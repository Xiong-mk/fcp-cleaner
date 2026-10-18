// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Darwin

nonisolated struct ScanFileMetadata: Sendable, Equatable {
    var isDirectory = false
    var isRegularFile = false
    var isSymbolicLink = false
    var isAlias = false
    var allocatedBytes: Int64?
    var stamp: ScanFileStamp?
}

/// 扫描器只能读取目录和属性，没有写入或删除接口。
nonisolated protocol LibraryScanFileSystem: Sendable {
    func children(of url: URL) throws -> [URL]
    func metadata(at url: URL) throws -> ScanFileMetadata
    func canonicalURL(for url: URL) throws -> URL
}

extension LibraryScanFileSystem {
    // 虚拟文件系统可覆盖此方法；真实文件系统必须解析路径。
    nonisolated func canonicalURL(for url: URL) throws -> URL { url.standardizedFileURL }
}

nonisolated struct FoundationScanFileSystem: LibraryScanFileSystem {
    func children(of url: URL) throws -> [URL] {
        // 不跳过隐藏项，也不递归；空结果只可能来自成功的目录读取。
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    func metadata(at url: URL) throws -> ScanFileMetadata {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let stamp = ScanFileStamp(
            device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino),
            birthSeconds: Int64(status.st_birthtimespec.tv_sec), birthNanoseconds: Int64(status.st_birthtimespec.tv_nsec),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec), modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec), changeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            logicalBytes: Int64(status.st_size), linkCount: UInt64(status.st_nlink)
        )
        // lstat 不跟随末级链接；不向链接目标请求容量信息。
        if status.st_mode & S_IFMT == S_IFLNK {
            return ScanFileMetadata(isSymbolicLink: true, stamp: stamp)
        }
        // 新 URL 避免复用枚举或先前扫描的 resourceValues 缓存。
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ])
        return ScanFileMetadata(
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true,
            isSymbolicLink: values.isSymbolicLink == true,
            isAlias: values.isAliasFile == true,
            allocatedBytes: (values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize).map(Int64.init),
            stamp: stamp
        )
    }

    func canonicalURL(for url: URL) throws -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

nonisolated protocol LibraryScanning: Sendable {
    func scanParent(_ parent: URL) throws -> ParentScanResult
}

