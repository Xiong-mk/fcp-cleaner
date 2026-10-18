// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

/// The mount path is only a string: all access uses SafetyFixture and injected readers.
private nonisolated struct MockExternalDiskFixture {
    let parent = URL(fileURLWithPath: "/Volumes/Mock External SSD/Projects")
    let fileSystem: SafetyFixture
    var library: URL { parent.appendingPathComponent("Demo.fcpbundle") }
    var render: URL { library.appendingPathComponent("Event A/Render Files/High Quality Media") }

    init() {
        var fixture = SafetyFixture()
        let prefix = parent.path
        fixture.nodes = Dictionary(uniqueKeysWithValues: fixture.nodes.map { path, original in
            var metadata = original
            metadata.stamp?.device = 42
            return (path.replacingOccurrences(of: "/allowed", with: prefix), metadata)
        })
        fileSystem = fixture
    }

    func renderRequest() throws -> CleanupRequest {
        let scan = try LibraryScanner(fileSystem: fileSystem).scanParent(parent)
        #expect(!scan.hasIssues)
        let library = try #require(scan.libraries.first)
        let measurement = try #require(library.measurements.first { $0.kind == .render })
        let candidate = try #require(measurement.candidates.first)
        #expect(candidate.snapshot != nil)
        return CleanupRequest(libraryURL: library.url, kind: .render, candidate: candidate)
    }
}

/// Switches only injected metadata; never queries the real path or a mounted volume.
private nonisolated final class ChangingCleanupVolumeResources: CleanupVolumeResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let failOnCheck: Int
    private let rejected: TestCleanupVolumeResources
    var volumeChecks: Int { lock.withLock { checks } }

    init(rejected: TestCleanupVolumeResources, failOnCheck: Int) {
        self.rejected = rejected
        self.failOnCheck = failOnCheck
    }

    func volumeProperties(at url: URL) throws -> CleanupVolumeProperties {
        let resources = lock.withLock {
            checks += 1
            return checks >= failOnCheck ? rejected : TestCleanupVolumeResources()
        }
        return try resources.volumeProperties(at: url)
    }

    func isUbiquitousItem(at url: URL) throws -> Bool? {
        let resources = lock.withLock {
            checks >= failOnCheck ? rejected : TestCleanupVolumeResources()
        }
        return try resources.isUbiquitousItem(at: url)
    }
}

@Suite @MainActor
struct ExternalDiskCleanupTests {
    @Test func mockedExternalDiskPassesScanPreviewAndExecution() async throws {
        let fixture = MockExternalDiskFixture()
        let request = try fixture.renderRequest()
        let originalNodes = fixture.fileSystem.nodes
        let preview = try DryRunCleaner(fileSystem: fixture.fileSystem)
            .preview([request], authorizedParent: fixture.parent)
        #expect(preview.eligibleCount == 1)
        #expect(preview.items.first?.request.candidate.url == fixture.render)

        let trash = TestTrash(), journal = TestCleanupJournal()
        let executor = CleanupExecutor(fileSystem: fixture.fileSystem, trash: trash, journal: journal,
            finalCut: TestFinalCutChecker(),
            volume: LocalCleanupVolumeChecker(resources: TestCleanupVolumeResources()))
        let report = await executor.execute([request], authorizedParent: fixture.parent,
                                            permit: {}, progress: { _ in })
        #expect(report.completedCount == 1 && report.failedCount == 0)
        #expect(report.movedBytes == request.candidate.bytes)
        #expect(trash.calls == [fixture.render])
        #expect(journal.entries.map(\.status) == [.pending, .completed])
        #expect(report.entries.first?.targetPath == fixture.render.path)
        #expect(fixture.fileSystem.nodes == originalNodes)
    }

