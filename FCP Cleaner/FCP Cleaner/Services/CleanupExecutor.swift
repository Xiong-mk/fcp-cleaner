// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import AppKit
import Foundation

nonisolated enum CleanupExecutionError: LocalizedError {
    case finalCutRunning, unsupportedVolume, invalidSelection, authorizationChanged

    var errorDescription: String? {
        switch self {
        case .finalCutRunning: return "Final Cut Pro 仍在运行。请结束全部编辑、渲染和导出任务并退出应用，再重新扫描确认。"
        case .unsupportedVolume: return "仅支持可写的本机内置或外接磁盘目录；网络卷、云盘、只读或状态不明的磁盘不支持清理。"
        case .invalidSelection: return "所选项目为空、已过期或不在通过校验的候选中，请重新预览。"
        case .authorizationChanged: return "文件夹授权已改变，请重新授权并扫描。"
        }
    }
}

nonisolated protocol FinalCutChecking: Sendable {
    @MainActor func requireClosed() throws
}

nonisolated struct SystemFinalCutChecker: FinalCutChecking {
    @MainActor func requireClosed() throws {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            let identifier = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return !app.isTerminated && (identifier.hasPrefix("com.apple.finalcut")
                || name.hasPrefix("final cut pro") || app.executableURL?.lastPathComponent == "Final Cut Pro")
        }
        guard !running else { throw CleanupExecutionError.finalCutRunning }
    }
}

nonisolated protocol CleanupVolumeChecking: Sendable {
    func requireSupported(_ target: URL) throws
}

/// 唯一的真实文件移动接口，没有永久删除或失败降级接口。
nonisolated protocol CleanupTrashing: Sendable {
    func trash(_ target: URL) throws -> URL?
}

nonisolated struct FileManagerTrash: CleanupTrashing {
    func trash(_ target: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}

nonisolated struct CleanupLogEntry: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case pending, completed, failed, cancelled }
    let id: UUID
    let batchID: UUID
    let libraryPath: String
    let targetPath: String
    let kind: String
    let estimatedBytes: Int64
    let startedAt: Date
    var updatedAt = Date()
    var status: Status = .pending
    var trashPath: String?
    var detail: String?
    // 若最终日志写入失败，UI 仍保留真实操作结果，停止后续项。
    var journalError: String?
}

nonisolated protocol CleanupJournaling: Sendable {
    var directory: URL? { get }
    func write(_ entry: CleanupLogEntry) throws
}

nonisolated struct FileCleanupJournal: CleanupJournaling {
    let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.example.FCP-Cleaner")
            .appendingPathComponent("cleanup-logs-v1", isDirectory: true)
    }

    func write(_ entry: CleanupLogEntry) throws {
        guard let directory else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(entry.id.uuidString + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

nonisolated struct CleanupReport: Sendable {
    let entries: [CleanupLogEntry]
    let journalDirectory: URL?
    var completedCount: Int { entries.filter { $0.status == .completed }.count }
    var failedCount: Int { entries.filter { $0.status == .failed }.count }
    var cancelledCount: Int { entries.filter { $0.status == .cancelled }.count }
    var movedBytes: Int64 { entries.filter { $0.status == .completed }.reduce(0) { $0 + $1.estimatedBytes } }
}

nonisolated protocol CleanupExecuting: Sendable {
    func execute(_ requests: [CleanupRequest], authorizedParent: URL,
                 permit: @escaping @Sendable () async throws -> Void,
                 progress: @escaping @Sendable (CleanupLogEntry) async -> Void) async -> CleanupReport
}

nonisolated struct CleanupExecutor: CleanupExecuting {
    let fileSystem: any LibraryScanFileSystem
    let trash: any CleanupTrashing
    let journal: any CleanupJournaling
    let finalCut: any FinalCutChecking
    let volume: any CleanupVolumeChecking

    init(fileSystem: any LibraryScanFileSystem = FoundationScanFileSystem(),
         trash: any CleanupTrashing = FileManagerTrash(), journal: any CleanupJournaling = FileCleanupJournal(),
         finalCut: any FinalCutChecking = SystemFinalCutChecker(),
         volume: any CleanupVolumeChecking = LocalCleanupVolumeChecker()) {
        self.fileSystem = fileSystem
        self.trash = trash
        self.journal = journal
        self.finalCut = finalCut
        self.volume = volume
    }

    func execute(_ requests: [CleanupRequest], authorizedParent: URL,
                 permit: @escaping @Sendable () async throws -> Void,
                 progress: @escaping @Sendable (CleanupLogEntry) async -> Void) async -> CleanupReport {
        let batchID = UUID()
        var seen: Set<String> = []
        // 渲染移动只修改 Render Files；分析移动修改事件目录，因此分析必须排在后面。
        // 不放宽祖先比较、不刷新已确认的快照。同路径重复请求只执行一次。
        let ordered = requests.filter { seen.insert($0.candidate.url.path).inserted }.sorted {
            if $0.kind != $1.kind { return $0.kind == .render }
            return $0.candidate.url.path < $1.candidate.url.path
        }
        var entries: [CleanupLogEntry] = []
        var stopped = false
        for request in ordered {
            var entry = CleanupLogEntry(id: UUID(), batchID: batchID, libraryPath: request.libraryURL.path,
                targetPath: request.candidate.url.path, kind: request.kind.rawValue,
                estimatedBytes: max(0, request.candidate.bytes), startedAt: Date())
            if Task.isCancelled || stopped {
                entry.status = .cancelled
                entry.detail = stopped ? "日志保存失败，停止后续操作。" : "已取消，未执行此项；已完成的移动不会撤回。"
                do { try journal.write(entry) } catch { entry.journalError = error.localizedDescription }
            } else {
                // 每一项独立后台任务不传播取消，必须等待当前调用返回，再停止下一项。
                let pending = entry
                entry = await Task.detached(priority: .utility) {
                    var item = pending
                    do { try journal.write(item) }
                    catch {
                        item.status = .failed
                        item.detail = "无法写入 pending 日志，此项未移动。"
                        item.journalError = error.localizedDescription
                        return item
                    }
                    await progress(item)
                    do {
                        try await permit()
                        try volume.requireSupported(request.candidate.url)
                        let safety = CleanupSafety(fileSystem: fileSystem)
                        try safety.revalidate(request, authorizedParent: authorizedParent)
                        try await finalCut.requireClosed()
                        try await permit()
                        // 授权/FCP 检查等待期间可能断盘或改变卷状态，使用新属性再次确认。
                        try volume.requireSupported(request.candidate.url)
                        // await 后完整复验，连目标内部文件变化也必须拒绝；随后直接调用移动 API。
                        try safety.revalidate(request, authorizedParent: authorizedParent)
                        item.trashPath = try trash.trash(request.candidate.url)?.path
                        item.status = .completed
                        item.detail = "系统废纸篓操作已返回成功。"
                    } catch {
                        item.status = .failed
                        item.detail = error.localizedDescription
                    }
                    item.updatedAt = Date()
                    do { try journal.write(item) } catch { item.journalError = error.localizedDescription }
                    return item
                }.value
            }
            if entry.journalError != nil { stopped = true }
            entries.append(entry)
            await progress(entry)
        }
        return CleanupReport(entries: entries, journalDirectory: journal.directory)
    }
}
