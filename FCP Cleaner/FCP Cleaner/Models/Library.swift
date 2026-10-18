// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation

nonisolated enum CacheKind: String, CaseIterable, Sendable, Identifiable {
    case render = "高质量渲染"
    case analysis = "分析文件"

    var id: Self { self }
}

nonisolated struct CacheCandidate: Identifiable, Sendable {
    let url: URL
    let bytes: Int64
    var snapshot: CleanupSnapshot? = nil
    var safetyIssue: String? = nil
    var id: String { url.standardizedFileURL.path }
}

/// bytes 为 nil 表示统计不完整；只有完整扫描的空目录才可以报告 0。
nonisolated struct CacheMeasurement: Identifiable, Sendable {
    let kind: CacheKind
    var candidates: [CacheCandidate] = []
    var issues: [ScanIssue] = []

    var id: CacheKind { kind }
    var bytes: Int64? {
        guard issues.isEmpty else { return nil }
        return candidates.reduce(0) { $0 + $1.bytes }
    }
    var sizeDescription: String {
        guard let bytes else { return "统计不完整" }
        if bytes == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

nonisolated struct Library: Identifiable, Sendable {
    let url: URL
    let measurements: [CacheMeasurement]
    /// 包根的管理入口不属于事件；只记录名称，不读取或跟随其目标。
    var skippedPackageLinks: [URL] = []

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var hasIssues: Bool { measurements.contains { !$0.issues.isEmpty } }
    var hasNoSupportedCaches: Bool {
        !hasIssues && measurements.allSatisfy { $0.candidates.isEmpty }
    }
}

nonisolated struct ParentScanResult: Sendable {
    let libraries: [Library]
    let issues: [ScanIssue]

    var hasIssues: Bool { !issues.isEmpty || libraries.contains(where: \.hasIssues) }
}

nonisolated struct ScanIssue: Error, Identifiable, Sendable {
    enum Reason: Sendable {
        case permission, unavailable, failed, excluded
    }

    let url: URL
    let reason: Reason
    let detail: String

    var id: String { url.path + message }
    var message: String {
        let title: String
        switch reason {
        case .permission: title = "权限不足，请重新授权"
        case .unavailable: title = "文件夹或磁盘不可访问，请检查磁盘连接及路径后重试"
        case .failed: title = "扫描失败，请重试"
        case .excluded: title = "未扫描链接或别名"
        }
        return "\(title)：\(detail)"
    }

    static func excluded(_ url: URL) -> Self {
        Self(url: url, reason: .excluded, detail: "为保持扫描范围，不跟随符号链接或 Finder 别名。")
    }

    static func failure(_ url: URL, _ detail: String) -> Self {
        Self(url: url, reason: .failed, detail: detail)
    }

    static func reading(_ url: URL, error: any Error) -> Self {
        if let issue = error as? Self { return issue }
        let original = error as NSError
        var current = original
        var reason = Reason.failed
        // Foundation 可能把 POSIX 错误包在 Cocoa 错误内；保留路径和原始说明。
        for _ in 0..<8 {
            if (current.domain == NSCocoaErrorDomain && current.code == NSFileReadNoPermissionError)
                || (current.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(current.code)) {
                reason = .permission
                break
            }
            if (current.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(current.code))
                || (current.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENODEV), Int(ENXIO), Int(EIO), Int(ESTALE), Int(ENOTCONN)].contains(current.code)) {
                reason = .unavailable
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return Self(url: url, reason: reason, detail: original.localizedDescription)
    }
}
