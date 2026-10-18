// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

@MainActor
final class TestFinalCutChecker: FinalCutChecking {
    var running = false
    var checks = 0
    var failAt: Int?
    func requireClosed() throws {
        checks += 1
        if running || checks == failAt { throw CleanupExecutionError.finalCutRunning }
    }
}

nonisolated struct TestVolumeChecker: CleanupVolumeChecking {
    var denied = false
    func requireSupported(_ target: URL) throws {
        if denied { throw CleanupExecutionError.unsupportedVolume }
    }
}

nonisolated final class TestCleanupJournal: CleanupJournaling, @unchecked Sendable {
    let directory: URL? = nil
    private let lock = NSLock()
    private var saved: [CleanupLogEntry] = []
    let failStatus: CleanupLogEntry.Status?
    var entries: [CleanupLogEntry] { lock.withLock { saved } }
    init(failStatus: CleanupLogEntry.Status? = nil) { self.failStatus = failStatus }
    func write(_ entry: CleanupLogEntry) throws {
        if entry.status == failStatus { throw CocoaError(.fileWriteOutOfSpace) }
        lock.withLock { saved.append(entry) }
    }
}

nonisolated final class TestTrash: CleanupTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private var called: [URL] = []
    let operation: @Sendable (URL) throws -> URL?
    var calls: [URL] { lock.withLock { called } }
    init(operation: @escaping @Sendable (URL) throws -> URL? = { _ in nil }) { self.operation = operation }
    func trash(_ target: URL) throws -> URL? {
        lock.withLock { called.append(target) }
        return try operation(target)
    }
}

