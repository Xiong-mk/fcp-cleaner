// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

/// ViewModel 测试只保存调用参数，避免覆盖用户实际的扫描诊断文件。
@MainActor
final class TestScanDiagnosticLogger: ScanDiagnosticLogging {
    struct Call {
        let results: [UUID: ParentScanResult]
        let folderPaths: [UUID: String]
        let startedAt: Date
    }

    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FCPCleaner-TestScanDiagnostics/latest.json")
    var calls: [Call] = []
    var failWrite = false

    func write(results: [UUID: ParentScanResult], folderPaths: [UUID: String], startedAt: Date) throws -> URL {
        calls.append(Call(results: results, folderPaths: folderPaths, startedAt: startedAt))
        if failWrite { throw CocoaError(.fileWriteOutOfSpace) }
        return outputURL
    }
}

@MainActor
private final class MemoryStorage: FolderBookmarkStorage {
    var records: [FolderBookmarkRecord] = []
    var failLoad = false
    var failSave = false
    var saves = 0

    func load() throws -> [FolderBookmarkRecord] {
        if failLoad { throw CocoaError(.coderReadCorrupt) }
        return records
    }

    func save(_ records: [FolderBookmarkRecord]) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        self.records = records
        saves += 1
    }
}

@MainActor
private final class BookmarkClient: FolderBookmarkClient {
    var resolutions: [Data: ResolvedFolderBookmark] = [:]
    var realPaths: [String: String] = [:]
    var failedCreationPaths: Set<String> = []
    var deniedPaths: Set<String> = []
    var invalidPaths: Set<String> = []
    var started: [URL] = []
    var stopped: [URL] = []
    var validated: [URL] = []

    func makeBookmark(for url: URL) throws -> Data {
        if failedCreationPaths.contains(url.path) { throw CocoaError(.fileReadNoPermission) }
        let data = Data(url.path.utf8)
        resolutions[data] = ResolvedFolderBookmark(url: url, isStale: false)
        return data
    }

    func resolve(_ data: Data) throws -> ResolvedFolderBookmark {
        guard let result = resolutions[data] else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    func startAccessing(_ url: URL) -> Bool {
        started.append(url)
        return !deniedPaths.contains(url.path)
    }

    func stopAccessing(_ url: URL) { stopped.append(url) }

    func canonicalFolderURL(for url: URL) throws -> URL {
        validated.append(url)
        if invalidPaths.contains(url.path) { throw CocoaError(.fileReadNoSuchFile) }
        return URL(fileURLWithPath: realPaths[url.path] ?? url.standardizedFileURL.path)
    }

    func record(_ path: String, stale: Bool = false) -> FolderBookmarkRecord {
        let data = Data("saved:\(path)".utf8)
        resolutions[data] = ResolvedFolderBookmark(url: URL(fileURLWithPath: path), isStale: stale)
        return FolderBookmarkRecord(id: UUID(), path: path, bookmarkData: data)
    }
}


nonisolated private final class RecordingScanner: LibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var scanned: [URL] = []
    var calls: [URL] { lock.withLock { scanned } }

    func scanParent(_ parent: URL) throws -> ParentScanResult {
        lock.withLock { scanned.append(parent) }
        return ParentScanResult(libraries: [Library(
            url: parent.appendingPathComponent("Demo.fcpbundle"),
            measurements: [CacheMeasurement(kind: .render), CacheMeasurement(kind: .analysis)]
        )], issues: [])
    }
}

/// 第一轮故意忽略取消直到放行，以验证旧结果不能覆盖新结果，访问也不能提前释放。
nonisolated private final class BlockingScanner: LibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var firstStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if firstStarted { return true }
                startWaiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() { gate.signal() }

    func scanParent(_ parent: URL) throws -> ParentScanResult {
        let (isFirst, waiter) = lock.withLock {
            callCount += 1
            guard callCount == 1 else { return (false, Optional<CheckedContinuation<Void, Never>>.none) }
            firstStarted = true
            let waiter = startWaiter
            startWaiter = nil
            return (true, waiter)
        }
        waiter?.resume()
        if isFirst { _ = gate.wait(timeout: .now() + 10) }
        return ParentScanResult(libraries: [Library(
            url: parent.appendingPathComponent(isFirst ? "Old.fcpbundle" : "New.fcpbundle"),
            measurements: []
        )], issues: [])
    }
}

