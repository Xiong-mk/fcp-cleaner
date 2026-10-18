// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

/// 故意允许无效枚举，验证读取器不会信任适配器提供的目录边界或容量。
nonisolated private struct TreeReaderFileSystem: LibraryScanFileSystem {
    var entries: [String: [URL]] = [:]
    var nodes: [String: ScanFileMetadata] = [:]

    func children(of url: URL) throws -> [URL] {
        guard let children = entries[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
        return children
    }

    func metadata(at url: URL) throws -> ScanFileMetadata {
        guard let node = nodes[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
        return node
    }

    mutating func directory(_ path: String, children: [String] = []) {
        nodes[path] = ScanFileMetadata(isDirectory: true)
        entries[path] = children.map { URL(fileURLWithPath: $0) }
    }
}

@Suite
struct CacheTreeReaderTests {
    private let target = URL(fileURLWithPath: "/fixture/Analysis Files")

    @Test func emptyNestedDirectoriesHaveZeroBytesAndRemainInSnapshot() throws {
        var fs = TreeReaderFileSystem()
        let nested = target.appendingPathComponent(".empty")
        fs.directory(target.path, children: [nested.path])
        fs.directory(nested.path)

        let tree = try CacheTreeReader(fileSystem: fs).read(target)

        #expect(tree.bytes == 0)
        #expect(Set(tree.entries.keys) == [target.path, nested.path])
        #expect(tree.entries.values.allSatisfy { $0.isDirectory })
    }

    @Test(arguments: [Int64(-1), Int64.min])
    func negativeAllocatedBytesAreFailuresRatherThanReducingTotal(_ bytes: Int64) throws {
        var fs = TreeReaderFileSystem()
        let file = target.appendingPathComponent("invalid.dat")
        fs.directory(target.path, children: [file.path])
        fs.nodes[file.path] = ScanFileMetadata(isRegularFile: true, allocatedBytes: bytes)

        do {
            _ = try CacheTreeReader(fileSystem: fs).read(target)
            Issue.record("负容量不得计入缓存总量")
        } catch let issue as ScanIssue {
            #expect(issue.url == file)
            #expect(issue.reason == .failed)
        }
    }

    @Test func acceptsLargestRepresentableTotalWithoutWrapping() throws {
        var fs = TreeReaderFileSystem()
        let file = target.appendingPathComponent("large.dat")
        fs.directory(target.path, children: [file.path])
        fs.nodes[file.path] = ScanFileMetadata(isRegularFile: true, allocatedBytes: Int64.max)

        #expect(try CacheTreeReader(fileSystem: fs).read(target).bytes == Int64.max)
    }

    @Test func accumulatedBytesOverflowAcrossNestedDirectoriesFailsExplicitly() throws {
        var fs = TreeReaderFileSystem()
        let large = target.appendingPathComponent("large.dat")
        let nested = target.appendingPathComponent("nested")
        let extra = nested.appendingPathComponent("extra.dat")
        fs.directory(target.path, children: [large.path, nested.path])
        fs.directory(nested.path, children: [extra.path])
        fs.nodes[large.path] = ScanFileMetadata(isRegularFile: true, allocatedBytes: Int64.max)
        fs.nodes[extra.path] = ScanFileMetadata(isRegularFile: true, allocatedBytes: 1)

        do {
            _ = try CacheTreeReader(fileSystem: fs).read(target)
            Issue.record("容量溢出必须报告失败，不能回绕为负值或 0 B")
        } catch let issue as ScanIssue {
            #expect(issue.url == extra)
            #expect(issue.reason == .failed)
        }
    }

    @Test(arguments: ["/outside/cache.dat", "/fixture/Analysis Files/nested/cache.dat", "/fixture/Analysis Files"])
    func rejectsEnumerationOutsideImmediateChildren(_ path: String) {
        var fs = TreeReaderFileSystem()
        fs.directory(target.path, children: [path])
        // 不提供该路径的元数据；必须先拒绝边界，再尝试读取它。
        #expect(throws: CleanupSafetyError.outsideLibrary) {
            try CacheTreeReader(fileSystem: fs).read(target)
        }
    }

    @Test func duplicateEntriesCannotDoubleCountCapacity() {
        var fs = TreeReaderFileSystem()
        let file = target.appendingPathComponent("repeated.dat")
        fs.directory(target.path, children: [file.path, file.path])
        fs.nodes[file.path] = ScanFileMetadata(isRegularFile: true, allocatedBytes: 3)

        #expect(throws: CleanupSafetyError.outsideLibrary) {
            try CacheTreeReader(fileSystem: fs).read(target)
        }
    }

    @Test func directoryEnumerationCycleIsRejected() {
        var fs = TreeReaderFileSystem()
        let nested = target.appendingPathComponent("nested")
        fs.directory(target.path, children: [nested.path])
        fs.directory(nested.path, children: [target.path])

        #expect(throws: CleanupSafetyError.outsideLibrary) {
            try CacheTreeReader(fileSystem: fs).read(target)
        }
    }

    @Test func unsupportedSpecialFileCannotProduceSuccessfulPartialTotal() throws {
        var fs = TreeReaderFileSystem()
        let special = target.appendingPathComponent("socket")
        fs.directory(target.path, children: [special.path])
        fs.nodes[special.path] = ScanFileMetadata(allocatedBytes: 0)

        do {
            _ = try CacheTreeReader(fileSystem: fs).read(target)
            Issue.record("特殊文件不得被静默忽略")
        } catch let issue as ScanIssue {
            #expect(issue.url == special)
            #expect(issue.reason == .failed)
        }
    }
}