nonisolated struct LibraryScanner: LibraryScanning {
    let fileSystem: any LibraryScanFileSystem

    init(fileSystem: any LibraryScanFileSystem = FoundationScanFileSystem()) {
        self.fileSystem = fileSystem
    }

    func scanParent(_ parent: URL) throws -> ParentScanResult {
        try Task.checkCancellation()
        var libraries: [Library] = []
        var issues: [ScanIssue] = []
        let children: [URL]
        do {
            try requireDirectory(parent)
            children = try readChildren(parent)
        } catch {
            if error is CancellationError { throw error }
            return ParentScanResult(libraries: [], issues: [.reading(parent, error: error)])
        }

        // 发现资源库仅检查已授权父文件夹的直接子项。
        for child in children where child.pathExtension.lowercased() == "fcpbundle" {
            try Task.checkCancellation()
            do {
                let info = try metadata(child)
                try rejectLink(info, at: child)
                guard info.isDirectory else { continue }
                libraries.append(try scanLibrary(child, authorizedParent: parent))
            } catch {
                if error is CancellationError { throw error }
                issues.append(.reading(child, error: error))
            }
        }
        return ParentScanResult(libraries: libraries.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, issues: issues)
    }

    private func scanLibrary(_ library: URL, authorizedParent: URL) throws -> Library {
        var render = CacheMeasurement(kind: .render)
        var analysis = CacheMeasurement(kind: .analysis)
        var skippedPackageLinks: [URL] = []
        do {
            let events = try readChildren(library)
            // 只列出下一层事件的目录项，绝不搜索更深处的事件或资源库。
            for event in events {
                try Task.checkCancellation()
                // FCP 的包根管理入口不是事件。.fcpcache 可以指回包根，
                // .fcpdata 可以指向包内/包外的数据位置；不访问或跟随它们。
                // 仅匹配这两个保留名称，隐藏事件及其他链接仍按原规则检查。
                if [".fcpcache", ".fcpdata"].contains(event.lastPathComponent) {
                    skippedPackageLinks.append(event)
                    continue
                }
                let info: ScanFileMetadata
                do {
                    info = try metadata(event)
                    try rejectLink(info, at: event)
                } catch {
                    if error is CancellationError { throw error }
                    let issue = ScanIssue.reading(event, error: error)
                    render.issues.append(issue)
                    analysis.issues.append(issue)
                    continue
                }
                guard info.isDirectory else { continue }
                let entries: [URL]
                do {
                    entries = try readChildren(event)
                } catch {
                    if error is CancellationError { throw error }
                    let issue = ScanIssue.reading(event, error: error)
                    render.issues.append(issue)
                    analysis.issues.append(issue)
                    continue
                }
                if let target = entries.first(where: { $0.lastPathComponent == "Analysis Files" }) {
                    try measure(target, library: library, parent: authorizedParent, into: &analysis)
                }
                if let renderFolder = entries.first(where: { $0.lastPathComponent == "Render Files" }) {
                    do {
                        try requireDirectory(renderFolder)
                        if let target = try readChildren(renderFolder).first(where: { $0.lastPathComponent == "High Quality Media" }) {
                            try measure(target, library: library, parent: authorizedParent, into: &render)
                        }
                    } catch {
                        if error is CancellationError { throw error }
                        render.issues.append(.reading(renderFolder, error: error))
                    }
                }
            }
        } catch {
            if error is CancellationError { throw error }
            let issue = ScanIssue.reading(library, error: error)
            render.issues.append(issue)
            analysis.issues.append(issue)
        }
        return Library(url: library, measurements: [render, analysis],
                       skippedPackageLinks: skippedPackageLinks.sorted { $0.path < $1.path })
    }

    private func measure(_ target: URL, library: URL, parent: URL, into measurement: inout CacheMeasurement) throws {
        do {
            let safety = CleanupSafety(fileSystem: fileSystem)
            var safetyIssue: String?
            var ancestors: [String: ScanFileMetadata]?
            do {
                ancestors = try safety.readAncestors(target, kind: measurement.kind, library: library, authorizedParent: parent)
            } catch CleanupSafetyError.missingSnapshot {
                // 不提供身份信息的只读适配器仍可统计，但绝不能通过安全预览。
                safetyIssue = CleanupSafetyError.missingSnapshot.localizedDescription
            } catch {
                throw error
            }
            let tree = try CacheTreeReader(fileSystem: fileSystem).read(target)
            let bytes = tree.bytes
            let subtotal = measurement.candidates.reduce(Int64(0)) { $0 + $1.bytes }
            guard !subtotal.addingReportingOverflow(bytes).overflow else {
                throw ScanIssue.failure(target, "同类缓存总容量超过可统计范围。")
            }
            var snapshot: CleanupSnapshot?
            if let ancestors {
                do {
                    snapshot = try safety.finishSnapshot(target, kind: measurement.kind, library: library,
                                                         authorizedParent: parent, ancestors: ancestors, tree: tree)
                } catch {
                    if error is CancellationError { throw error }
                    safetyIssue = error.localizedDescription
                }
            }
            measurement.candidates.append(CacheCandidate(url: target, bytes: bytes, snapshot: snapshot, safetyIssue: safetyIssue))
        } catch {
            if error is CancellationError { throw error }
            measurement.issues.append(.reading(target, error: error))
        }
    }

    private func metadata(_ url: URL) throws -> ScanFileMetadata {
        do { return try fileSystem.metadata(at: url) }
        catch { throw ScanIssue.reading(url, error: error) }
    }

    private func readChildren(_ url: URL) throws -> [URL] {
        try Task.checkCancellation()
        do { return try fileSystem.children(of: url) }
        catch { throw ScanIssue.reading(url, error: error) }
    }

    private func requireDirectory(_ url: URL) throws {
        let info = try metadata(url)
        try rejectLink(info, at: url)
        guard info.isDirectory else { throw ScanIssue.failure(url, "预期为目录，但当前路径不是目录。") }
    }

    private func rejectLink(_ info: ScanFileMetadata, at url: URL) throws {
        if info.isSymbolicLink || info.isAlias { throw ScanIssue.excluded(url) }
    }
}
