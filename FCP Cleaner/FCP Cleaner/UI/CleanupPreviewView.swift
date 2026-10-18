// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import SwiftUI

struct CleanupPreviewView: View {
    let preview: CleanupPreview
    @Bindable var viewModel: LibraryListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("清理预览", systemImage: "checkmark.shield").font(.title2.bold())
                Spacer()
                Text("只读预览").font(.headline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(CleanupPreview.risks, id: \.self) { risk in
                    Text("• \(risk)").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("校验通过 \(preview.eligibleCount) 项 · 拒绝 \(preview.items.count - preview.eligibleCount) 项")
                Spacer()
                Text(preview.checkedAt, style: .time).foregroundStyle(.secondary)
            }
            .font(.callout)

            List(preview.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(
                            get: { selection.contains(item.id) },
                            set: { selected in
                                if selected && item.isEligible { selection.insert(item.id) }
                                else { selection.remove(item.id) }
                            }
                        )) {
                            Text("\(item.request.libraryURL.lastPathComponent) · \(item.request.kind.rawValue)").font(.headline)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!item.isEligible || viewModel.isPreparingCleanup)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.request.candidate.bytes, countStyle: .file))
                            .monospacedDigit()
                    }
                    Text(item.request.candidate.url.path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let reason = item.blockedReason {
                        Label("拒绝：\(reason)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    } else {
                        Label("快照校验通过 · 可勾选清理", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.vertical, 6)
            }
            .listStyle(.inset)
            .frame(minHeight: 180)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选 \(selection.count) 项 · 估算占用 \(selectedSize)").font(.headline)
                    Text("尚未移动文件；下一步将再次复验并确认完整路径。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(viewModel.isPreparingCleanup ? "正在复验…" : "清理到废纸篓…") {
                    viewModel.prepareCleanup(selection: selection, previewID: preview.id)
                }
                .disabled(selection.isEmpty || preview.estimatedBytes(for: selection) == nil || viewModel.isPreparingCleanup)
            }
        }
        .padding(20)
        .frame(minWidth: 740, idealWidth: 840, minHeight: 610)
        .interactiveDismissDisabled(viewModel.isPreparingCleanup)
        .sheet(item: $viewModel.cleanupConfirmation) { confirmation in
            CleanupConfirmationView(confirmation: confirmation, viewModel: viewModel)
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
    }

    private var selectedSize: String {
        guard let bytes = preview.estimatedBytes(for: selection) else { return "超出统计范围" }
        return bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview("通过与拒绝的清理预览") {
    let library = URL(fileURLWithPath: "/Volumes/演示磁盘/剪辑项目/旅行.fcpbundle")
    CleanupPreviewView(preview: CleanupPreview(items: [
        CleanupPreviewItem(request: CleanupRequest(libraryURL: library, kind: .render, candidate: CacheCandidate(
            url: library.appendingPathComponent("事件一/Render Files/High Quality Media"), bytes: 8_200_000_000
        )), blockedReason: nil),
        CleanupPreviewItem(request: CleanupRequest(libraryURL: library, kind: .analysis, candidate: CacheCandidate(
            url: library.appendingPathComponent("事件一/Analysis Files"), bytes: 300_000_000
        )), blockedReason: CleanupSafetyError.changed.localizedDescription)
    ]), viewModel: LibraryListViewModel())
}
