// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import SwiftUI

struct CleanupConfirmationView: View {
    let confirmation: CleanupConfirmation
    @Bindable var viewModel: LibraryListViewModel
    @State private var editingTasksEnded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("确认移到废纸篓", systemImage: "trash").font(.title2.bold())
            Text("即将移动以下 \(confirmation.requests.count) 个生成文件目录，估算占用 \(ByteCountFormatter.string(fromByteCount: confirmation.estimatedBytes, countStyle: .file))。")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(confirmation.requests) { request in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(request.libraryURL.lastPathComponent) · \(request.kind.rawValue)").font(.headline)
                            Text(request.candidate.url.path).font(.caption).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: request.candidate.bytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 100, maxHeight: 240)
            Text("渲染与分析可能需要重新生成。移入废纸篓不会立即释放磁盘空间；操作失败会显示原因，不会永久删除。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("我已结束全部编辑、渲染和导出任务，并退出 Final Cut Pro", isOn: $editingTasksEnded)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("取消") { viewModel.cleanupConfirmation = nil }.keyboardShortcut(.cancelAction)
                Button("确认移到废纸篓", role: .destructive) {
                    viewModel.confirmCleanup(id: confirmation.id, editingTasksEnded: editingTasksEnded)
                }.disabled(!editingTasksEnded)
            }
        }
        .padding(24)
        .frame(width: 680)
    }
}

struct CleanupResultView: View {
    @Bindable var viewModel: LibraryListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if viewModel.isCleaning {
                    ProgressView().controlSize(.small)
                    Text(viewModel.isRescanningAfterCleanup ? "操作已返回，正在重新扫描…" : "正在逐项移到废纸篓…")
                    Spacer()
                    Button("停止后续项", action: viewModel.cancelCleanup)
                        .disabled(viewModel.isRescanningAfterCleanup)
                } else if let report = viewModel.cleanupReport {
                    Text("成功移动 \(report.completedCount) 项 · 失败 \(report.failedCount) 项 · 未执行 \(report.cancelledCount) 项")
                        .font(.headline)
                    Spacer()
                }
            }
            if let report = viewModel.cleanupReport {
                Text("已移入废纸篓的估算容量：\(ByteCountFormatter.string(fromByteCount: report.movedBytes, countStyle: .file))；不等于已释放空间。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(viewModel.hasScanIssues ? "重扫已结束，但存在读取错误或未检查项，请查看上方详情。" : "已根据文件系统重新扫描。")
                    .font(.caption).foregroundStyle(viewModel.hasScanIssues ? .orange : .secondary)
                if let directory = report.journalDirectory {
                    HStack {
                        Text("日志：\(directory.path)").font(.caption).textSelection(.enabled).lineLimit(2)
                        Button("显示日志") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                    }
                }
            }
            DisclosureGroup("每项操作日志（\(viewModel.cleanupEntries.count)）") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.cleanupEntries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(status(entry.status)) · \(entry.kind)").bold()
                                    Spacer()
                                    Text(entry.updatedAt, style: .time)
                                }
                                Text(entry.targetPath).textSelection(.enabled)
                                if let detail = entry.detail { Text(detail).textSelection(.enabled) }
                                if let error = entry.journalError {
                                    Text("日志保存失败：\(error)。磁盘上可能仍为 pending，请根据实际状态核对，勿直接重试。")
                                        .foregroundStyle(.orange).textSelection(.enabled)
                                }
                            }.font(.caption)
                        }
                    }
                }.frame(maxHeight: 180)
            }.font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func status(_ status: CleanupLogEntry.Status) -> String {
        switch status {
        case .pending: return "进行中"
        case .completed: return "已移入废纸篓"
        case .failed: return "失败"
        case .cancelled: return "未执行"
        }
    }
}

#Preview("废纸篓二次确认") {
    let library = URL(fileURLWithPath: "/Users/demo/Movies/旅行.fcpbundle")
    let requests = [CleanupRequest(libraryURL: library, kind: .render, candidate: CacheCandidate(
        url: library.appendingPathComponent("事件一/Render Files/High Quality Media"), bytes: 8_200_000_000
    ))]
    CleanupConfirmationView(confirmation: CleanupConfirmation(previewID: UUID(), folderID: UUID(),
        parentURL: library.deletingLastPathComponent(), requests: requests, estimatedBytes: 8_200_000_000),
        viewModel: LibraryListViewModel())
}
