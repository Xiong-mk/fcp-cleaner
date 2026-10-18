// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: LibraryListViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("资源库缓存统计", systemImage: "square.stack.3d.up")
                    .font(.title2.bold())
                Spacer()
                if viewModel.isScanning {
                    ProgressView().controlSize(.small)
                    Text("只读扫描中…").foregroundStyle(.secondary)
                } else {
                    Text("已发现 \(viewModel.libraries.count) 个资源库")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()
            authorizedFolders
            Divider()

            results

            if viewModel.isCleaning || viewModel.cleanupReport != nil {
                Divider()
                CleanupResultView(viewModel: viewModel)
            }

            Divider()
            if let error = viewModel.scanLogError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
            }
            HStack {
                Label("扫描只读 · 估算磁盘占用 · 外部位置未检查", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("仅检查包内高质量渲染和分析文件。估算占用受 APFS 克隆、硬链接、压缩和快照等影响，不代表可释放空间。")
                Spacer()
                if let logURL = viewModel.scanLogURL {
                    Button("显示扫描日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                    .font(.caption)
                    .help("在 Finder 中显示最近一次已完成扫描的 JSON 诊断日志；包含路径与错误，不包含媒体内容。")
                }
                if viewModel.hasScanIssues {
                    Label("扫描存在错误或未检查项", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 760, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: viewModel.addLibrary) {
                    Label("添加资源库", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("选择存放 Final Cut Pro 资源库的父文件夹")
                .disabled(viewModel.isCleaning)

                Button(action: viewModel.rescan) {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.folderStore.folders.isEmpty || viewModel.isCleaning)
                .help("重新只读扫描已授权文件夹")
            }
        }
        .toolbarRole(.editor)
        .task { viewModel.startScanningIfNeeded() }
        .alert(item: Binding(
            get: { viewModel.cleanupPreview == nil ? viewModel.notice : nil },
            set: { viewModel.notice = $0 }
        )) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(item: $viewModel.cleanupPreview, onDismiss: viewModel.cancelPreview) { preview in
            CleanupPreviewView(preview: preview, viewModel: viewModel)
        }
    }

    private var results: some View {
        List {
            ForEach(viewModel.folderStore.folders) { folder in
                Section {
                    if let result = viewModel.scanResults[folder.id] {
                        ForEach(result.issues) { issue in ScanIssueRow(issue: issue) }
                        ForEach(result.libraries) { library in
                            VStack(alignment: .leading, spacing: 4) {
                                LibraryRow(library: library)
                                if library.measurements.contains(where: { !$0.candidates.isEmpty }) {
                                    Button {
                                        viewModel.previewCleanup(libraryID: library.id, folderID: folder.id)
                                    } label: {
                                        Label(viewModel.isPreparingPreview ? "安全校验中…" : "预览并选择清理", systemImage: "checkmark.shield")
                                    }
                                    .disabled(viewModel.isScanning || viewModel.isPreparingPreview || viewModel.isCleaning)
                                    .help("只读复验候选；勾选并二次确认后可移到废纸篓")
                                    .padding(.bottom, 8)
                                }
                            }
                        }
                        if result.libraries.isEmpty && result.issues.isEmpty {
                            Text("此文件夹的直接子项中未发现 .fcpbundle 资源库。")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    } else {
                        Text(viewModel.isScanning ? "等待扫描结果…" : "尚未扫描")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("\(folder.name) · \(folder.path)")
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if viewModel.folderStore.folders.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加文件夹", systemImage: "film.stack")
                } description: {
                    Text("添加存放资源库的父文件夹后，将自动进行只读扫描。")
                }
            }
        }
    }

    private var authorizedFolders: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已授权文件夹（\(viewModel.folderStore.folders.count)）").font(.headline)
                Spacer()
                Button("重试授权访问", action: viewModel.retryFolderAccess)
                    .disabled(viewModel.isCleaning || (viewModel.folderStore.folders.isEmpty && viewModel.folderStore.loadError == nil))
            }

            if let message = viewModel.folderStore.loadError ?? viewModel.folderStore.persistenceWarning {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if viewModel.folderStore.folders.isEmpty {
                Text("点击“添加资源库”，选择存放资源库的父文件夹。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.folderStore.folders) { folder in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: folder.url == nil ? "folder.badge.questionmark" : "folder")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(folder.name).font(.headline)
                                    Text(folder.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    if let error = folder.accessError {
                                        Text(error).font(.caption).foregroundStyle(.orange)
                                    } else if viewModel.isScanning {
                                        Text("正在只读扫描").font(.caption).foregroundStyle(.secondary)
                                    } else if let result = viewModel.scanResults[folder.id] {
                                        Text(result.hasIssues ? "扫描存在错误或未检查项" : "扫描完成")
                                            .font(.caption).foregroundStyle(result.hasIssues ? .orange : .secondary)
                                    } else {
                                        Text("访问已开启").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("重新授权") { viewModel.reauthorizeFolder(id: folder.id) }
                                    .disabled(viewModel.isCleaning)
                                Button("移除") { viewModel.removeFolder(id: folder.id) }
                                    .disabled(viewModel.isCleaning)
                                    .help("仅移除授权记录，保留磁盘上的文件夹及内容")
                                    .accessibilityLabel("移除 \(folder.name) 的授权")
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct LibraryRow: View {
    let library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(library.name, systemImage: "film.stack").font(.headline)
            Text(library.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !library.skippedPackageLinks.isEmpty {
                DisclosureGroup("已跳过 \(library.skippedPackageLinks.count) 个资源库管理项") {
                    Text(".fcpcache 和 .fcpdata 是包根管理入口，不作为事件扫描，也不跟随其目标。下方仅统计包内受支持的缓存；外部位置未检查。")
                    ForEach(library.skippedPackageLinks, id: \.path) { url in
                        Text(url.path).textSelection(.enabled)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(library.measurements) { measurement in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(measurement.kind.rawValue)
                        Spacer()
                        Text(measurement.sizeDescription)
                            .monospacedDigit()
                            .foregroundStyle(measurement.bytes == nil ? .orange : .primary)
                    }
                    ForEach(measurement.issues) { issue in ScanIssueRow(issue: issue) }
                    if !measurement.candidates.isEmpty {
                        DisclosureGroup("查看 \(measurement.candidates.count) 个缓存目录") {
                            ForEach(measurement.candidates) { candidate in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top) {
                                        Text(candidate.url.path).textSelection(.enabled)
                                        Spacer()
                                        Text(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file))
                                    }
                                    if let issue = candidate.safetyIssue {
                                        Text("安全预览不可用：\(issue)").foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 2)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            if library.hasNoSupportedCaches {
                Text("未发现已支持类别的缓存").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct ScanIssueRow: View {
    let issue: ScanIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.message, systemImage: "exclamationmark.triangle")
            Text(issue.url.path).textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView(viewModel: LibraryListViewModel())
}

#Preview("缓存分类与错误") {
    // 仅用于 Xcode 预览，运行中的应用不会加载演示资源库。
    List {
        LibraryRow(library: Library(
            url: URL(fileURLWithPath: "/Volumes/演示磁盘/剪辑项目/旅行.fcpbundle"),
            measurements: [
                CacheMeasurement(kind: .render, candidates: [CacheCandidate(
                    url: URL(fileURLWithPath: "/Volumes/演示磁盘/剪辑项目/旅行.fcpbundle/事件一/Render Files/High Quality Media"),
                    bytes: 8_200_000_000
                )]),
                CacheMeasurement(kind: .analysis, issues: [ScanIssue(
                    url: URL(fileURLWithPath: "/Volumes/演示磁盘/剪辑项目/旅行.fcpbundle/事件二/Analysis Files"),
                    reason: .permission, detail: "无法读取目录。"
                )])
            ]
        ))
        LibraryRow(library: Library(
            url: URL(fileURLWithPath: "/Volumes/演示磁盘/剪辑项目/空资源库.fcpbundle"),
            measurements: [CacheMeasurement(kind: .render), CacheMeasurement(kind: .analysis)]
        ))
    }
    .frame(width: 820, height: 430)
}
