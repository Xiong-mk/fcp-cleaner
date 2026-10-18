// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation

nonisolated struct CleanupRequest: Identifiable, Sendable {
    let libraryURL: URL
    let kind: CacheKind
    let candidate: CacheCandidate

    var id: String { libraryURL.path + "\n" + kind.rawValue + "\n" + candidate.id }
}

nonisolated struct CleanupPreviewItem: Identifiable, Sendable {
    let request: CleanupRequest
    let blockedReason: String?
    var id: String { request.id }
    var isEligible: Bool { blockedReason == nil }
}

nonisolated struct CleanupPreview: Identifiable, Sendable {
    let id = UUID()
    let checkedAt = Date()
    let items: [CleanupPreviewItem]

    var eligibleCount: Int { items.filter(\.isEligible).count }
    var eligibleBytes: Int64? { estimatedBytes(for: Set(items.filter(\.isEligible).map(\.id))) }

    func estimatedBytes(for selection: Set<String>) -> Int64? {
        var total: Int64 = 0
        for item in items where item.isEligible && selection.contains(item.id) {
            let (sum, overflow) = total.addingReportingOverflow(item.request.candidate.bytes)
            guard !overflow, item.request.candidate.bytes >= 0 else { return nil }
            total = sum
        }
        return total
    }

    static let risks = [
        "预览阶段只读。仅勾选的通过项可进入二次确认；确认后会真实移到系统废纸篓。",
        "高质量渲染覆盖白名单目录中的全部渲染，无法判断哪些未使用；后续使用可能需要重新渲染。",
        "分析文件可能需要重新分析，耗时取决于素材、效果和设备。",
        "原始媒体、代理/优化媒体、数据库和备份不属于白名单；外部位置未检查。",
        "请结束全部编辑、渲染和导出任务并退出 Final Cut Pro；运行中检测仅为辅助，不能证明文件无人占用。",
        "支持可写的本机内置及外接磁盘；网络卷、云盘、只读或状态不明的磁盘不清理。废纸篓失败将保留数据并报告错误。",
        "已移入废纸篓的估算容量不等于已释放空间；估算受 APFS 克隆、硬链接、压缩和快照影响。"
    ]
}

nonisolated protocol DryRunCleaning: Sendable {
    func preview(_ requests: [CleanupRequest], authorizedParent: URL) throws -> CleanupPreview
}

/// 只有读取依赖；返回结果后，扫描容量和磁盘内容均不改变。
nonisolated struct DryRunCleaner: DryRunCleaning {
    let fileSystem: any LibraryScanFileSystem

    init(fileSystem: any LibraryScanFileSystem = FoundationScanFileSystem()) {
        self.fileSystem = fileSystem
    }

    func preview(_ requests: [CleanupRequest], authorizedParent: URL) throws -> CleanupPreview {
        try Task.checkCancellation()
        let safety = CleanupSafety(fileSystem: fileSystem)
        var seen: Set<String> = []
        var items: [CleanupPreviewItem] = []
        for request in requests where seen.insert(request.id).inserted {
            try Task.checkCancellation()
            do {
                try safety.revalidate(request, authorizedParent: authorizedParent)
                items.append(CleanupPreviewItem(request: request, blockedReason: nil))
            } catch {
                if error is CancellationError { throw error }
                items.append(CleanupPreviewItem(request: request, blockedReason: error.localizedDescription))
            }
        }
        return CleanupPreview(items: items)
    }
}
