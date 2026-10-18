// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Observation

struct AuthorizedFolder: Identifiable {
    var record: FolderBookmarkRecord
    /// 仅在成功解析、开启 scope 并验证目录之后提供 URL，绝不从旧路径恢复权限。
    let url: URL?
    let accessError: String?

    var id: UUID { record.id }
    var path: String { record.path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// 独立的扫描访问计数。移除授权或恢复书签时，后台扫描仍持有自己的 scope。
@MainActor
final class FolderScanAccess {
    let url: URL
    private let scopedURL: URL
    private let client: any FolderBookmarkClient
    private var isOpen = true

    init(url: URL, scopedURL: URL, client: any FolderBookmarkClient) {
        self.url = url
        self.scopedURL = scopedURL
        self.client = client
    }

    func close() {
        guard isOpen else { return }
        client.stopAccessing(scopedURL)
        isOpen = false
    }

    isolated deinit {
        if isOpen { client.stopAccessing(scopedURL) }
    }
}

@MainActor
@Observable
final class AuthorizedFolderStore {
    private(set) var folders: [AuthorizedFolder] = []
    private(set) var loadError: String?
    private(set) var persistenceWarning: String?
    private let storage: any FolderBookmarkStorage
    private let client: any FolderBookmarkClient
    @ObservationIgnored private var activeURLs: [UUID: URL] = [:]

    init(
        storage: (any FolderBookmarkStorage)? = nil,
        client: (any FolderBookmarkClient)? = nil
    ) {
        self.storage = storage ?? JSONFolderBookmarkStorage()
        self.client = client ?? SecurityScopedFolderBookmarkClient()
        restore()
    }

    isolated deinit {
        for url in activeURLs.values { client.stopAccessing(url) }
    }

    /// 失败时保留原始存储，禁止随后添加/移除覆盖无法读取的数据。
    func restore() {
        let records: [FolderBookmarkRecord]
        do {
            records = try storage.load()
            guard Set(records.map(\.id)).count == records.count else {
                throw CocoaError(.coderReadCorrupt)
            }
        } catch {
            loadError = "无法读取已保存的授权记录：\(error.localizedDescription)。原记录已保留，请重试。"
            return
        }

        stopAllAccess()
        loadError = nil
        persistenceWarning = nil
        var restored: [AuthorizedFolder] = []
        var seenPaths: Set<String> = []

        for original in records {
            var startedURL: URL?
            do {
                let resolved = try client.resolve(original.bookmarkData)
                guard client.startAccessing(resolved.url) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                startedURL = resolved.url
                let canonical = try client.canonicalFolderURL(for: resolved.url)
                guard !seenPaths.contains(canonical.path) else {
                    client.stopAccessing(resolved.url)
                    continue
                }
                var record = original
                record.path = canonical.path
                if resolved.isStale {
                    record.bookmarkData = try client.makeBookmark(for: resolved.url)
                }
                seenPaths.insert(canonical.path)
                activeURLs[record.id] = resolved.url
                restored.append(AuthorizedFolder(record: record, url: canonical, accessError: nil))
            } catch {
                if let startedURL { client.stopAccessing(startedURL) }
                restored.append(AuthorizedFolder(
                    record: original, url: nil,
                    accessError: "文件夹或磁盘不可访问：\(error.localizedDescription)。请连接磁盘后重试，或重新授权。"
                ))
            }
        }

        folders = restored
        if restored.map(\.record) != records {
            do {
                try storage.save(restored.map(\.record))
            } catch {
                persistenceWarning = "本次已恢复访问，但更新后的授权记录保存失败：\(error.localizedDescription)。下次启动可能需要重新授权。"
            }
        }
    }

    enum AddResult: Equatable {
        case added
        case renewed
        case duplicate
    }

    /// 只能由用户确认的 NSOpenPanel URL 调用；新书签也先解析并开启 scope。
    @discardableResult
    func add(_ selectedURL: URL, replacing id: UUID? = nil) throws -> AddResult {
        try ensureStorageLoaded()
        let data = try client.makeBookmark(for: selectedURL)
        let resolved = try client.resolve(data)
        guard client.startAccessing(resolved.url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var retainAccess = false
        defer {
            if !retainAccess { client.stopAccessing(resolved.url) }
        }
        let canonical = try client.canonicalFolderURL(for: resolved.url)
        if folders.contains(where: { $0.path == canonical.path && $0.id != id && $0.url != nil }) {
            return .duplicate
        }

        // 再选失效记录的原路径时更新记录；明确重新授权也可选择它移动后的新位置。
        let replacementID = id ?? folders.first(where: { $0.path == canonical.path })?.id
        if let replacementID, !folders.contains(where: { $0.id == replacementID }) {
            throw CocoaError(.fileNoSuchFile)
        }
        let record = FolderBookmarkRecord(
            id: replacementID ?? UUID(), path: canonical.path,
            bookmarkData: resolved.isStale ? try client.makeBookmark(for: resolved.url) : data
        )
        var updated = folders
        // 同一路径的失效记录也合并，避免重新授权后留下重复条目。
        updated.removeAll { $0.path == canonical.path && $0.id != record.id }
        let folder = AuthorizedFolder(record: record, url: canonical, accessError: nil)
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            updated[index] = folder
        } else {
            updated.append(folder)
        }
        try storage.save(updated.map(\.record))

        if let old = activeURLs.removeValue(forKey: record.id) { client.stopAccessing(old) }
        activeURLs[record.id] = resolved.url
        retainAccess = true
        folders = updated
        persistenceWarning = nil
        return replacementID == nil ? .added : .renewed
    }

    func remove(id: UUID) throws {
        try ensureStorageLoaded()
        let updated = folders.filter { $0.id != id }
        guard updated.count != folders.count else { return }
        // 持久化成功后才提交 UI 和资源访问变化；失败保留现有记录与 scope。
        try storage.save(updated.map(\.record))
        if let url = activeURLs.removeValue(forKey: id) { client.stopAccessing(url) }
        folders = updated
        persistenceWarning = nil
    }

    func makeScanAccess(for id: UUID) throws -> FolderScanAccess {
        guard let folder = folders.first(where: { $0.id == id }),
              let canonical = folder.url, let scopedURL = activeURLs[id],
              client.startAccessing(scopedURL) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return FolderScanAccess(url: canonical, scopedURL: scopedURL, client: client)
    }

    /// 所有窗口共用一个 store；退出时显式释放，析构作为兜底。
    func stopAllAccess() {
        for url in activeURLs.values { client.stopAccessing(url) }
        activeURLs.removeAll()
    }

    private func ensureStorageLoaded() throws {
        if let loadError {
            throw NSError(
                domain: "FCPCleaner.FolderAuthorization", code: 1,
                userInfo: [NSLocalizedDescriptionKey: loadError]
            )
        }
    }
}
