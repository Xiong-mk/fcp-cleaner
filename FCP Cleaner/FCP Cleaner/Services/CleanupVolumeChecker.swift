// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation

/// 是否内置不影响清理资格；本地性和只读状态必须能明确取得。
nonisolated struct CleanupVolumeProperties: Sendable {
    let isLocal: Bool?
    let isReadOnly: Bool?
}

/// 仅查询属性，便于在不访问真实外接盘的情况下验证卷策略。
nonisolated protocol CleanupVolumeResourceReading: Sendable {
    func volumeProperties(at url: URL) throws -> CleanupVolumeProperties
    func isUbiquitousItem(at url: URL) throws -> Bool?
}

nonisolated struct FoundationCleanupVolumeResources: CleanupVolumeResourceReading {
    func volumeProperties(at url: URL) throws -> CleanupVolumeProperties {
        // 不复用扫描时可能缓存的 URL 资源值，执行前重新查询。
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])
        return CleanupVolumeProperties(isLocal: values.volumeIsLocal, isReadOnly: values.volumeIsReadOnly)
    }

    func isUbiquitousItem(at url: URL) throws -> Bool? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem
    }
}

nonisolated struct LocalCleanupVolumeChecker: CleanupVolumeChecking {
    let resources: any CleanupVolumeResourceReading

    init(resources: any CleanupVolumeResourceReading = FoundationCleanupVolumeResources()) {
        self.resources = resources
    }

    func requireSupported(_ target: URL) throws {
        let fresh = URL(fileURLWithPath: target.path)
        let values = try resources.volumeProperties(at: fresh)
        guard values.isLocal == true, values.isReadOnly == false else {
            throw CleanupExecutionError.unsupportedVolume
        }
        // 本地落盘的云目录仍不支持。按组件匹配，也覆盖云目录本身与大小写变体。
        let components = fresh.pathComponents.map { $0.lowercased() }
        for (parent, child) in zip(components, components.dropFirst()) {
            if parent == "library", ["cloudstorage", "mobile documents"].contains(child) {
                throw CleanupExecutionError.unsupportedVolume
            }
        }
        var current = fresh
        while current.path != "/" {
            if try resources.isUbiquitousItem(at: current) == true {
                throw CleanupExecutionError.unsupportedVolume
            }
            current.deleteLastPathComponent()
        }
    }
}
