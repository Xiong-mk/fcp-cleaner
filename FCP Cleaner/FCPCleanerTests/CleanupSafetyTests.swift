// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

nonisolated struct SafetyFixture: LibraryScanFileSystem {
    var nodes: [String: ScanFileMetadata] = [:]
    var failures: [String: Int] = [:]
    var canonicalPaths: [String: String] = [:]
    let parent = URL(fileURLWithPath: "/allowed")
    let library = URL(fileURLWithPath: "/allowed/Demo.fcpbundle")
    let target = URL(fileURLWithPath: "/allowed/Demo.fcpbundle/Event A/Render Files/High Quality Media")

    init() {
        for path in [parent.path, library.path, library.path + "/Event A",
                     library.path + "/Event A/Render Files", target.path,
                     library.path + "/Event A/Analysis Files"] {
            nodes[path] = ScanFileMetadata(isDirectory: true, stamp: stamp(UInt64(nodes.count + 1)))
        }
        nodes[target.path + "/cache.dat"] = ScanFileMetadata(
            isRegularFile: true, allocatedBytes: 12, stamp: stamp(100)
        )
    }

    func stamp(_ inode: UInt64) -> ScanFileStamp {
        ScanFileStamp(device: 1, inode: inode, birthSeconds: 1, birthNanoseconds: 0,
                      modificationSeconds: 2, modificationNanoseconds: 0,
                      changeSeconds: 2, changeNanoseconds: 0, logicalBytes: 12, linkCount: 1)
    }

    func metadata(at url: URL) throws -> ScanFileMetadata {
        if let code = failures[url.path] { throw NSError(domain: NSPOSIXErrorDomain, code: code) }
        guard let node = nodes[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
        return node
    }

    func children(of url: URL) throws -> [URL] {
        _ = try metadata(at: url)
        return nodes.keys.map { URL(fileURLWithPath: $0) }
            .filter { $0.deletingLastPathComponent().path == url.path }
            .sorted { $0.path < $1.path }
    }

    func canonicalURL(for url: URL) throws -> URL {
        URL(fileURLWithPath: canonicalPaths[url.path] ?? url.path)
    }

    func request(kind: CacheKind = .render, target override: URL? = nil) throws -> CleanupRequest {
        let url = override ?? target
        let snapshot = try CleanupSafety(fileSystem: self).capture(
            url, kind: kind, library: library, authorizedParent: parent
        )
        return CleanupRequest(libraryURL: library, kind: kind,
                              candidate: CacheCandidate(url: url, bytes: snapshot.bytes, snapshot: snapshot))
    }
}

@Suite
struct CleanupSafetyTests {
    @Test(arguments: [
        "/allowed/Demo.fcpbundle-other/Event/Analysis Files",
        "/outside/Demo.fcpbundle/Event/Analysis Files",
        "/allowed/Demo.fcpbundle/../Other.fcpbundle/Event/Analysis Files",
        "/allowed/Demo.fcpbundle/Event A/Render Files/../Analysis Files"
    ])
    func rejectsBoundaryAndTraversalPaths(_ path: String) throws {
        let fs = SafetyFixture()
        let expected: CleanupSafetyError = path.contains("..") ? .traversal : .outsideLibrary
        #expect(throws: expected) {
            try CleanupSafety(fileSystem: fs).capture(URL(fileURLWithPath: path), kind: .analysis,
                                                      library: fs.library, authorizedParent: fs.parent)
        }
    }

    @Test(arguments: ["", "/Event A", "/Event A/Original Media", "/Event A/Transcoded Media",
                      "/Event A/Render Files", "/Event A/Render Files/Proxy Media",
                      "/Event A/Nested/Analysis Files", "/Event A/Analysis Files/nested",
                      "/Event A/analysis files", "/Event A/CurrentVersion.fcpevent"])
    func rejectsEveryNonWhitelistedDepthAndName(_ relative: String) throws {
        let fs = SafetyFixture()
        #expect(throws: relative.isEmpty ? CleanupSafetyError.outsideLibrary : .unexpectedPath) {
            try CleanupSafety(fileSystem: fs).capture(URL(fileURLWithPath: fs.library.path + relative),
                                                      kind: .analysis, library: fs.library, authorizedParent: fs.parent)
        }
    }

    @Test(arguments: ["/allowed", "/allowed/Demo.fcpbundle", "/allowed/Demo.fcpbundle/Event A",
                      "/allowed/Demo.fcpbundle/Event A/Render Files",
                      "/allowed/Demo.fcpbundle/Event A/Render Files/High Quality Media",
                      "/allowed/Demo.fcpbundle/Event A/Render Files/High Quality Media/cache.dat"])
    func rejectsSymbolicLinkAtEveryLevelIncludingDescendants(_ path: String) {
        var fs = SafetyFixture()
        fs.nodes[path]?.isSymbolicLink = true
        #expect(throws: (any Error).self) { try fs.request() }
    }

    @Test func sameNamedLibrariesAndTargetsUseCompletePaths() throws {
        let first = SafetyFixture()
        var second = SafetyFixture()
        second.nodes = Dictionary(uniqueKeysWithValues: first.nodes.map { ($0.key.replacingOccurrences(of: "/allowed", with: "/second"), $0.value) })
        let target = URL(fileURLWithPath: first.target.path.replacingOccurrences(of: "/allowed", with: "/second"))
        let library = URL(fileURLWithPath: "/second/Demo.fcpbundle")
        let parent = URL(fileURLWithPath: "/second")
        let snapshot = try CleanupSafety(fileSystem: second).capture(target, kind: .render, library: library, authorizedParent: parent)
        let other = CleanupRequest(libraryURL: library, kind: .render,
                                   candidate: CacheCandidate(url: target, bytes: snapshot.bytes, snapshot: snapshot))
        let original = try first.request()
        #expect(original.id != other.id)
        #expect(try DryRunCleaner(fileSystem: first).preview([original], authorizedParent: first.parent).eligibleCount == 1)
        #expect(try DryRunCleaner(fileSystem: second).preview([other], authorizedParent: parent).eligibleCount == 1)
        let preview = try DryRunCleaner(fileSystem: first).preview([other], authorizedParent: first.parent)
        #expect(preview.items.first?.isEligible == false)
        #expect(throws: CleanupSafetyError.self) {
            try CleanupSafety(fileSystem: second).revalidate(original, authorizedParent: parent)
        }
    }

    @Test(arguments: ["inode", "mtime", "ctime", "size", "device", "birth", "child", "ancestor"])
    func refusesChangesSinceOriginalScan(_ mutation: String) throws {
        var fs = SafetyFixture()
        let request = try fs.request()
        let path = mutation == "child" ? fs.target.path + "/cache.dat" : mutation == "ancestor" ? fs.library.path : fs.target.path
        switch mutation {
        case "inode", "ancestor", "child": fs.nodes[path]?.stamp?.inode += 1
        case "mtime": fs.nodes[path]?.stamp?.modificationNanoseconds += 1
        case "ctime": fs.nodes[path]?.stamp?.changeNanoseconds += 1
        case "size": fs.nodes[path]?.stamp?.logicalBytes += 1
        case "device": fs.nodes[path]?.stamp?.device += 1
        case "birth": fs.nodes[path]?.stamp?.birthNanoseconds += 1
        default: break
        }
        #expect(throws: (any Error).self) {
            try CleanupSafety(fileSystem: fs).revalidate(request, authorizedParent: fs.parent)
        }
    }

    @Test func contentMembershipChangeEvenWithUnchangedDirectoryStampIsRejected() throws {
        var fs = SafetyFixture()
        let request = try fs.request()
        fs.nodes[fs.target.path + "/new.dat"] = fs.nodes[fs.target.path + "/cache.dat"]
        #expect(throws: CleanupSafetyError.self) {
            try CleanupSafety(fileSystem: fs).revalidate(request, authorizedParent: fs.parent)
        }
    }

    @Test func missingRenamedTargetRequiresRescan() throws {
        var fs = SafetyFixture()
        let request = try fs.request()
        fs.nodes[fs.target.path] = nil
        let result = try DryRunCleaner(fileSystem: fs).preview([request], authorizedParent: fs.parent)
        #expect(result.items.first?.isEligible == false)
        #expect(result.eligibleBytes == 0)
    }

    @Test func onlyExactPathsAndMatchingKindsPass() throws {
        let fs = SafetyFixture()
        let request = try fs.request()
        try CleanupSafety(fileSystem: fs).revalidate(request, authorizedParent: fs.parent)
        let analysis = try fs.request(kind: .analysis, target: fs.library.appendingPathComponent("Event A/Analysis Files"))
        try CleanupSafety(fileSystem: fs).revalidate(analysis, authorizedParent: fs.parent)
        let wrongKind = CleanupRequest(libraryURL: fs.library, kind: .analysis, candidate: request.candidate)
        #expect(throws: CleanupSafetyError.self) {
            try CleanupSafety(fileSystem: fs).revalidate(wrongKind, authorizedParent: fs.parent)
        }
    }

    @Test func rejectsAliasesMissingIdentityAndCanonicalEscape() throws {
        let original = SafetyFixture()
        for mutation in ["alias", "identity", "canonical", "file"] {
            var fs = original
            switch mutation {
            case "alias": fs.nodes[fs.target.path]?.isAlias = true
            case "identity": fs.nodes[fs.target.path]?.stamp = nil
            case "canonical": fs.canonicalPaths[fs.target.path] = "/outside/High Quality Media"
            case "file": fs.nodes[fs.target.path]?.isDirectory = false
            default: break
            }
            #expect(throws: (any Error).self) { try fs.request() }
        }
    }

    @Test(arguments: [Int(EACCES), Int(ENODEV), Int(ENOENT)])
    func readFailureIsBlockedWithReasonAndNoEligibleCapacity(_ code: Int) throws {
        var fs = SafetyFixture()
        let request = try fs.request()
        fs.failures[fs.target.path] = code
        let result = try DryRunCleaner(fileSystem: fs).preview([request], authorizedParent: fs.parent)
        let item = try #require(result.items.first)
        #expect(!item.isEligible)
        #expect(item.blockedReason?.isEmpty == false)
        #expect(result.eligibleBytes == 0)
    }

    @Test func rejectsNonLocalURLsWrongLibraryRootAndCrossVolumeDescendants() throws {
        var fs = SafetyFixture()
        for target in [URL(string: "https://example.com/cache")!, URL(string: "file://remote/allowed/Demo.fcpbundle/Event/Analysis%20Files")!] {
            #expect(throws: CleanupSafetyError.invalidURL) {
                try CleanupSafety(fileSystem: fs).capture(target, kind: .analysis, library: fs.library, authorizedParent: fs.parent)
            }
        }
        #expect(throws: CleanupSafetyError.outsideLibrary) {
            try CleanupSafety(fileSystem: fs).capture(fs.target, kind: .render,
                                                      library: URL(fileURLWithPath: "/allowed/Demo.folder"), authorizedParent: fs.parent)
        }
        #expect(throws: CleanupSafetyError.invalidURL) {
            try CleanupSafety(fileSystem: fs).capture(fs.target, kind: .render, library: fs.library,
                                                      authorizedParent: URL(fileURLWithPath: "/"))
        }
        fs.nodes[fs.target.path + "/cache.dat"]?.stamp?.device = 99
        #expect(throws: CleanupSafetyError.crossVolume) { try fs.request() }
    }
}
