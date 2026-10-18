// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

@Suite
struct DryRunCleanerTests {
    @Test func deduplicatesRequestsAndCountsOnlyEligibleItems() throws {
        let fs = SafetyFixture()
        let valid = try fs.request()
        let analysisURL = fs.library.appendingPathComponent("Event A/Analysis Files")
        let missingSnapshot = CleanupRequest(libraryURL: fs.library, kind: .analysis,
                                            candidate: CacheCandidate(url: analysisURL, bytes: 100))
        let preview = try DryRunCleaner(fileSystem: fs).preview([valid, valid, missingSnapshot], authorizedParent: fs.parent)
        #expect(preview.items.count == 2)
        #expect(preview.eligibleCount == 1)
        #expect(preview.eligibleBytes == 12)
        #expect(preview.estimatedBytes(for: []) == 0)
        #expect(preview.estimatedBytes(for: [missingSnapshot.id]) == 0)
        #expect(preview.estimatedBytes(for: [valid.id]) == 12)
    }

    @Test func cancellationPropagatesRatherThanBecomingAnEligiblePreview() async throws {
        let fs = SafetyFixture()
        let request = try fs.request()
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DryRunCleaner(fileSystem: fs).preview([request], authorizedParent: fs.parent)
        }
        let result = await worker.result
        if case .failure(let error) = result { #expect(error is CancellationError) }
        else { Issue.record("模拟清理未响应取消") }
    }

    @Test func selectedCapacityOverflowIsUnknownAndUnselectedItemsDoNotAffectEstimate() {
        let library = URL(fileURLWithPath: "/fixture/Demo.fcpbundle")
        let large = CleanupRequest(libraryURL: library, kind: .analysis,
            candidate: CacheCandidate(url: library.appendingPathComponent("Event A/Analysis Files"), bytes: Int64.max))
        let extra = CleanupRequest(libraryURL: library, kind: .analysis,
            candidate: CacheCandidate(url: library.appendingPathComponent("Event B/Analysis Files"), bytes: 1))
        let preview = CleanupPreview(items: [
            CleanupPreviewItem(request: large, blockedReason: nil),
            CleanupPreviewItem(request: extra, blockedReason: nil)
        ])

        #expect(preview.eligibleBytes == nil)
        #expect(preview.estimatedBytes(for: [large.id]) == Int64.max)
        #expect(preview.estimatedBytes(for: [extra.id]) == 1)
        #expect(preview.estimatedBytes(for: ["unknown-selection"]) == 0)
    }

    @Test func malformedNegativeCandidateCannotProduceAnEstimatedCapacity() {
        let library = URL(fileURLWithPath: "/fixture/Demo.fcpbundle")
        let request = CleanupRequest(libraryURL: library, kind: .analysis,
            candidate: CacheCandidate(url: library.appendingPathComponent("Event/Analysis Files"), bytes: -1))
        let preview = CleanupPreview(items: [CleanupPreviewItem(request: request, blockedReason: nil)])

        #expect(preview.eligibleBytes == nil)
        #expect(preview.estimatedBytes(for: [request.id]) == nil)
        #expect(preview.estimatedBytes(for: []) == 0)
    }

