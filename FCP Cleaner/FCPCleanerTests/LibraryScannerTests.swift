// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

nonisolated private struct FixtureFileSystem: LibraryScanFileSystem {
    var entries: [String: [URL]] = [:]
    var attributes: [String: ScanFileMetadata] = [:]
    var errors: [String: Int] = [:]

    func children(of url: URL) throws -> [URL] {
        if let code = errors[url.path] { throw NSError(domain: NSPOSIXErrorDomain, code: code) }
        guard let children = entries[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
        return children
    }

    func metadata(at url: URL) throws -> ScanFileMetadata {
        if let code = errors[url.path + "#metadata"] { throw NSError(domain: NSPOSIXErrorDomain, code: code) }
        guard let info = attributes[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
        return info
    }

    mutating func directory(_ path: String) {
        attributes[path] = ScanFileMetadata(isDirectory: true)
        entries[path] = entries[path] ?? []
        appendToParent(path)
    }

    mutating func file(_ path: String, bytes: Int64? = 1) {
        attributes[path] = ScanFileMetadata(isRegularFile: true, allocatedBytes: bytes)
        appendToParent(path)
    }

    mutating func link(_ path: String, alias: Bool = false) {
        attributes[path] = ScanFileMetadata(isSymbolicLink: !alias, isAlias: alias)
        appendToParent(path)
    }

    private mutating func appendToParent(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        if entries[parent] != nil && !(entries[parent]?.contains(url) ?? false) {
            entries[parent]?.append(url)
        }
    }

    static func caches() -> Self {
        var fs = Self()
        for directory in [
            "/allowed", "/allowed/Demo.fcpbundle", "/allowed/Demo.fcpbundle/Event A",
            "/allowed/Demo.fcpbundle/Event A/Render Files",
            "/allowed/Demo.fcpbundle/Event A/Render Files/High Quality Media",
            "/allowed/Demo.fcpbundle/Event A/Render Files/High Quality Media/nested",
            "/allowed/Demo.fcpbundle/Event A/Analysis Files"
        ] { fs.directory(directory) }
        fs.file("/allowed/Demo.fcpbundle/Event A/Render Files/High Quality Media/nested/render.dat", bytes: 12)
        fs.file("/allowed/Demo.fcpbundle/Event A/Analysis Files/.hidden-cache", bytes: 7)
        return fs
    }
}

@Suite
struct LibraryScannerTests {
    private let parent = URL(fileURLWithPath: "/allowed")
    private let event = "/allowed/Demo.fcpbundle/Event A"

    @Test func discoversOnlyImmediateDirectoriesIncludingHiddenAndCaseInsensitiveExtensions() throws {
        var fs = FixtureFileSystem.caches()
        fs.directory("/allowed/Second.FCPBUNDLE")
        fs.directory("/allowed/.Hidden.fcpbundle")
        fs.file("/allowed/file.fcpbundle")
        fs.file("/allowed/movie.mov")
        fs.directory("/allowed/Other")
        fs.directory("/allowed/Other/Nested.fcpbundle")
        fs.errors["/allowed/Other"] = Int(EACCES)
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        #expect(Set(result.libraries.map(\.name)) == ["Demo.fcpbundle", "Second.FCPBUNDLE", ".Hidden.fcpbundle"])
        #expect(result.issues.isEmpty)
    }

    @Test func sumsBothKindsAcrossImmediateEventsAndRecursesOnlyInsideCaches() throws {
        var fs = FixtureFileSystem.caches()
        fs.directory("/allowed/Demo.fcpbundle/Event B")
        fs.directory("/allowed/Demo.fcpbundle/Event B/Analysis Files")
        fs.file("/allowed/Demo.fcpbundle/Event B/Analysis Files/second", bytes: 9)
        for directory in [
            event + "/Original Media", event + "/Transcoded Media",
            event + "/Render Files/Proxy Media", event + "/Nested",
            event + "/Nested/Analysis Files"
        ] {
            fs.directory(directory)
            fs.errors[directory] = Int(EACCES)
        }
        fs.file(event + "/CurrentVersion.fcpevent", bytes: 100_000)
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        let library = try #require(result.libraries.first)
        #expect(!result.hasIssues)
        #expect(library.measurements[0].bytes == 12)
        #expect(library.measurements[1].bytes == 16)
        #expect(library.measurements[1].candidates.count == 2)
    }

    @Test func distinguishesNoLibrariesNoSupportedCachesAndEmptyCache() throws {
        var fs = FixtureFileSystem()
        fs.directory("/allowed")
        let scanner = LibraryScanner(fileSystem: fs)
        #expect(try scanner.scanParent(parent).libraries.isEmpty)
        fs.directory("/allowed/Empty.fcpbundle")
        var library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(library.hasNoSupportedCaches)
        #expect(library.measurements.allSatisfy { $0.bytes == 0 && $0.sizeDescription == "0 B" })
        fs.directory("/allowed/Empty.fcpbundle/Event")
        fs.directory("/allowed/Empty.fcpbundle/Event/Analysis Files")
        library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(!library.hasNoSupportedCaches)
        #expect(library.measurements[1].candidates.count == 1)
        #expect(library.measurements[1].bytes == 0)
    }

    @Test(arguments: [Int(EACCES), Int(ENODEV), Int(EBUSY)])
    func parentFailuresAreExplicit(_ code: Int) throws {
        var fs = FixtureFileSystem.caches()
        fs.errors[parent.path] = code
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        #expect(result.libraries.isEmpty)
        let issue = try #require(result.issues.first)
        #expect(issue.url == parent)
        #expect(issue.reason == (code == Int(EACCES) ? .permission : code == Int(ENODEV) ? .unavailable : .failed))
    }

    @Test func unreadableLibraryDoesNotHideHealthySibling() throws {
        var fs = FixtureFileSystem.caches()
        fs.directory("/allowed/Broken.fcpbundle")
        fs.errors["/allowed/Broken.fcpbundle"] = Int(EACCES)
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        #expect(result.libraries.count == 2)
        let broken = try #require(result.libraries.first { $0.name == "Broken.fcpbundle" })
        #expect(broken.measurements.allSatisfy { $0.bytes == nil })
        #expect(result.libraries.first { $0.name == "Demo.fcpbundle" }?.measurements[0].bytes == 12)
    }

    @Test func unreadableEventMakesBothTotalsIncomplete() throws {
        var fs = FixtureFileSystem.caches()
        fs.directory("/allowed/Demo.fcpbundle/Unreadable")
        fs.errors["/allowed/Demo.fcpbundle/Unreadable"] = Int(EACCES)
        let library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(library.measurements.allSatisfy { $0.bytes == nil })
        #expect(library.measurements[0].candidates.first?.bytes == 12)
        #expect(library.measurements[0].issues.first?.url.path == "/allowed/Demo.fcpbundle/Unreadable")
    }

    @Test func nestedTraversalErrorInvalidatesOnlyAffectedCategory() throws {
        var fs = FixtureFileSystem.caches()
        let failedPath = event + "/Render Files/High Quality Media/nested"
        fs.errors[failedPath] = Int(EACCES)
        let library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(library.measurements[0].bytes == nil)
        #expect(library.measurements[0].sizeDescription == "统计不完整")
        #expect(library.measurements[0].issues.first?.url.path == failedPath)
        #expect(library.measurements[1].bytes == 7)
    }

    @Test func disappearanceDuringScanIsNotAbsenceOfCache() throws {
        var fs = FixtureFileSystem.caches()
        fs.errors[event + "/Analysis Files#metadata"] = Int(ENOENT)
        let library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(library.measurements[1].bytes == nil)
        #expect(library.measurements[1].issues.first?.reason == .unavailable)
        #expect(library.measurements[0].bytes == 12)
    }

    @Test func missingSizeMetadataNeverFallsBackToZero() throws {
        var fs = FixtureFileSystem.caches()
        fs.file(event + "/Analysis Files/unknown", bytes: nil)
        let library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(library.measurements[1].bytes == nil)
        #expect(!library.measurements[1].issues.isEmpty)
    }

    @Test func categoryCapacityOverflowDoesNotHideHealthySiblingCategory() throws {
        var fs = FixtureFileSystem.caches()
        let secondEvent = "/allowed/Demo.fcpbundle/Event B"
        let secondCache = secondEvent + "/Analysis Files"
        fs.directory(secondEvent)
        fs.directory(secondCache)
        fs.file(secondCache + "/large.dat", bytes: Int64.max)

        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        let library = try #require(result.libraries.first)
        let render = try #require(library.measurements.first { $0.kind == .render })
        let analysis = try #require(library.measurements.first { $0.kind == .analysis })

        #expect(result.hasIssues)
        #expect(render.bytes == 12)
        #expect(render.issues.isEmpty)
        #expect(analysis.bytes == nil)
        #expect(analysis.candidates.count == 1)
        #expect(analysis.issues.count == 1)
        #expect(analysis.issues.first?.reason == .failed)
        #expect(analysis.issues.first?.detail.contains("同类缓存总容量") == true)
    }

    @Test(arguments: [false, true])
    func libraryStorageReferencesAreNotEventScanFailures(_ alias: Bool) throws {
        var fs = FixtureFileSystem.caches()
        for name in [".fcpcache", ".fcpdata"] {
            let path = "/allowed/Demo.fcpbundle/" + name
            fs.link(path, alias: alias)
            // 引用目标可能离线或无权读取；这些库根元数据不在事件缓存白名单内。
            fs.errors[path] = Int(EACCES)
            fs.errors[path + "#metadata"] = Int(EACCES)
        }
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        let library = try #require(result.libraries.first)
        #expect(!result.hasIssues)
        #expect(library.measurements[0].bytes == 12)
        #expect(library.measurements[1].bytes == 7)
        #expect(library.measurements.allSatisfy { $0.candidates.count == 1 })
        #expect(Set(library.skippedPackageLinks.map(\.lastPathComponent)) == [".fcpcache", ".fcpdata"])
    }

    @Test func externalDiskScreenshotLayoutKeepsBothCacheTotalsComplete() throws {
        let folder = "/Volumes/Mock External SSD/Projects"
        let bundle = folder + "/Demo.fcpbundle"
        var fs = FixtureFileSystem()
        fs.directory(folder)
        fs.directory(bundle)
        fs.link(bundle + "/.fcpcache")
        fs.link(bundle + "/.fcpdata", alias: true)
        for (name, bytes) in [("2026-10-17", Int64(13)), ("2026-10-18", Int64(19))] {
            let eventPath = bundle + "/" + name
            fs.directory(eventPath)
            fs.directory(eventPath + "/Render Files")
            fs.directory(eventPath + "/Render Files/High Quality Media")
            fs.directory(eventPath + "/Analysis Files")
            fs.file(eventPath + "/Render Files/High Quality Media/render.dat", bytes: bytes)
            fs.file(eventPath + "/Analysis Files/analysis.dat", bytes: bytes + 1)
        }
        let result = try LibraryScanner(fileSystem: fs).scanParent(URL(fileURLWithPath: folder))
        let library = try #require(result.libraries.first)
        #expect(result.libraries.count == 1)
        #expect(!result.hasIssues)
        #expect(library.measurements[0].bytes == 32)
        #expect(library.measurements[1].bytes == 34)
        #expect(library.measurements.allSatisfy { $0.candidates.count == 2 })
        #expect(Set(library.skippedPackageLinks.map(\.path)) == [bundle + "/.fcpcache", bundle + "/.fcpdata"])
    }

    @Test func hiddenEventAndHiddenCacheContentsRemainInScanScope() throws {
        var fs = FixtureFileSystem.caches()
        let hiddenEvent = "/allowed/Demo.fcpbundle/.Hidden Event"
        fs.directory(hiddenEvent)
        fs.directory(hiddenEvent + "/Analysis Files")
        fs.file(hiddenEvent + "/Analysis Files/.hidden-analysis", bytes: 11)
        fs.link("/allowed/Demo.fcpbundle/.fcpcache")
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        let library = try #require(result.libraries.first)
        #expect(!result.hasIssues)
        #expect(library.measurements[0].bytes == 12)
        #expect(library.measurements[1].bytes == 18)
        #expect(library.measurements[1].candidates.count == 2)
    }

    @Test(arguments: ["Linked Event", ".Hidden Event", ".fcpcache Event", ".fcpdata.backup"], [false, true])
    func actualEventReferencesRemainIncompleteEvenWithStorageReferences(_ name: String, _ alias: Bool) throws {
        var fs = FixtureFileSystem.caches()
        fs.link("/allowed/Demo.fcpbundle/.fcpcache")
        fs.link("/allowed/Demo.fcpbundle/.fcpdata", alias: true)
        let linkedEvent = "/allowed/Demo.fcpbundle/" + name
        fs.link(linkedEvent, alias: alias)
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        let library = try #require(result.libraries.first)
        #expect(result.issues.isEmpty)
        #expect(library.measurements.allSatisfy { $0.bytes == nil })
        #expect(library.measurements.allSatisfy {
            $0.issues.count == 1 && $0.issues.first?.url.path == linkedEvent
                && $0.issues.first?.reason == .excluded
        })
        #expect(library.measurements[0].candidates.first?.bytes == 12)
        #expect(library.measurements[1].candidates.first?.bytes == 7)
        #expect(Set(library.skippedPackageLinks.map(\.lastPathComponent)) == [".fcpcache", ".fcpdata"])
    }

    @Test(arguments: ["Render Files", "Render Files/High Quality Media", "Analysis Files"], [false, true])
    func actualCacheReferencesRemainIncomplete(_ component: String, _ alias: Bool) throws {
        var fs = FixtureFileSystem.caches()
        fs.link("/allowed/Demo.fcpbundle/.fcpcache")
        fs.link("/allowed/Demo.fcpbundle/.fcpdata", alias: true)
        let path = event + "/" + component
        fs.link(path, alias: alias)
        let library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        let affected = component == "Analysis Files" ? 1 : 0
        #expect(library.measurements[affected].bytes == nil)
        #expect(library.measurements[affected].issues.count == 1)
        #expect(library.measurements[affected].issues.first?.url.path == path)
        #expect(library.measurements[affected].issues.first?.reason == .excluded)
        #expect(library.measurements[1 - affected].bytes == (affected == 0 ? 7 : 12))
    }

    @Test(arguments: [".fcpcache", ".fcpdata"], [false, true])
    func storageReferenceNamesInsideCacheRemainExcluded(_ name: String, _ alias: Bool) throws {
        var fs = FixtureFileSystem.caches()
        let path = event + "/Analysis Files/" + name
        fs.link(path, alias: alias)
        let library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(library.skippedPackageLinks.isEmpty)
        #expect(library.measurements[0].bytes == 12)
        #expect(library.measurements[1].bytes == nil)
        #expect(library.measurements[1].issues.count == 1)
        #expect(library.measurements[1].issues.first?.url.path == path)
        #expect(library.measurements[1].issues.first?.reason == .excluded)
    }

    @Test func rejectsLinksAtLibraryEventRenderContainerTargetAndDescendant() throws {
        var fs = FixtureFileSystem.caches()
        fs.link("/allowed/Linked.fcpbundle")
        fs.link("/allowed/Alias.fcpbundle", alias: true)
        fs.link("/allowed/Demo.fcpbundle/Linked Event")
        fs.link(event + "/Analysis Files/escape")
        fs.directory("/allowed/Demo.fcpbundle/Event B")
        fs.link("/allowed/Demo.fcpbundle/Event B/Render Files")
        fs.directory("/allowed/Demo.fcpbundle/Event C")
        fs.directory("/allowed/Demo.fcpbundle/Event C/Render Files")
        fs.link("/allowed/Demo.fcpbundle/Event C/Render Files/High Quality Media")
        let result = try LibraryScanner(fileSystem: fs).scanParent(parent)
        #expect(result.libraries.count == 1)
        #expect(result.issues.count == 2)
        let library = try #require(result.libraries.first)
        #expect(library.measurements.allSatisfy { $0.bytes == nil })
        #expect(library.measurements[0].issues.count == 3)
        #expect(library.measurements[1].issues.count == 2)
        #expect(library.measurements.flatMap(\.issues).allSatisfy { $0.reason == .excluded })
    }

    @Test func candidatePathThatIsAFileIsAnError() throws {
        var fs = FixtureFileSystem.caches()
        fs.attributes[event + "/Analysis Files"] = ScanFileMetadata(isRegularFile: true, allocatedBytes: 200)
        let library = try #require(LibraryScanner(fileSystem: fs).scanParent(parent).libraries.first)
        #expect(library.measurements[1].bytes == nil)
        #expect(library.measurements[0].bytes == 12)
    }

    @Test func sameNamedLibrariesInDifferentParentsHaveDifferentIdentities() throws {
        var fs = FixtureFileSystem.caches()
        fs.directory("/second")
        fs.directory("/second/Demo.fcpbundle")
        let scanner = LibraryScanner(fileSystem: fs)
        let first = try #require(scanner.scanParent(parent).libraries.first)
        let second = try #require(scanner.scanParent(URL(fileURLWithPath: "/second")).libraries.first)
        #expect(first.name == second.name)
        #expect(first.id != second.id)
    }

    @Test func cancellationStopsTraversal() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryScanner(fileSystem: FixtureFileSystem.caches())
                .scanParent(URL(fileURLWithPath: "/allowed"))
        }
        let result = await worker.result
        if case .failure(let error) = result { #expect(error is CancellationError) }
        else { Issue.record("扫描未响应取消") }
    }

    @Test func realLibraryStorageReferencesAreSkippedWithoutFollowingSelfLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("StorageReferenceScanner-" + UUID().uuidString)
        let library = root.appendingPathComponent("Demo.fcpbundle")
        let cache = library.appendingPathComponent("Event A/Analysis Files")
        let dataStorage = library.appendingPathComponent("__.fcpdata.apple.com")
        for directory in [cache, dataStorage] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let analysis = cache.appendingPathComponent(".analysis")
        let database = dataStorage.appendingPathComponent("CurrentVersion.flexolibrary")
        let analysisContents = Data(repeating: 3, count: 4097)
        let databaseContents = Data("keep database".utf8)
        try analysisContents.write(to: analysis)
        try databaseContents.write(to: database)
        let cacheReference = library.appendingPathComponent(".fcpcache")
        let dataReference = library.appendingPathComponent(".fcpdata")
        try fm.createSymbolicLink(atPath: cacheReference.path, withDestinationPath: ".")
        try fm.createSymbolicLink(atPath: dataReference.path, withDestinationPath: "./__.fcpdata.apple.com")

        let result = try LibraryScanner().scanParent(root)
        let found = try #require(result.libraries.first)
        #expect(!result.hasIssues)
        #expect(found.measurements[0].bytes == 0)
        let values = try analysis.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        let expected = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize
        #expect(found.measurements[1].bytes == expected.map(Int64.init))
        #expect(found.measurements[1].candidates.count == 1)
        #expect(Set(found.skippedPackageLinks.map(\.lastPathComponent)) == [".fcpcache", ".fcpdata"])
        #expect(try fm.destinationOfSymbolicLink(atPath: cacheReference.path) == ".")
        #expect(try fm.destinationOfSymbolicLink(atPath: dataReference.path) == "./__.fcpdata.apple.com")
        #expect(try Data(contentsOf: analysis) == analysisContents)
        #expect(try Data(contentsOf: database) == databaseContents)
        // 仅使用系统临时目录中的虚拟库，不扫描真实资源库，也不执行清理。
    }

    @Test func realFilesystemUsesAllocatedSizesAndDoesNotModifyFixture() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ReadOnlyScanner-" + UUID().uuidString)
        let library = root.appendingPathComponent("Demo.fcpbundle")
        let render = library.appendingPathComponent("Event A/Render Files/High Quality Media")
        let analysis = library.appendingPathComponent("Event A/Analysis Files")
        let original = library.appendingPathComponent("Event A/Original Media/important.mov")
        for directory in [render, analysis, original.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let files: [(URL, Data)] = [
            (render.appendingPathComponent("render.dat"), Data(repeating: 1, count: 8_193)),
            (analysis.appendingPathComponent(".hidden.dat"), Data(repeating: 2, count: 17)),
            (original, Data("keep original".utf8))
        ]
        for (url, data) in files { try data.write(to: url) }
        let protectedLink = render.appendingPathComponent("outside-link")
        // 独立验证真实符号链接不能把扫描扩展到 Original Media。
        try fm.createSymbolicLink(at: protectedLink, withDestinationURL: original)
        let before = try files.map { try $0.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let scanner = LibraryScanner()
        let found = try #require(scanner.scanParent(root).libraries.first)
        #expect(found.measurements[0].bytes == nil)
        #expect(found.measurements[0].issues.first?.reason == .excluded)
        let analysisValues = try files[1].0.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        let expected = analysisValues.totalFileAllocatedSize ?? analysisValues.fileAllocatedSize ?? analysisValues.fileSize
        #expect(found.measurements[1].bytes == expected.map(Int64.init))
        for (index, file) in files.enumerated() {
            #expect(try Data(contentsOf: file.0) == file.1)
            #expect(try file.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before[index])
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: protectedLink.path) == original.path)
        // 测试不调用删除 API；虚拟库留在系统临时目录。
    }
}
