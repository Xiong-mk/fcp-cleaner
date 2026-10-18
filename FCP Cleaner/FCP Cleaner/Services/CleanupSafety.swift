// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation

/// 使用设备、inode、创建时间识别对象，以纳秒级 mtime/ctime 检测修改。
/// 不含 atime：只读检查本身可能更新访问时间。
nonisolated struct ScanFileStamp: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var birthSeconds: Int64
    var birthNanoseconds: Int64
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var changeSeconds: Int64
    var changeNanoseconds: Int64
    var logicalBytes: Int64
    var linkCount: UInt64
}

/// 只在内存中保存扫描时的路径、祖先及整个候选树的元数据，不读取文件内容。
nonisolated struct CleanupSnapshot: Equatable, Sendable {
    let parentPath: String
    let libraryPath: String
    let targetPath: String
    let kind: CacheKind
    let ancestors: [String: ScanFileMetadata]
    let entries: [String: ScanFileMetadata]
    let bytes: Int64
}

nonisolated enum CleanupSafetyError: LocalizedError, Equatable {
    case invalidURL, traversal, outsideLibrary, unexpectedPath, invalidDirectory
    case linkOrAlias, missingSnapshot, changed, crossVolume, noncanonicalPath

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "仅接受本机绝对文件路径，拒绝根目录及无效 URL。"
        case .traversal: return "路径含有 . 或 ..，拒绝路径穿越；请重新扫描。"
        case .outsideLibrary: return "目标不在指定资源库内，或资源库不是已授权文件夹的直接子项。"
        case .unexpectedPath: return "目标的名称、层级或类别不符合精确路径白名单。"
        case .invalidDirectory: return "候选路径的每一层都必须为真实目录。"
        case .linkOrAlias: return "路径中存在符号链接或 Finder 别名，拒绝清理。"
        case .missingSnapshot: return "缺少完整的扫描身份快照，无法安全判断；请重新扫描。"
        case .changed: return "目标、内容或祖先目录已改变；请重新扫描后重新预览。"
        case .crossVolume: return "候选树跨越文件系统边界，拒绝清理。"
        case .noncanonicalPath: return "真实路径与扫描路径不符，可能存在链接或位置变化；请重新授权并扫描。"
        }
    }
}

/// 与扫描和预览共享一次目录遍历。协议仅有读取接口，不具备修改磁盘的能力。
nonisolated struct CacheTreeReader {
    struct Tree: Sendable {
        let bytes: Int64
        let entries: [String: ScanFileMetadata]
    }

    let fileSystem: any LibraryScanFileSystem

    func read(_ target: URL) throws -> Tree {
        var pending = [target]
        var entries: [String: ScanFileMetadata] = [:]
        var total: Int64 = 0
        while let folder = pending.popLast() {
            try Task.checkCancellation()
            let info = try metadata(folder)
            if info.isSymbolicLink || info.isAlias { throw ScanIssue.excluded(folder) }
            guard info.isDirectory else { throw CleanupSafetyError.invalidDirectory }
            if let previous = entries[folder.path], previous != info { throw CleanupSafetyError.changed }
            entries[folder.path] = info
            let children: [URL]
            do { children = try fileSystem.children(of: folder) }
            catch { throw ScanIssue.reading(folder, error: error) }
            for item in children {
                try Task.checkCancellation()
                // 防止文件系统适配器意外返回非直接子项，也阻止重复/循环枚举。
                guard item.isFileURL, !item.pathComponents.contains(".."), !item.pathComponents.contains("."),
                      item.deletingLastPathComponent().path == folder.path,
                      item.path != folder.path, entries[item.path] == nil else {
                    throw CleanupSafetyError.outsideLibrary
                }
                let child = try metadata(item)
                if child.isSymbolicLink || child.isAlias { throw ScanIssue.excluded(item) }
                entries[item.path] = child
                if child.isDirectory {
                    pending.append(item)
                } else if child.isRegularFile {
                    guard let bytes = child.allocatedBytes, bytes >= 0 else {
                        throw ScanIssue.failure(item, "文件系统未提供有效容量，不能视为 0 B。")
                    }
                    let (sum, overflow) = total.addingReportingOverflow(bytes)
                    guard !overflow else { throw ScanIssue.failure(item, "容量超过可统计范围。") }
                    total = sum
                } else {
                    throw ScanIssue.failure(item, "不支持的文件类型，容量未计入。")
                }
            }
        }
        return Tree(bytes: total, entries: entries)
    }

    private func metadata(_ url: URL) throws -> ScanFileMetadata {
        do { return try fileSystem.metadata(at: url) }
        catch { throw ScanIssue.reading(url, error: error) }
    }
}