@Suite @MainActor
struct FolderAuthorizationTests {
    private let first = URL(fileURLWithPath: "/test/one/Projects")
    private let second = URL(fileURLWithPath: "/test/two/Projects")

    @Test func multipleFoldersWithSameNameRemainDistinct() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(try store.add(first) == .added)
        #expect(try store.add(second) == .added)
        #expect(store.folders.map(\.path) == [first.path, second.path])
        #expect(disk.records.count == 2)
        #expect(client.stopped.isEmpty)
    }

    @Test func secondLaunchResolvesSavedBookmarksAndStartsAccess() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let firstLaunch = AuthorizedFolderStore(storage: disk, client: client)
        try firstLaunch.add(first)
        firstLaunch.stopAllAccess()
        let nextLaunch = AuthorizedFolderStore(storage: disk, client: client)
        #expect(nextLaunch.folders.first?.url == first)
        #expect(client.started == [first, first])
        #expect(client.stopped == [first])
    }

    @Test func duplicateRealPathReleasesOnlyTemporaryScope() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        client.realPaths[second.path] = first.path
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        #expect(try store.add(second) == .duplicate)
        #expect(store.folders.count == 1)
        #expect(disk.saves == 1)
        #expect(client.stopped == [second])
    }

    @Test func restoreDeduplicatesResolvedPathsAndPersistsResult() {
        let disk = MemoryStorage(), client = BookmarkClient()
        disk.records = [client.record(first.path), client.record(second.path)]
        client.realPaths[second.path] = first.path
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.folders.count == 1)
        #expect(disk.records.count == 1)
        #expect(client.stopped == [second])
    }

    @Test func removePersistsAndStopsOnlyRemovedScope() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        try store.add(second)
        try store.remove(id: #require(store.folders.first?.id))
        #expect(store.folders.map(\.path) == [second.path])
        #expect(disk.records.map(\.path) == [second.path])
        #expect(client.stopped == [first])
        let nextLaunch = AuthorizedFolderStore(storage: disk, client: client)
        #expect(nextLaunch.folders.map(\.path) == [second.path])
    }

    @Test func failedRemovalRetainsRecordAndAccess() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        disk.failSave = true
        let id = try #require(store.folders.first?.id)
        #expect(throws: (any Error).self) { try store.remove(id: id) }
        #expect(store.folders.count == 1)
        #expect(disk.records.count == 1)
        #expect(client.stopped.isEmpty)
    }

    @Test func failedCreationDoesNotSaveOrStart() {
        let disk = MemoryStorage(), client = BookmarkClient()
        client.failedCreationPaths.insert(first.path)
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(throws: (any Error).self) { try store.add(first) }
        #expect(store.folders.isEmpty && disk.records.isEmpty)
        #expect(client.started.isEmpty && client.stopped.isEmpty)
    }

    @Test func deniedStartDoesNotStopAnUnacquiredScope() {
        let disk = MemoryStorage(), client = BookmarkClient()
        client.deniedPaths.insert(first.path)
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(throws: (any Error).self) { try store.add(first) }
        #expect(store.folders.isEmpty && disk.records.isEmpty)
        #expect(client.started == [first])
        #expect(client.stopped.isEmpty && client.validated.isEmpty)
    }

    @Test func invalidDirectoryBalancesScopeAndDoesNotSave() {
        let disk = MemoryStorage(), client = BookmarkClient()
        client.invalidPaths.insert(first.path)
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(throws: (any Error).self) { try store.add(first) }
        #expect(store.folders.isEmpty && disk.records.isEmpty)
        #expect(client.started == client.stopped)
    }

    @Test func failedSaveRollsBackAdditionAndBalancesScope() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        disk.failSave = true
        #expect(throws: (any Error).self) { try store.add(second) }
        #expect(store.folders.map(\.path) == [first.path])
        #expect(disk.records.map(\.path) == [first.path])
        #expect(client.stopped == [second])
    }

    @Test func brokenBookmarkIsRetainedWithoutUsingOldPath() {
        let disk = MemoryStorage(), client = BookmarkClient()
        let broken = FolderBookmarkRecord(id: UUID(), path: first.path, bookmarkData: Data([0]))
        disk.records = [broken, client.record(second.path)]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.folders.count == 2)
        #expect(store.folders[0].url == nil && store.folders[0].accessError != nil)
        #expect(store.folders[1].url == second)
        #expect(client.started == [second] && client.validated == [second])
        #expect(disk.records.first == broken)
    }

    @Test func unpluggedDirectoryCanBeRetried() {
        let disk = MemoryStorage(), client = BookmarkClient()
        disk.records = [client.record(first.path)]
        client.invalidPaths.insert(first.path)
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.folders.first?.accessError != nil)
        #expect(client.stopped == [first])
        client.invalidPaths.removeAll()
        store.restore()
        #expect(store.folders.first?.url == first)
        #expect(store.folders.first?.accessError == nil)
    }

    @Test func staleBookmarkIsRenewedWhileScopeIsActive() {
        let disk = MemoryStorage(), client = BookmarkClient()
        let old = client.record(first.path, stale: true)
        disk.records = [old]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.folders.first?.url == first)
        #expect(disk.records.first?.id == old.id)
        #expect(disk.records.first?.bookmarkData != old.bookmarkData)
        #expect(client.stopped.isEmpty)
    }

    @Test func failedStaleRenewalRetainsOldRecordAndClosesScope() {
        let disk = MemoryStorage(), client = BookmarkClient()
        let old = client.record(first.path, stale: true)
        disk.records = [old, client.record(second.path)]
        client.failedCreationPaths.insert(first.path)
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.folders.first?.url == nil)
        #expect(store.folders.first?.accessError != nil)
        #expect(disk.records.first == old)
        #expect(store.folders.last?.url == second)
        #expect(client.stopped == [first])
    }

    @Test func failedRenewalPersistenceDisplaysWarningAndKeepsOldDiskData() {
        let disk = MemoryStorage(), client = BookmarkClient()
        let old = client.record(first.path, stale: true)
        disk.records = [old]
        disk.failSave = true
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.persistenceWarning != nil)
        #expect(store.folders.first?.url == first)
        #expect(disk.records == [old])
    }

    @Test func corruptStorageBlocksMutationsUntilSuccessfulRetry() {
        let disk = MemoryStorage(), client = BookmarkClient()
        disk.records = [client.record(first.path)]
        disk.failLoad = true
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.add(second) }
        #expect(throws: (any Error).self) { try store.remove(id: UUID()) }
        #expect(disk.saves == 0 && disk.records.count == 1)
        disk.failLoad = false
        store.restore()
        #expect(store.loadError == nil && store.folders.first?.url == first)
    }

    @Test func corruptDuplicateIDsAreNotOverwritten() {
        let disk = MemoryStorage(), client = BookmarkClient()
        let record = client.record(first.path)
        disk.records = [record, record]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(store.loadError != nil)
        #expect(disk.saves == 0 && client.started.isEmpty)
    }

    @Test func reauthorizationPreservesIdentityAndCanFollowMovedFolder() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let old = FolderBookmarkRecord(id: UUID(), path: first.path, bookmarkData: Data([0]))
        disk.records = [old]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(try store.add(second, replacing: old.id) == .renewed)
        #expect(store.folders.count == 1 && store.folders.first?.url == second)
        #expect(disk.records.first?.id == old.id)
    }

    @Test func selectingFailedRecordAgainRepairsItInPlace() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let old = FolderBookmarkRecord(id: UUID(), path: first.path, bookmarkData: Data([0]))
        disk.records = [old]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(try store.add(first) == .renewed)
        #expect(store.folders.count == 1 && store.folders.first?.id == old.id)
        #expect(store.folders.first?.url == first)
    }

    @Test func failedRecordCannotHideAnActiveDuplicateAfterFolderMoves() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let failed = FolderBookmarkRecord(id: UUID(), path: first.path, bookmarkData: Data([0]))
        disk.records = [failed, client.record(second.path)]
        client.realPaths[second.path] = first.path
        let store = AuthorizedFolderStore(storage: disk, client: client)
        #expect(try store.add(first) == .duplicate)
        #expect(store.folders.count == 2)
        #expect(client.stopped == [first])
        store.stopAllAccess()
        #expect(client.stopped == [first, second])
    }

    @Test func shutdownAndDestructionStopExactlyOnce() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        var store: AuthorizedFolderStore? = AuthorizedFolderStore(storage: disk, client: client)
        try store?.add(first)
        store?.stopAllAccess()
        store?.stopAllAccess()
        store = nil
        #expect(client.stopped == [first])
        var another: AuthorizedFolderStore? = AuthorizedFolderStore(storage: disk, client: client)
        #expect(another?.folders.count == 1)
        another = nil
        #expect(client.stopped == [first, first])
    }

    @Test func cancellingPickerPreservesRecordsAndExistingNotice() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        let viewModel = LibraryListViewModel(folderStore: store, chooseFolder: { nil },
                                            scanLogger: TestScanDiagnosticLogger())
        viewModel.notice = .init(title: "已有提示", message: "保留")
        viewModel.addLibrary()
        viewModel.reauthorizeFolder(id: try #require(store.folders.first?.id))
        #expect(disk.saves == 1 && store.folders.count == 1)
        #expect(viewModel.notice?.title == "已有提示")
        #expect(viewModel.libraries.isEmpty)
    }

    @Test func viewModelReportsAddAndRemoveFailures() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        let viewModel = LibraryListViewModel(folderStore: store, chooseFolder: { first },
                                            scanLogger: TestScanDiagnosticLogger())
        client.failedCreationPaths.insert(first.path)
        viewModel.addLibrary()
        #expect(viewModel.notice?.title == "文件夹授权失败")
        client.failedCreationPaths.removeAll()
        try store.add(first)
        disk.failSave = true
        viewModel.removeFolder(id: try #require(store.folders.first?.id))
        #expect(viewModel.notice?.title == "移除授权失败")
        #expect(store.folders.count == 1)
    }

    @Test func realPathNormalizationResolvesSymlinksAndRejectsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // 本阶段保留临时测试数据，不执行删除收尾。
        let folder = root.appendingPathComponent("Projects")
        let alias = root.appendingPathComponent("Link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let client = SecurityScopedFolderBookmarkClient()
        #expect(try client.canonicalFolderURL(for: alias) == folder.resolvingSymlinksInPath())
        #expect(try client.canonicalFolderURL(for: folder.appendingPathComponent("../Projects")) == folder.resolvingSymlinksInPath())
        let file = root.appendingPathComponent("movie.mov")
        try Data([1]).write(to: file)
        #expect(throws: (any Error).self) { try client.canonicalFolderURL(for: file) }
    }

    @Test func jsonStorageRoundTripAndCorruptionPreservesOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // 本阶段保留临时测试数据，不执行删除收尾。
        let file = root.appendingPathComponent("Support/folders.json")
        let disk = JSONFolderBookmarkStorage(fileURL: file)
        #expect(try disk.load().isEmpty)
        let record = FolderBookmarkRecord(id: UUID(), path: first.path, bookmarkData: Data([1, 2]))
        try disk.save([record])
        #expect(try JSONFolderBookmarkStorage(fileURL: file).load() == [record])
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: file)
        let store = AuthorizedFolderStore(storage: disk, client: BookmarkClient())
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.add(first) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func realSecurityScopedBookmarkSurvivesStoreRecreationAndReadsFixture() throws {
        // 使用应用自身测试容器中的虚拟资源库，不接触真实剪辑素材。
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // 本阶段保留临时测试数据，不执行删除收尾。
        let parent = root.appendingPathComponent("Projects")
        let library = parent.appendingPathComponent("Demo.fcpbundle")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let disk = JSONFolderBookmarkStorage(fileURL: root.appendingPathComponent("bookmarks.json"))
        let firstLaunch = AuthorizedFolderStore(storage: disk)
        try firstLaunch.add(parent)
        firstLaunch.stopAllAccess()
        let nextLaunch = AuthorizedFolderStore(storage: disk)
        let restored = try #require(nextLaunch.folders.first?.url)
        let children = try FileManager.default.contentsOfDirectory(at: restored, includingPropertiesForKeys: nil)
        #expect(children.map(\.lastPathComponent) == ["Demo.fcpbundle"])
        try nextLaunch.remove(id: #require(nextLaunch.folders.first?.id))
        #expect(try disk.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: library.path))
    }

    @Test func startupScansOnlyAuthorizedURLsAndBalancesIndependentScopes() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = RecordingScanner()
        disk.records = [client.record(first.path), client.record(second.path)]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: TestScanDiagnosticLogger())
        model.startScanningIfNeeded()
        await model.waitForScan()
        #expect(Set(scanner.calls) == [first, second])
        #expect(model.libraries.count == 2 && model.hasScanned && !model.isScanning)
        #expect(client.started.count == 4 && client.stopped.count == 2)
        model.startScanningIfNeeded()
        #expect(scanner.calls.count == 2)
        store.stopAllAccess()
        #expect(client.started.count == client.stopped.count)
    }

    @Test func completedScanLogsResultsPathsAndStartTimeAndExposesLocation() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = RecordingScanner()
        disk.records = [client.record(first.path), client.record(second.path)]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        let logger = TestScanDiagnosticLogger()
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: logger)
        let beforeScan = Date()
        model.rescan()
        await model.waitForScan()
        let afterScan = Date()

        #expect(logger.calls.count == 1)
        let call = try #require(logger.calls.first)
        #expect(call.startedAt >= beforeScan && call.startedAt <= afterScan)
        #expect(call.folderPaths == Dictionary(uniqueKeysWithValues: store.folders.map { ($0.id, $0.path) }))
        #expect(Set(call.results.keys) == Set(model.scanResults.keys))
        #expect(Set(call.results.values.flatMap(\.libraries).map(\.path)) == Set(model.libraries.map(\.path)))
        #expect(call.results.values.allSatisfy { !$0.hasIssues })
        #expect(model.hasScanned && !model.isScanning && model.libraries.count == 2)
        #expect(model.scanLogURL == logger.outputURL && model.scanLogError == nil)
        store.stopAllAccess()
    }

    @Test func diagnosticWriteFailurePreservesScanResultsAndClearsOldLocation() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = RecordingScanner()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        let logger = TestScanDiagnosticLogger()
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: logger)
        model.rescan()
        await model.waitForScan()
        #expect(model.scanLogURL == logger.outputURL && model.scanLogError == nil)
        let libraryPath = try #require(model.libraries.first?.path)

        logger.failWrite = true
        model.rescan()
        await model.waitForScan()
        #expect(logger.calls.count == 2)
        #expect(model.hasScanned && !model.isScanning && !model.hasScanIssues)
        #expect(model.libraries.map(\.path) == [libraryPath])
        #expect(model.scanLogURL == nil)
        #expect(model.scanLogError?.contains("扫描日志写入失败") == true)

        logger.failWrite = false
        model.rescan()
        await model.waitForScan()
        #expect(logger.calls.count == 3)
        #expect(model.scanLogURL == logger.outputURL && model.scanLogError == nil)
        store.stopAllAccess()
    }

    @Test func canceledScanDoesNotPublishDiagnosticLogOrLateResults() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = BlockingScanner()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        let logger = TestScanDiagnosticLogger()
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: logger)
        model.rescan()
        await scanner.waitUntilStarted()
        model.cancelScan()
        scanner.release()
        await model.waitForScan()

        #expect(logger.calls.isEmpty)
        #expect(model.scanLogURL == nil && model.scanLogError == nil)
        #expect(model.scanResults.isEmpty && model.libraries.isEmpty)
        #expect(!model.hasScanned && !model.isScanning)
        store.stopAllAccess()
        #expect(client.started.count == client.stopped.count)
    }

    @Test func addAutomaticallyScansAndCancellationKeepsCompletedResults() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = RecordingScanner()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        var selection: URL? = first
        let model = LibraryListViewModel(folderStore: store, chooseFolder: { selection }, scanner: scanner,
                                        scanLogger: TestScanDiagnosticLogger())
        model.addLibrary()
        await model.waitForScan()
        #expect(scanner.calls == [first] && model.libraries.count == 1)
        let identity = model.libraries.first?.id
        selection = nil
        model.addLibrary()
        #expect(model.libraries.first?.id == identity && scanner.calls == [first])
    }

    @Test func failedAuthorizationNeverScansRememberedPath() async {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = RecordingScanner()
        disk.records = [FolderBookmarkRecord(id: UUID(), path: first.path, bookmarkData: Data([0]))]
        let store = AuthorizedFolderStore(storage: disk, client: client)
        let logger = TestScanDiagnosticLogger()
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: logger)
        model.rescan()
        await model.waitForScan()
        #expect(scanner.calls.isEmpty && model.hasScanIssues)
        #expect(model.scanResults.values.first?.issues.first?.url == first)
        #expect(logger.calls.count == 1)
        #expect(logger.calls.first?.folderPaths.values.first == first.path)
        #expect(logger.calls.first?.results.values.first?.issues.first?.url == first)
        #expect(logger.calls.first?.results.values.first?.issues.first?.reason == .unavailable)
        #expect(model.scanLogURL == logger.outputURL && model.scanLogError == nil)
    }

    @Test func scanAccessStartFailureIsReportedWithoutStoppingUnacquiredScope() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = RecordingScanner()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        client.deniedPaths.insert(first.path)
        let logger = TestScanDiagnosticLogger()
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: logger)
        model.rescan()
        await model.waitForScan()
        #expect(scanner.calls.isEmpty && model.hasScanIssues)
        #expect(model.scanResults.values.first?.issues.first?.reason == .permission)
        #expect(client.stopped.isEmpty)
        #expect(logger.calls.count == 1)
        #expect(logger.calls.first?.results.values.first?.issues.first?.reason == .permission)
    }

    @Test func removingFolderDuringScanKeepsLeaseUntilWorkerExitsAndDiscardsResults() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = BlockingScanner()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        let id = try #require(store.folders.first?.id)
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: TestScanDiagnosticLogger())
        model.rescan()
        await scanner.waitUntilStarted()
        let removal = Task { @MainActor in
            model.removeFolder(id: id)
            #expect(client.stopped == [first]) // store scope 已释放，扫描 scope 仍生效
            scanner.release()
        }
        await model.waitForScan() // 进入等待后，removal 才能在主 actor 上运行
        await removal.value
        #expect(client.started == [first, first] && client.stopped == [first, first])
        #expect(model.libraries.isEmpty && model.scanResults.isEmpty && !model.isScanning)
    }

    @Test func repeatedScanCannotPublishCanceledOldResults() async throws {
        let disk = MemoryStorage(), client = BookmarkClient(), scanner = BlockingScanner()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        let logger = TestScanDiagnosticLogger()
        let model = LibraryListViewModel(folderStore: store, scanner: scanner, scanLogger: logger)
        model.rescan()
        await scanner.waitUntilStarted()
        let replacement = Task { @MainActor in
            model.rescan()
            await model.waitForScan()
            #expect(model.libraries.first?.name == "New.fcpbundle")
            scanner.release()
        }
        await model.waitForScan()
        await replacement.value
        #expect(model.libraries.first?.name == "New.fcpbundle")
        #expect(client.started.count == 3 && client.stopped.count == 2)
        #expect(logger.calls.count == 1)
        #expect(logger.calls.first?.results.values.first?.libraries.first?.name == "New.fcpbundle")
        #expect(model.scanLogURL == logger.outputURL && model.scanLogError == nil)
        store.stopAllAccess()
    }

    @Test func explicitLeaseSurvivesRestoreAndClosesExactlyOnce() throws {
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(first)
        let lease = try store.makeScanAccess(for: #require(store.folders.first?.id))
        store.restore()
        #expect(client.started.count == 3 && client.stopped.count == 1)
        lease.close()
        lease.close()
        #expect(client.stopped.count == 2)
        store.stopAllAccess()
        #expect(client.started.count == client.stopped.count)
    }

    @Test func previewUsesFreshScopeAndNeverChangesScanTotals() async throws {
        let fs = SafetyFixture()
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(fs.parent)
        let id = try #require(store.folders.first?.id)
        let model = LibraryListViewModel(folderStore: store, scanner: LibraryScanner(fileSystem: fs),
                                         dryRunCleaner: DryRunCleaner(fileSystem: fs), scanLogger: TestScanDiagnosticLogger())
        model.rescan()
        await model.waitForScan()
        let library = try #require(model.libraries.first)
        let before = library.measurements.map(\.bytes)
        model.previewCleanup(libraryID: library.id, folderID: id)
        await model.waitForPreview()
        #expect(model.cleanupPreview?.eligibleCount == 2)
        #expect(model.libraries.first?.measurements.map(\.bytes) == before)
        #expect(client.started.count == 3 && client.stopped.count == 2)
        model.rescan()
        #expect(model.cleanupPreview == nil)
        await model.waitForScan()
        store.stopAllAccess()
        #expect(client.started.count == client.stopped.count)
    }

    @Test func lostAuthorizationBlocksPreviewBeforeReadingFiles() async throws {
        let fs = SafetyFixture()
        let disk = MemoryStorage(), client = BookmarkClient()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(fs.parent)
        let model = LibraryListViewModel(folderStore: store, scanner: LibraryScanner(fileSystem: fs),
                                        scanLogger: TestScanDiagnosticLogger())
        model.rescan()
        await model.waitForScan()
        let library = try #require(model.libraries.first)
        client.deniedPaths.insert(fs.parent.path)
        model.previewCleanup(libraryID: library.id, folderID: try #require(store.folders.first?.id))
        #expect(model.cleanupPreview == nil && !model.isPreparingPreview)
        #expect(model.notice?.title == "无法生成清理预览")
        #expect(client.stopped.count == 1) // 失败的 scope 没有配对 stop
        store.stopAllAccess()
    }

    @Test func removingAuthorizationDuringPreviewDiscardsResultAndRetainsWorkerScope() async throws {
        let fs = SafetyFixture()
        let disk = MemoryStorage(), client = BookmarkClient(), cleaner = BlockingDryRunCleaner()
        let store = AuthorizedFolderStore(storage: disk, client: client)
        try store.add(fs.parent)
        let id = try #require(store.folders.first?.id)
        let model = LibraryListViewModel(folderStore: store, scanner: LibraryScanner(fileSystem: fs), dryRunCleaner: cleaner,
                                        scanLogger: TestScanDiagnosticLogger())
        model.rescan()
        await model.waitForScan()
        let library = try #require(model.libraries.first)
        model.previewCleanup(libraryID: library.id, folderID: id)
        await cleaner.waitUntilStarted()
        let removal = Task { @MainActor in
            model.removeFolder(id: id)
            #expect(client.stopped.count == 2) // scan + store，预览 worker 的 scope 仍然保持
            #expect(model.cleanupPreview == nil && !model.isPreparingPreview)
            cleaner.release()
        }
        await model.waitForPreview() // 先进入等待，再让 removal 在主 actor 运行
        await removal.value
        #expect(model.cleanupPreview == nil && model.libraries.isEmpty)
        #expect(client.started.count == 3 && client.stopped.count == 3)
    }

}


/// 故意忽略取消，证明完成已过期的后台预览不会重新发布结果。
nonisolated private final class BlockingDryRunCleaner: DryRunCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if started { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() { gate.signal() }

    func preview(_ requests: [CleanupRequest], authorizedParent: URL) throws -> CleanupPreview {
        let continuation = lock.withLock {
            started = true
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume()
        _ = gate.wait(timeout: .now() + 10)
        return CleanupPreview(items: requests.map { CleanupPreviewItem(request: $0, blockedReason: nil) })
    }
}