    @Test func scannerAndPreviewLeaveRealFixtureContentsAndMetadataUnchanged() throws {
        let fixture = try DryRunFixture()
        let fs = FoundationScanFileSystem()
        let before = try fixture.files.map { try fs.metadata(at: $0.0) }
        let library = try #require(LibraryScanner().scanParent(fixture.parent).libraries.first)
        let requests = library.measurements.flatMap { measurement in
            measurement.candidates.map { CleanupRequest(libraryURL: library.url, kind: measurement.kind, candidate: $0) }
        }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.candidate.snapshot != nil && $0.candidate.safetyIssue == nil })
        let directoryBefore = try fs.metadata(at: fixture.render)
        let preview = try DryRunCleaner().preview(requests, authorizedParent: fixture.parent)
        #expect(preview.eligibleCount == 2)
        #expect(preview.eligibleBytes == requests.reduce(0) { $0 + $1.candidate.bytes })
        #expect(try fs.metadata(at: fixture.render) == directoryBefore)
        for (index, file) in fixture.files.enumerated() {
            #expect(try Data(contentsOf: file.0) == file.1)
            #expect(try fs.metadata(at: file.0) == before[index])
        }
        // 同一输入反复预览不会扣减原候选容量，也不会把新对象更新为扫描基准。
        #expect(try DryRunCleaner().preview(requests, authorizedParent: fixture.parent).eligibleBytes == preview.eligibleBytes)
        #expect(library.measurements.flatMap(\.candidates).map(\.bytes) == requests.map(\.candidate.bytes))
    }

    @Test(arguments: ["target", "event", "library", "child", "symlink"])
    func realReplacementRenameAndSymlinkAfterScanAreRejected(_ mutation: String) throws {
        let fixture = try DryRunFixture()
        let library = try #require(LibraryScanner().scanParent(fixture.parent).libraries.first)
        let candidate = try #require(library.measurements.first { $0.kind == .render }?.candidates.first)
        let request = CleanupRequest(libraryURL: library.url, kind: .render, candidate: candidate)
        let fm = FileManager.default
        switch mutation {
        case "child":
            // 在原目录中改写文件，目录本身的 mtime 不必改变。
            try Data(repeating: 9, count: fixture.files[0].1.count).write(to: fixture.files[0].0)
        case "symlink":
            try fm.moveItem(at: fixture.render, to: fixture.render.appendingPathExtension("saved"))
            try fm.createSymbolicLink(at: fixture.render, withDestinationURL: fixture.original.deletingLastPathComponent())
        default:
            let path = mutation == "event" ? fixture.library.appendingPathComponent("Event A")
                : mutation == "library" ? fixture.library : fixture.render
            try fm.moveItem(at: path, to: path.appendingPathExtension("saved"))
            try fm.createDirectory(at: fixture.render, withIntermediateDirectories: true)
            try fixture.files[0].1.write(to: fixture.render.appendingPathComponent("cache.dat"))
        }
        let preview = try DryRunCleaner().preview([request], authorizedParent: fixture.parent)
        #expect(preview.eligibleCount == 0)
        #expect(preview.items.first?.blockedReason != nil)
        #expect(preview.eligibleBytes == 0)
        // 只在专用临时虚拟库中移动/写入模拟变化，无删除收尾。
    }

    @Test func realDanglingAndOutsideLinksAreRejectedWithoutFollowingThem() throws {
        let fixture = try DryRunFixture()
        for (name, destination) in [("outside", fixture.original), ("dangling", fixture.parent.appendingPathComponent("absent"))] {
            let link = fixture.render.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            #expect(throws: (any Error).self) {
                try CleanupSafety().capture(fixture.render, kind: .render, library: fixture.library, authorizedParent: fixture.parent)
            }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination.path)
        }
        #expect(try Data(contentsOf: fixture.original) == Data("keep original".utf8))
    }
}

nonisolated private struct DryRunFixture {
    let parent: URL
    let library: URL
    let render: URL
    let original: URL
    let files: [(URL, Data)]

    init() throws {
        let fm = FileManager.default
        parent = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DryRun-" + UUID().uuidString)
        library = parent.appendingPathComponent("Demo.fcpbundle")
        render = library.appendingPathComponent("Event A/Render Files/High Quality Media")
        original = library.appendingPathComponent("Event A/Original Media/important.mov")
        files = [
            (render.appendingPathComponent("cache.dat"), Data(repeating: 1, count: 8_193)),
            (library.appendingPathComponent("Event A/Analysis Files/.hidden.dat"), Data(repeating: 2, count: 17)),
            (original, Data("keep original".utf8)),
            (library.appendingPathComponent("Event A/Transcoded Media/proxy.mov"), Data("keep proxy".utf8)),
            (library.appendingPathComponent("Event A/CurrentVersion.fcpevent"), Data("keep database".utf8)),
            (parent.appendingPathComponent("Final Cut Backups/Demo.fcpbundle/backup"), Data("keep backup".utf8))
        ]
        for (file, data) in files {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }
}