nonisolated final class BlockingTestTrash: CleanupTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func trash(_ target: URL) throws -> URL? {
        lock.withLock { count += 1 }
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
        return nil
    }
    func release() { semaphore.signal() }
    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while calls == 0 {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// 仅构造本次测试独享的系统临时目录；不查找、不操作任何已有资源库。
nonisolated struct TrashIntegrationFixture {
    let parent: URL
    let library: URL
    let render: URL
    let analysis: URL
    let protectedFiles: [(URL, Data)]
    init() throws {
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("TrashIntegration-" + UUID().uuidString)
        library = parent.appendingPathComponent("Demo.fcpbundle")
        render = library.appendingPathComponent("Event A/Render Files/High Quality Media")
        analysis = library.appendingPathComponent("Event A/Analysis Files")
        protectedFiles = [
            (library.appendingPathComponent("Event A/Original Media/important.mov"), Data("original".utf8)),
            (library.appendingPathComponent("Event A/Transcoded Media/proxy.mov"), Data("proxy".utf8)),
            (library.appendingPathComponent("Event A/Render Files/Proxy Media/proxy.mov"), Data("render proxy".utf8)),
            (library.appendingPathComponent("Event A/CurrentVersion.fcpevent"), Data("database".utf8)),
            (parent.appendingPathComponent("Final Cut Backups/Demo.fcpbundle/backup"), Data("backup".utf8))
        ]
        for (url, data) in protectedFiles + [
            (render.appendingPathComponent("nested/cache.dat"), Data(repeating: 7, count: 8_193)),
            (analysis.appendingPathComponent(".hidden.dat"), Data(repeating: 8, count: 19))
        ] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
    func requests() throws -> [CleanupRequest] {
        let library = try #require(LibraryScanner().scanParent(parent).libraries.first)
        return library.measurements.flatMap { measurement in
            measurement.candidates.map { CleanupRequest(libraryURL: library.url, kind: measurement.kind, candidate: $0) }
        }
    }
}

@Suite @MainActor
struct CleanupExecutorTests {
    @Test func waitsForCurrentOperationAndCancellationStopsOnlyNextItem() async throws {
        let fs = SafetyFixture(), journal = TestCleanupJournal(), trash = BlockingTestTrash()
        let render = try fs.request()
        let analysis = try fs.request(kind: .analysis, target: fs.library.appendingPathComponent("Event A/Analysis Files"))
        let executor = CleanupExecutor(fileSystem: fs, trash: trash, journal: journal,
            finalCut: TestFinalCutChecker(), volume: TestVolumeChecker())
        let task = Task { await executor.execute([analysis, render, render], authorizedParent: fs.parent,
                                                 permit: {}, progress: { _ in }) }
        defer { trash.release() }
        try await trash.waitUntilStarted()
        #expect(trash.calls == 1)
        #expect(journal.entries.count == 1 && journal.entries.first?.status == .pending)
        task.cancel()
        trash.release()
        let report = await task.value
        #expect(trash.calls == 1)
        #expect(report.completedCount == 1 && report.cancelledCount == 1 && report.failedCount == 0)
        #expect(report.entries.first?.targetPath == render.candidate.url.path)
        #expect(journal.entries.map(\.status) == [.pending, .completed, .cancelled])
    }

    @Test func trashFailureKeepsDataAndContinuesWithIndependentItem() async throws {
        let fixture = try TrashIntegrationFixture(), journal = TestCleanupJournal()
        let requests = try fixture.requests()
        let trash = TestTrash { _ in throw CocoaError(.fileWriteNoPermission) }
        let executor = CleanupExecutor(trash: trash, journal: journal, finalCut: TestFinalCutChecker())
        let report = await executor.execute(requests, authorizedParent: fixture.parent, permit: {}, progress: { _ in })
        #expect(report.failedCount == 2 && report.completedCount == 0 && report.movedBytes == 0)
        #expect(trash.calls.count == 2)
        #expect(journal.entries.map(\.status) == [.pending, .failed, .pending, .failed])
        #expect(FileManager.default.fileExists(atPath: fixture.render.path))
        #expect(FileManager.default.fileExists(atPath: fixture.analysis.path))
        #expect(try Data(contentsOf: fixture.render.appendingPathComponent("nested/cache.dat")) == Data(repeating: 7, count: 8_193))
    }

    @Test func runningFinalCutOrUnsupportedVolumeNeverCallsTrash() async throws {
        let fs = SafetyFixture(), request = try fs.request()
        for denyVolume in [false, true] {
            let checker = TestFinalCutChecker(), trash = TestTrash()
            checker.running = !denyVolume
            let executor = CleanupExecutor(fileSystem: fs, trash: trash, journal: TestCleanupJournal(),
                finalCut: checker, volume: TestVolumeChecker(denied: denyVolume))
            let report = await executor.execute([request], authorizedParent: fs.parent, permit: {}, progress: { _ in })
            #expect(report.failedCount == 1 && trash.calls.isEmpty)
        }
    }

    @Test func finalCutStartingBetweenItemsBlocksNextMove() async throws {
        let fs = SafetyFixture(), checker = TestFinalCutChecker(), trash = TestTrash()
        checker.failAt = 2
        let analysis = try fs.request(kind: .analysis, target: fs.library.appendingPathComponent("Event A/Analysis Files"))
        let executor = CleanupExecutor(fileSystem: fs, trash: trash, journal: TestCleanupJournal(),
            finalCut: checker, volume: TestVolumeChecker())
        let report = await executor.execute([try fs.request(), analysis], authorizedParent: fs.parent, permit: {}, progress: { _ in })
        #expect(report.completedCount == 1 && report.failedCount == 1 && trash.calls.count == 1)
    }

    @Test(arguments: ["content", "target", "symlink", "missing", "root"])
    func changedOrForbiddenRealTargetsNeverReachTrash(_ mutation: String) async throws {
        let fixture = try TrashIntegrationFixture()
        var request = try #require(fixture.requests().first { $0.kind == .render })
        switch mutation {
        case "content": try Data(repeating: 9, count: 8_193).write(to: fixture.render.appendingPathComponent("nested/cache.dat"))
        case "root": request = CleanupRequest(libraryURL: fixture.library, kind: .render,
            candidate: CacheCandidate(url: fixture.library, bytes: 0))
        default:
            try FileManager.default.moveItem(at: fixture.render, to: fixture.render.appendingPathExtension("saved"))
            if mutation == "target" { try FileManager.default.createDirectory(at: fixture.render, withIntermediateDirectories: true) }
            if mutation == "symlink" { try FileManager.default.createSymbolicLink(at: fixture.render, withDestinationURL: fixture.parent) }
        }
        let trash = TestTrash()
        let executor = CleanupExecutor(trash: trash, journal: TestCleanupJournal(), finalCut: TestFinalCutChecker())
        let report = await executor.execute([request], authorizedParent: fixture.parent, permit: {}, progress: { _ in })
        #expect(report.failedCount == 1 && trash.calls.isEmpty)
        for (url, data) in fixture.protectedFiles { #expect(try Data(contentsOf: url) == data) }
    }

    @Test func finalRevalidationDetectsChildChangeDuringAuthorizationAwait() async throws {
        let fixture = try TrashIntegrationFixture(), trash = TestTrash()
        let request = try #require(fixture.requests().first { $0.kind == .render })
        let permit = MutatingPermit(file: fixture.render.appendingPathComponent("nested/cache.dat"))
        let executor = CleanupExecutor(trash: trash, journal: TestCleanupJournal(), finalCut: TestFinalCutChecker())
        let report = await executor.execute([request], authorizedParent: fixture.parent,
            permit: { try await permit.check() }, progress: { _ in })
        #expect(report.failedCount == 1 && trash.calls.isEmpty)
    }

    @Test func revokedAuthorizationIsLoggedWithoutMoving() async throws {
        let fs = SafetyFixture(), trash = TestTrash()
        let executor = CleanupExecutor(fileSystem: fs, trash: trash, journal: TestCleanupJournal(),
            finalCut: TestFinalCutChecker(), volume: TestVolumeChecker())
        let report = await executor.execute([try fs.request()], authorizedParent: fs.parent,
            permit: { throw CleanupExecutionError.authorizationChanged }, progress: { _ in })
        #expect(report.failedCount == 1 && trash.calls.isEmpty)
    }

    @Test(arguments: [Int(EACCES), Int(ENODEV), Int(ENOENT)])
    func inaccessibleOrDisconnectedTargetIsFailureNotZero(_ code: Int) async throws {
        var fs = SafetyFixture()
        let request = try fs.request(), trash = TestTrash()
        fs.failures[fs.target.path] = code
        let executor = CleanupExecutor(fileSystem: fs, trash: trash, journal: TestCleanupJournal(),
            finalCut: TestFinalCutChecker(), volume: TestVolumeChecker())
        let report = await executor.execute([request], authorizedParent: fs.parent, permit: {}, progress: { _ in })
        #expect(report.failedCount == 1 && report.completedCount == 0 && report.movedBytes == 0)
        #expect(report.entries.first?.detail != nil && trash.calls.isEmpty)
    }

    @Test func cancelledBeforeStartNeverCallsTrash() async throws {
        let fs = SafetyFixture(), trash = TestTrash(), journal = TestCleanupJournal()
        let request = try fs.request()
        let executor = CleanupExecutor(fileSystem: fs, trash: trash, journal: journal,
            finalCut: TestFinalCutChecker(), volume: TestVolumeChecker())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await executor.execute([request], authorizedParent: fs.parent, permit: {}, progress: { _ in })
        }
        let report = await task.value
        #expect(report.cancelledCount == 1 && report.completedCount == 0 && trash.calls.isEmpty)
        #expect(journal.entries.map(\.status) == [.cancelled])
    }

    @Test(arguments: [CleanupLogEntry.Status.pending, .completed])
    func journalFailureStopsFurtherMovesAndKeepsActualOutcome(_ failure: CleanupLogEntry.Status) async throws {
        let fs = SafetyFixture(), trash = TestTrash(), journal = TestCleanupJournal(failStatus: failure)
        let analysis = try fs.request(kind: .analysis, target: fs.library.appendingPathComponent("Event A/Analysis Files"))
        let executor = CleanupExecutor(fileSystem: fs, trash: trash, journal: journal,
            finalCut: TestFinalCutChecker(), volume: TestVolumeChecker())
        let report = await executor.execute([try fs.request(), analysis], authorizedParent: fs.parent, permit: {}, progress: { _ in })
        #expect(report.cancelledCount == 1 && report.entries.first?.journalError != nil)
        #expect(trash.calls.count == (failure == .pending ? 0 : 1))
        #expect(report.completedCount == (failure == .pending ? 0 : 1))
        #expect(report.failedCount == (failure == .pending ? 1 : 0))
    }

    @Test func realTrashMovesOnlyFixtureCachesAndPersistsFinalLogs() async throws {
        let fixture = try TrashIntegrationFixture()
        let fs = FoundationScanFileSystem()
        let protectedStamps = try fixture.protectedFiles.map { try fs.metadata(at: $0.0) }
        let requests = try fixture.requests().reversed()
        let logs = fixture.parent.appendingPathComponent("logs")
        // 先创建日志目录，再重新扫描，以免测试自己的创建动作改变授权父目录快照。
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let fresh = try fixture.requests()
        #expect(requests.count == fresh.count)
        let executor = CleanupExecutor(journal: FileCleanupJournal(directory: logs), finalCut: TestFinalCutChecker())
        let report = await executor.execute(Array(fresh.reversed()), authorizedParent: fixture.parent, permit: {}, progress: { _ in })
        #expect(report.completedCount == 2 && report.failedCount == 0)
        #expect(report.entries.first?.kind == CacheKind.render.rawValue)
        #expect(report.movedBytes == fresh.reduce(0) { $0 + $1.candidate.bytes })
        #expect(!FileManager.default.fileExists(atPath: fixture.render.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.analysis.path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.path))
        for (index, file) in fixture.protectedFiles.enumerated() {
            #expect(try Data(contentsOf: file.0) == file.1)
            #expect(try fs.metadata(at: file.0) == protectedStamps[index])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for entry in report.entries {
            let saved = try decoder.decode(CleanupLogEntry.self,
                from: Data(contentsOf: logs.appendingPathComponent(entry.id.uuidString + ".json")))
            #expect(saved.status == .completed && saved.targetPath == entry.targetPath && saved.batchID == entry.batchID)
            let trashed = URL(fileURLWithPath: try #require(saved.trashPath))
            let relative = saved.kind == CacheKind.render.rawValue ? "nested/cache.dat" : ".hidden.dat"
            #expect(try Data(contentsOf: trashed.appendingPathComponent(relative)) ==
                Data(repeating: saved.kind == CacheKind.render.rawValue ? 7 : 8,
                     count: saved.kind == CacheKind.render.rawValue ? 8_193 : 19))
        }
        let rescanned = try LibraryScanner().scanParent(fixture.parent)
        #expect(!rescanned.hasIssues)
        #expect(rescanned.libraries.first?.hasNoSupportedCaches == true)
        // 不清空废纸篓、不删除临时目录，便于核对与恢复本次测试数据。
    }
}

private actor MutatingPermit {
    let file: URL
    var checks = 0
    init(file: URL) { self.file = file }
    func check() throws {
        checks += 1
        if checks == 2 { try Data(repeating: 1, count: 8_193).write(to: file) }
    }
}