    @Test(arguments: ["network", "readOnly", "disconnected", "cloud"], [1, 2])
    func rejectedExternalDiskStateAtEitherGateNeverReachesTrash(_ failure: String, _ failOnCheck: Int) async throws {
        let fixture = MockExternalDiskFixture(), request = try fixture.renderRequest()
        var rejected = TestCleanupVolumeResources()
        switch failure {
        case "network": rejected.properties = CleanupVolumeProperties(isLocal: false, isReadOnly: false)
        case "readOnly": rejected.properties = CleanupVolumeProperties(isLocal: true, isReadOnly: true)
        case "disconnected": rejected.volumeError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV))
        case "cloud": rejected.ubiquitousPaths = [fixture.parent.path]
        default: Issue.record("Unknown failure fixture: \(failure)")
        }
        let resources = ChangingCleanupVolumeResources(rejected: rejected, failOnCheck: failOnCheck)
        let trash = TestTrash(), journal = TestCleanupJournal(), finalCut = TestFinalCutChecker()
        let executor = CleanupExecutor(fileSystem: fixture.fileSystem, trash: trash, journal: journal,
            finalCut: finalCut, volume: LocalCleanupVolumeChecker(resources: resources))
        let report = await executor.execute([request], authorizedParent: fixture.parent,
                                            permit: {}, progress: { _ in })

        #expect(report.failedCount == 1 && report.completedCount == 0 && report.movedBytes == 0)
        #expect(trash.calls.isEmpty)
        #expect(resources.volumeChecks == failOnCheck)
        #expect(finalCut.checks == failOnCheck - 1)
        #expect(journal.entries.map(\.status) == [.pending, .failed])
        let entry = try #require(report.entries.first)
        #expect(entry.targetPath == fixture.render.path)
        #expect(entry.trashPath == nil && entry.journalError == nil)
        let expectedDetail = failure == "disconnected"
            ? NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV)).localizedDescription
            : CleanupExecutionError.unsupportedVolume.localizedDescription
        #expect(entry.detail == expectedDetail)
    }

    @Test func writableLocalPolicyMovesOnlySelectedTemporaryRenderAndPersistsResult() async throws {
        // Only this newly created temporary fixture reaches the real trash API.
        let fixture = try TrashIntegrationFixture()
        let logs = fixture.parent.appendingPathComponent("external-policy-logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let fileSystem = FoundationScanFileSystem()
        let protected = fixture.protectedFiles + [
            (fixture.analysis.appendingPathComponent(".hidden.dat"), Data(repeating: 8, count: 19))
        ]
        let before = try protected.map { try fileSystem.metadata(at: $0.0) }
        let analysisBefore = try fileSystem.metadata(at: fixture.analysis)
        let request = try #require(fixture.requests().first { $0.kind == .render })
        let preview = try DryRunCleaner().preview([request], authorizedParent: fixture.parent)
        #expect(preview.eligibleCount == 1)

        let executor = CleanupExecutor(journal: FileCleanupJournal(directory: logs),
            finalCut: TestFinalCutChecker(),
            volume: LocalCleanupVolumeChecker(resources: TestCleanupVolumeResources()))
        let report = await executor.execute([request], authorizedParent: fixture.parent,
                                            permit: {}, progress: { _ in })
        #expect(report.completedCount == 1 && report.failedCount == 0)
        #expect(report.movedBytes == request.candidate.bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.render.path))
        #expect(FileManager.default.fileExists(atPath: fixture.library.path))
        #expect(try fileSystem.metadata(at: fixture.analysis) == analysisBefore)
        for (index, file) in protected.enumerated() {
            #expect(try Data(contentsOf: file.0) == file.1)
            #expect(try fileSystem.metadata(at: file.0) == before[index])
        }

        let entry = try #require(report.entries.first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(CleanupLogEntry.self,
            from: Data(contentsOf: logs.appendingPathComponent(entry.id.uuidString + ".json")))
        #expect(saved.status == .completed && saved.targetPath == fixture.render.path)
        #expect(saved.kind == CacheKind.render.rawValue && saved.batchID == entry.batchID)
        #expect(saved.estimatedBytes == request.candidate.bytes)
        #expect(saved.journalError == nil && saved.trashPath == entry.trashPath)
        let trashPath = try #require(saved.trashPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: trashPath).appendingPathComponent("nested/cache.dat"))
            == Data(repeating: 7, count: 8_193))

        let scan = try LibraryScanner().scanParent(fixture.parent)
        #expect(!scan.hasIssues)
        let library = try #require(scan.libraries.first)
        let render = try #require(library.measurements.first { $0.kind == .render })
        let analysis = try #require(library.measurements.first { $0.kind == .analysis })
        #expect(render.bytes == 0 && render.candidates.isEmpty)
        #expect(analysis.candidates.count == 1 && analysis.candidates.first?.url.path == fixture.analysis.path)
        let analysisBytes = try #require(analysis.bytes)
        #expect(analysisBytes > 0)
        // Keep generated fixtures and trash contents available for inspection and recovery.
    }
}
