// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

@MainActor
private final class FlowStorage: FolderBookmarkStorage {
    var records: [FolderBookmarkRecord] = []
    func load() throws -> [FolderBookmarkRecord] { records }
    func save(_ records: [FolderBookmarkRecord]) throws { self.records = records }
}

@MainActor
private final class FlowBookmarks: FolderBookmarkClient {
    var denied = false
    var starts = 0
    var stops = 0
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedFolderBookmark {
        ResolvedFolderBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool {
        if denied { return false }
        starts += 1
        return true
    }
    func stopAccessing(_ url: URL) { stops += 1 }
    func canonicalFolderURL(for url: URL) throws -> URL { url.standardizedFileURL }
}

nonisolated private final class FlowScanner: LibraryScanning, @unchecked Sendable {
    let base: any LibraryScanning
    let blockRescan: Bool
    let failRescan: Bool
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(base: any LibraryScanning, blockRescan: Bool = false, failRescan: Bool = false) {
        self.base = base; self.blockRescan = blockRescan; self.failRescan = failRescan
    }
    func scanParent(_ parent: URL) throws -> ParentScanResult {
        let call = lock.withLock { count += 1; return count }
        if call > 1 {
            if failRescan { throw CocoaError(.fileReadNoPermission) }
            if blockRescan, semaphore.wait(timeout: .now() + 10) != .success { throw CocoaError(.fileReadUnknown) }
        }
        return try base.scanParent(parent)
    }
    func release() { semaphore.signal() }
    func waitForRescan() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while calls < 2 {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private struct FlowContext {
    let model: LibraryListViewModel
    let store: AuthorizedFolderStore
    let client = FlowBookmarks()
    let checker = TestFinalCutChecker()
    let journal = TestCleanupJournal()
    let scanner: FlowScanner
    let folderID: UUID
    init(parent: URL = SafetyFixture().parent,
         fileSystem: any LibraryScanFileSystem = SafetyFixture(),
         trash: any CleanupTrashing = TestTrash(), blockRescan: Bool = false, failRescan: Bool = false) throws {
        store = AuthorizedFolderStore(storage: FlowStorage(), client: client)
        try store.add(parent)
        folderID = try #require(store.folders.first?.id)
        scanner = FlowScanner(base: LibraryScanner(fileSystem: fileSystem), blockRescan: blockRescan, failRescan: failRescan)
        model = LibraryListViewModel(folderStore: store, chooseFolder: { parent }, scanner: scanner,
            dryRunCleaner: DryRunCleaner(fileSystem: fileSystem), finalCut: checker,
            executor: CleanupExecutor(fileSystem: fileSystem, trash: trash, journal: journal,
                finalCut: checker, volume: TestVolumeChecker()), scanLogger: TestScanDiagnosticLogger())
    }
    func preview() async throws -> CleanupPreview {
        model.rescan()
        await model.waitForScan()
        model.previewCleanup(libraryID: try #require(model.libraries.first?.id), folderID: folderID)
        await model.waitForPreview()
        return try #require(model.cleanupPreview)
    }
    func prepare(_ selection: Set<String>, preview: CleanupPreview) async throws -> CleanupConfirmation {
        model.prepareCleanup(selection: selection, previewID: preview.id)
        await model.waitForCleanupPreparation()
        return try #require(model.cleanupConfirmation)
    }
}

@Suite @MainActor
struct CleanupFlowTests {
    @Test func emptyUnknownOrBlockedSelectionCannotCreateConfirmation() async throws {
        let trash = TestTrash(), context = try FlowContext(trash: trash)
        let preview = try await context.preview()
        context.model.prepareCleanup(selection: [], previewID: preview.id)
        await context.model.waitForCleanupPreparation()
        #expect(context.model.cleanupConfirmation == nil && trash.calls.isEmpty && context.journal.entries.isEmpty)
        context.model.prepareCleanup(selection: ["unknown"], previewID: preview.id)
        #expect(context.model.cleanupConfirmation == nil && context.model.notice != nil)
        context.model.confirmCleanup(id: UUID(), editingTasksEnded: true)
        #expect(!context.model.isCleaning && trash.calls.isEmpty)
        context.store.stopAllAccess()
        #expect(context.client.starts == context.client.stops)
    }

    @Test func checkboxAndCurrentConfirmationAreRequiredAndCancelDoesNotMove() async throws {
        let trash = TestTrash(), context = try FlowContext(trash: trash)
        let preview = try await context.preview()
        let confirmation = try await context.prepare([try #require(preview.items.first?.id)], preview: preview)
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: false)
        context.model.confirmCleanup(id: UUID(), editingTasksEnded: true)
        #expect(trash.calls.isEmpty && !context.model.isCleaning && context.journal.entries.isEmpty)
        context.model.cleanupConfirmation = nil // 二次确认点击取消
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        #expect(trash.calls.isEmpty && !context.model.isCleaning)
    }

    @Test func rescanInvalidatesPreviouslyPreparedConfirmation() async throws {
        let trash = TestTrash(), context = try FlowContext(trash: trash)
        let preview = try await context.preview()
        let confirmation = try await context.prepare([try #require(preview.items.first?.id)], preview: preview)
        context.model.rescan()
        await context.model.waitForScan()
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        #expect(context.model.cleanupPreview == nil && context.model.cleanupConfirmation == nil && trash.calls.isEmpty)
    }

    @Test func runningFinalCutBlocksBothPreparationAndConfirmation() async throws {
        let trash = TestTrash(), context = try FlowContext(trash: trash)
        let preview = try await context.preview()
        let selection: Set<String> = [try #require(preview.items.first?.id)]
        context.checker.running = true
        context.model.prepareCleanup(selection: selection, previewID: preview.id)
        #expect(context.model.cleanupConfirmation == nil && context.model.notice != nil)
        context.checker.running = false
        let confirmation = try await context.prepare(selection, preview: preview)
        context.checker.running = true
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        #expect(trash.calls.isEmpty && !context.model.isCleaning && context.model.cleanupConfirmation == nil)
    }

    @Test func authorityLossAfterConfirmationPreparationBlocksExecution() async throws {
        let trash = TestTrash(), context = try FlowContext(trash: trash)
        let preview = try await context.preview()
        let confirmation = try await context.prepare([try #require(preview.items.first?.id)], preview: preview)
        context.client.denied = true
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        #expect(trash.calls.isEmpty && !context.model.isCleaning && context.model.notice?.title == "未执行清理")
        context.store.stopAllAccess()
        #expect(context.client.starts == context.client.stops)
    }

    @Test func noOptimisticTotalsWaitsForRescanAndBlocksConcurrentMutations() async throws {
        let trash = BlockingTestTrash(), context = try FlowContext(trash: trash, blockRescan: true)
        let preview = try await context.preview()
        let before = context.model.libraries.first?.measurements.map(\.bytes)
        let confirmation = try await context.prepare([try #require(preview.items.first?.id)], preview: preview)
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        defer { trash.release(); context.scanner.release() }
        try await trash.waitUntilStarted()
        #expect(context.model.isCleaning && context.model.cleanupReport == nil)
        #expect(context.model.libraries.first?.measurements.map(\.bytes) == before)
        #expect(context.model.cleanupEntries.first?.status == .pending)
        context.model.rescan()
        context.model.removeFolder(id: context.folderID)
        context.model.retryFolderAccess()
        context.model.addLibrary()
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        #expect(context.scanner.calls == 1 && context.store.folders.count == 1 && trash.calls == 1)
        trash.release()
        try await context.scanner.waitForRescan()
        #expect(context.model.isCleaning && context.model.isRescanningAfterCleanup && context.model.cleanupReport == nil)
        context.scanner.release()
        await context.model.waitForCleanup()
        #expect(!context.model.isCleaning && context.model.cleanupReport?.completedCount == 1)
        // 测试替身没有移动文件；重扫保留原容量，证明 UI 没有按成功字节数扣减。
        #expect(context.model.libraries.first?.measurements.map(\.bytes) == before)
        context.store.stopAllAccess()
        #expect(context.client.starts == context.client.stops)
    }

    @Test func failedRescanIsReportedAsErrorAlongsideActualOperationResults() async throws {
        let context = try FlowContext(failRescan: true)
        let preview = try await context.preview()
        let confirmation = try await context.prepare([try #require(preview.items.first?.id)], preview: preview)
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        await context.model.waitForCleanup()
        #expect(context.model.cleanupReport?.completedCount == 1)
        #expect(context.model.hasScanIssues && context.model.libraries.isEmpty)
        #expect(context.model.scanResults[context.folderID]?.issues.first?.reason == .permission)
        #expect(!context.model.isCleaning)
    }

    @Test func cancellingModelStillWaitsForCurrentItemAndCompletesRescan() async throws {
        let trash = BlockingTestTrash(), context = try FlowContext(trash: trash)
        let preview = try await context.preview()
        let confirmation = try await context.prepare(Set(preview.items.map(\.id)), preview: preview)
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        defer { trash.release() }
        try await trash.waitUntilStarted()
        context.model.cancelCleanup()
        #expect(context.model.isCleaning && context.model.cleanupReport == nil && context.scanner.calls == 1)
        trash.release()
        await context.model.waitForCleanup()
        #expect(context.model.cleanupReport?.completedCount == 1 && context.model.cleanupReport?.cancelledCount == 1)
        #expect(context.scanner.calls == 2 && context.model.hasScanned && !context.model.isCleaning)
        context.store.stopAllAccess()
        #expect(context.client.starts == context.client.stops)
    }

    @Test func confirmedSelectionMovesOnlyCheckedRealFixtureDirectory() async throws {
        let fixture = try TrashIntegrationFixture()
        let context = try FlowContext(parent: fixture.parent, fileSystem: FoundationScanFileSystem(), trash: FileManagerTrash())
        let preview = try await context.preview()
        let analysis = try #require(preview.items.first { $0.request.kind == .analysis })
        let confirmation = try await context.prepare([analysis.id], preview: preview)
        #expect(confirmation.requests.count == 1 && confirmation.requests.first?.kind == .analysis)
        #expect(FileManager.default.fileExists(atPath: fixture.analysis.path))
        context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
        await context.model.waitForCleanup()
        #expect(context.model.cleanupReport?.completedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.analysis.path))
        #expect(FileManager.default.fileExists(atPath: fixture.render.path))
        #expect(context.model.libraries.first?.measurements.first { $0.kind == .analysis }?.bytes == 0)
        #expect(context.model.libraries.first?.measurements.first { $0.kind == .render }?.bytes == preview.items.first { $0.request.kind == .render }?.request.candidate.bytes)
        for (url, data) in fixture.protectedFiles { #expect(try Data(contentsOf: url) == data) }
        context.store.stopAllAccess()
        #expect(context.client.starts == context.client.stops)
    }

    @Test(arguments: [false, true])
    func realChangesBeforeOrAfterSecondConfirmationAreRejected(_ afterPreparation: Bool) async throws {
        let fixture = try TrashIntegrationFixture(), trash = TestTrash()
        let context = try FlowContext(parent: fixture.parent, fileSystem: FoundationScanFileSystem(), trash: trash)
        let preview = try await context.preview()
        let render = try #require(preview.items.first { $0.request.kind == .render })
        let confirmation = afterPreparation ? try await context.prepare([render.id], preview: preview) : nil
        try Data(repeating: 3, count: 8_193).write(to: fixture.render.appendingPathComponent("nested/cache.dat"))
        if let confirmation {
            context.model.confirmCleanup(id: confirmation.id, editingTasksEnded: true)
            await context.model.waitForCleanup()
            #expect(context.model.cleanupReport?.failedCount == 1)
        } else {
            context.model.prepareCleanup(selection: [render.id], previewID: preview.id)
            await context.model.waitForCleanupPreparation()
            #expect(context.model.cleanupConfirmation == nil && context.model.notice?.title == "清理前复验失败")
        }
        #expect(trash.calls.isEmpty && FileManager.default.fileExists(atPath: fixture.render.path))
    }
}
