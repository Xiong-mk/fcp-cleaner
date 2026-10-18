// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation

@MainActor
protocol ScanDiagnosticLogging {
    func write(results: [UUID: ParentScanResult], folderPaths: [UUID: String], startedAt: Date) throws -> URL
}

/// 仅保留最近一次扫描的诊断；不持久化书签、文件内容或清理身份快照。
@MainActor
struct JSONScanDiagnosticLogger: ScanDiagnosticLogging {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.FCP-Cleaner"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("scan-logs-v1", isDirectory: true)
            .appendingPathComponent("latest.json")
    }

    func write(results: [UUID: ParentScanResult], folderPaths: [UUID: String], startedAt: Date) throws -> URL {
        let folders = Set(results.keys).union(folderPaths.keys).sorted {
            let firstPath = folderPaths[$0] ?? ""
            let secondPath = folderPaths[$1] ?? ""
            return firstPath == secondPath ? $0.uuidString < $1.uuidString : firstPath < secondPath
        }.map { id in
            ScanDiagnosticFolder(id: id, path: folderPaths[id], result: results[id])
        }
        let libraries = folders.flatMap(\.libraries)
        let measurements = libraries.flatMap(\.measurements)
        let log = ScanDiagnosticRecord(
            schemaVersion: 1,
            appBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.example.FCP-Cleaner",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            startedAt: startedAt, completedAt: Date(),
            authorizedFolderCount: folderPaths.count, scannedFolderCount: results.count,
            libraryCount: libraries.count,
            candidateCount: measurements.reduce(0) { $0 + $1.candidates.count },
            issueCount: folders.reduce(0) { $0 + $1.issues.count }
                + measurements.reduce(0) { $0 + $1.issues.count },
            skippedLinkCount: libraries.reduce(0) { $0 + $1.skippedLinks.count },
            hasIssues: results.values.contains(where: \.hasIssues), folders: folders
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 固定路径原子替换，失败时抛给调用方；扫描不会不断累积日志文件。
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

nonisolated private struct ScanDiagnosticRecord: Codable {
    let schemaVersion: Int
    let appBundleIdentifier: String
    let appVersion: String
    let appBuild: String
    let startedAt: Date
    let completedAt: Date
    let authorizedFolderCount: Int
    let scannedFolderCount: Int
    let libraryCount: Int
    let candidateCount: Int
    let issueCount: Int
    let skippedLinkCount: Int
    let hasIssues: Bool
    let folders: [ScanDiagnosticFolder]
}

nonisolated private struct ScanDiagnosticFolder: Codable {
    let id: UUID
    let path: String?
    let hasResult: Bool
    let hasIssues: Bool
    let issues: [ScanDiagnosticIssue]
    let libraries: [ScanDiagnosticLibrary]

    init(id: UUID, path: String?, result: ParentScanResult?) {
        self.id = id
        self.path = path
        hasResult = result != nil
        hasIssues = result?.hasIssues ?? false
        issues = ScanDiagnosticIssue.sorted(result?.issues ?? [])
        libraries = (result?.libraries ?? []).sorted { $0.path < $1.path }.map(ScanDiagnosticLibrary.init)
    }

    private enum CodingKeys: String, CodingKey { case id, path, hasResult, hasIssues, issues, libraries }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(path, forKey: .path)
        try values.encode(hasResult, forKey: .hasResult)
        try values.encode(hasIssues, forKey: .hasIssues)
        try values.encode(issues, forKey: .issues)
        try values.encode(libraries, forKey: .libraries)
    }
}

nonisolated private struct ScanDiagnosticLibrary: Codable {
    let name: String
    let path: String
    let hasIssues: Bool
    let skippedLinks: [String]
    let measurements: [ScanDiagnosticMeasurement]

    init(_ library: Library) {
        name = library.name
        path = library.path
        hasIssues = library.hasIssues
        skippedLinks = library.skippedPackageLinks.map(\.path).sorted()
        measurements = library.measurements.sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map(ScanDiagnosticMeasurement.init)
    }
}

nonisolated private struct ScanDiagnosticMeasurement: Codable {
    let kind: String
    let bytes: Int64?
    let candidates: [ScanDiagnosticCandidate]
    let issues: [ScanDiagnosticIssue]

    init(_ measurement: CacheMeasurement) {
        kind = measurement.kind.rawValue
        bytes = measurement.bytes
        candidates = measurement.candidates.sorted { $0.url.path < $1.url.path }.map(ScanDiagnosticCandidate.init)
        issues = ScanDiagnosticIssue.sorted(measurement.issues)
    }

    private enum CodingKeys: String, CodingKey { case kind, bytes, candidates, issues }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        // 未完整统计与完整扫描的 0 B 必须在诊断中保持区别。
        try values.encode(bytes, forKey: .bytes)
        try values.encode(candidates, forKey: .candidates)
        try values.encode(issues, forKey: .issues)
    }
}

nonisolated private struct ScanDiagnosticCandidate: Codable {
    let path: String
    let bytes: Int64
    let snapshotAvailable: Bool
    let safetyIssue: String?

    init(_ candidate: CacheCandidate) {
        path = candidate.url.path
        bytes = candidate.bytes
        snapshotAvailable = candidate.snapshot != nil
        safetyIssue = candidate.safetyIssue
    }
}

nonisolated private struct ScanDiagnosticIssue: Codable {
    let path: String
    let reason: String
    let detail: String

    init(_ issue: ScanIssue) {
        path = issue.url.path
        switch issue.reason {
        case .permission: reason = "permission"
        case .unavailable: reason = "unavailable"
        case .failed: reason = "failed"
        case .excluded: reason = "excluded"
        }
        detail = issue.detail
    }

    static func sorted(_ issues: [ScanIssue]) -> [Self] {
        issues.map(Self.init).sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.reason != $1.reason { return $0.reason < $1.reason }
            return $0.detail < $1.detail
        }
    }
}