nonisolated struct CleanupSafety {
    let fileSystem: any LibraryScanFileSystem

    init(fileSystem: any LibraryScanFileSystem = FoundationScanFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// 在标准化之前拒绝穿越，而不是把可疑路径变成看起来合法的路径。
    private func pathChain(_ target: URL, kind: CacheKind, library: URL, authorizedParent: URL) throws -> [URL] {
        for url in [target, library, authorizedParent] {
            guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/"), url.path != "/",
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil else { throw CleanupSafetyError.invalidURL }
            guard !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
                throw CleanupSafetyError.traversal
            }
        }
        let root = library.pathComponents
        let item = target.pathComponents
        guard library.pathExtension.lowercased() == "fcpbundle",
              library.deletingLastPathComponent().pathComponents == authorizedParent.pathComponents,
              item.starts(with: root), item.count > root.count else { throw CleanupSafetyError.outsideLibrary }
        let relative = Array(item.dropFirst(root.count))
        let allowed: Bool
        switch kind {
        case .analysis: allowed = relative.count == 2 && relative[1] == "Analysis Files"
        case .render: allowed = relative.count == 3 && relative[1] == "Render Files" && relative[2] == "High Quality Media"
        }
        guard allowed else { throw CleanupSafetyError.unexpectedPath }
        var chain = [authorizedParent, library]
        var current = library
        for component in relative {
            current.appendPathComponent(component, isDirectory: true)
            chain.append(current)
        }
        return chain
    }

    func readAncestors(_ target: URL, kind: CacheKind, library: URL, authorizedParent: URL) throws -> [String: ScanFileMetadata] {
        var nodes: [String: ScanFileMetadata] = [:]
        for url in try pathChain(target, kind: kind, library: library, authorizedParent: authorizedParent) {
            try Task.checkCancellation()
            let info = try fileSystem.metadata(at: url)
            guard !info.isSymbolicLink, !info.isAlias else { throw ScanIssue.excluded(url) }
            guard info.isDirectory else { throw CleanupSafetyError.invalidDirectory }
            guard info.stamp != nil else { throw CleanupSafetyError.missingSnapshot }
            guard try fileSystem.canonicalURL(for: url).pathComponents == url.pathComponents else {
                throw CleanupSafetyError.noncanonicalPath
            }
            nodes[url.path] = info
        }
        return nodes
    }

    func finishSnapshot(_ target: URL, kind: CacheKind, library: URL, authorizedParent: URL,
                        ancestors: [String: ScanFileMetadata], tree: CacheTreeReader.Tree) throws -> CleanupSnapshot {
        guard tree.entries[target.path] == ancestors[target.path],
              let device = ancestors[library.path]?.stamp?.device else { throw CleanupSafetyError.changed }
        // 先检查整个清理树，包含隐藏项、嵌套目录及文件。读取失败一律中止。
        for (path, info) in ancestors.merging(tree.entries, uniquingKeysWith: { first, _ in first }) {
            try Task.checkCancellation()
            guard let stamp = info.stamp else { throw CleanupSafetyError.missingSnapshot }
            guard stamp.device == device else { throw CleanupSafetyError.crossVolume }
            guard !info.isSymbolicLink, !info.isAlias else { throw CleanupSafetyError.linkOrAlias }
            guard try fileSystem.metadata(at: URL(fileURLWithPath: path)) == info else { throw CleanupSafetyError.changed }
        }
        let after = try readAncestors(target, kind: kind, library: library, authorizedParent: authorizedParent)
        guard after == ancestors else { throw CleanupSafetyError.changed }
        return CleanupSnapshot(parentPath: authorizedParent.path, libraryPath: library.path, targetPath: target.path,
                               kind: kind, ancestors: ancestors, entries: tree.entries, bytes: tree.bytes)
    }

    func capture(_ target: URL, kind: CacheKind, library: URL, authorizedParent: URL) throws -> CleanupSnapshot {
        let ancestors = try readAncestors(target, kind: kind, library: library, authorizedParent: authorizedParent)
        let tree = try CacheTreeReader(fileSystem: fileSystem).read(target)
        return try finishSnapshot(target, kind: kind, library: library, authorizedParent: authorizedParent,
                                  ancestors: ancestors, tree: tree)
    }

    /// 永远对照最初扫描快照；预览不得悄悄把改变后的对象当作新的基准。
    func revalidate(_ request: CleanupRequest, authorizedParent: URL) throws {
        _ = try pathChain(request.candidate.url, kind: request.kind, library: request.libraryURL, authorizedParent: authorizedParent)
        guard let original = request.candidate.snapshot else { throw CleanupSafetyError.missingSnapshot }
        guard original.parentPath == authorizedParent.path, original.libraryPath == request.libraryURL.path,
              original.targetPath == request.candidate.url.path, original.kind == request.kind,
              original.bytes == request.candidate.bytes else { throw CleanupSafetyError.changed }
        let ancestors = try readAncestors(request.candidate.url, kind: request.kind, library: request.libraryURL, authorizedParent: authorizedParent)
        guard ancestors == original.ancestors else { throw CleanupSafetyError.changed }
        let tree = try CacheTreeReader(fileSystem: fileSystem).read(request.candidate.url)
        let current = try finishSnapshot(request.candidate.url, kind: request.kind, library: request.libraryURL,
                                         authorizedParent: authorizedParent, ancestors: ancestors, tree: tree)
        guard current == original else { throw CleanupSafetyError.changed }
    }
}
