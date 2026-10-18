// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

@Suite @MainActor
struct ScanDiagnosticLogTests {
    @Test func recordsScanDiagnosticsWithoutBookmarksOrFileContents() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("diagnostics/latest.json")
        let parent = "/Volumes/Mock External SSD/Projects"
        let libraryURL = URL(fileURLWithPath: parent + "/Demo.fcpbundle")
        let target = libraryURL.appendingPathComponent("Event/Render Files/High Quality Media")
        let unavailable = libraryURL.appendingPathComponent("Event/Analysis Files")
        let id = UUID()
        let snapshot = CleanupSnapshot(parentPath: parent, libraryPath: libraryURL.path,
            targetPath: target.path, kind: .render, ancestors: [:], entries: [:], bytes: 256)
        let library = Library(url: libraryURL, measurements: [
            CacheMeasurement(kind: .render, candidates: [CacheCandidate(url: target, bytes: 256, snapshot: snapshot)]),
            CacheMeasurement(kind: .analysis, candidates: [CacheCandidate(url: unavailable, bytes: 7,
                safetyIssue: "扫描身份快照不可用")], issues: [
                    ScanIssue(url: unavailable, reason: .permission, detail: "读取目录被拒绝")
                ])
        ], skippedPackageLinks: [libraryURL.appendingPathComponent(".fcpdata"), libraryURL.appendingPathComponent(".fcpcache")])
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let returned = try JSONScanDiagnosticLogger(fileURL: file).write(
            results: [id: ParentScanResult(libraries: [library], issues: [
                ScanIssue(url: URL(fileURLWithPath: parent + "/Offline.fcpbundle"),
                    reason: .unavailable, detail: "磁盘不可访问")
            ])], folderPaths: [id: parent], startedAt: startedAt)
        #expect(returned == file)
        let data = try Data(contentsOf: file)
        let log = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(log["schemaVersion"] as? Int == 1)
        #expect(log["appBundleIdentifier"] is String)
        #expect(log["appVersion"] is String)
        #expect(log["appBuild"] is String)
        let start = try #require(log["startedAt"] as? String)
        let completion = try #require(log["completedAt"] as? String)
        let completedAt = try #require(ISO8601DateFormatter().date(from: completion))
        #expect(ISO8601DateFormatter().date(from: start) == startedAt)
        #expect(completedAt >= startedAt)
        #expect(log["authorizedFolderCount"] as? Int == 1)
        #expect(log["scannedFolderCount"] as? Int == 1)
        #expect(log["libraryCount"] as? Int == 1)
        #expect(log["candidateCount"] as? Int == 2)
        #expect(log["issueCount"] as? Int == 2)
        #expect(log["skippedLinkCount"] as? Int == 2)
        #expect(log["hasIssues"] as? Bool == true)
        let folders = try #require(log["folders"] as? [[String: Any]])
        let folder = try #require(folders.first)
        #expect(folder["path"] as? String == parent)
        #expect(folder["hasResult"] as? Bool == true)
        let parentIssues = try #require(folder["issues"] as? [[String: Any]])
        #expect(parentIssues.first?["reason"] as? String == "unavailable")
        #expect(parentIssues.first?["detail"] as? String == "磁盘不可访问")
        let libraries = try #require(folder["libraries"] as? [[String: Any]])
        let savedLibrary = try #require(libraries.first)
        #expect(savedLibrary["path"] as? String == libraryURL.path)
        #expect(savedLibrary["skippedLinks"] as? [String] == [
            libraryURL.appendingPathComponent(".fcpcache").path,
            libraryURL.appendingPathComponent(".fcpdata").path
        ])
        let measurements = try #require(savedLibrary["measurements"] as? [[String: Any]])
        let render = try #require(measurements.first { $0["kind"] as? String == CacheKind.render.rawValue })
        #expect(render["bytes"] as? Int == 256)
        let renderCandidates = try #require(render["candidates"] as? [[String: Any]])
        #expect(renderCandidates.first?["path"] as? String == target.path)
        #expect(renderCandidates.first?["snapshotAvailable"] as? Bool == true)
        let analysis = try #require(measurements.first { $0["kind"] as? String == CacheKind.analysis.rawValue })
        #expect(analysis["bytes"] is NSNull)
        let analysisCandidates = try #require(analysis["candidates"] as? [[String: Any]])
        #expect(analysisCandidates.first?["snapshotAvailable"] as? Bool == false)
        #expect(analysisCandidates.first?["safetyIssue"] as? String == "扫描身份快照不可用")
        let issues = try #require(analysis["issues"] as? [[String: Any]])
        #expect(issues.first?["path"] as? String == unavailable.path)
        #expect(issues.first?["reason"] as? String == "permission")
        #expect(issues.first?["detail"] as? String == "读取目录被拒绝")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("bookmark"))
        #expect(!text.contains("contents"))
        #expect(!text.contains("ancestors"))
        #expect(!text.contains("entries"))
    }

    @Test func replacesLatestScanAndKeepsZeroDistinctFromIncomplete() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("scan-logs-v1/latest.json")
        let logger = JSONScanDiagnosticLogger(fileURL: file)
        let earlierID = UUID()
        _ = try logger.write(results: [earlierID: ParentScanResult(libraries: [], issues: [
            .failure(URL(fileURLWithPath: "/earlier/failed"), "earlier error")
        ])], folderPaths: [earlierID: "/earlier"], startedAt: Date())
        let id = UUID()
        let library = Library(url: URL(fileURLWithPath: "/latest/Empty.fcpbundle"),
            measurements: [CacheMeasurement(kind: .render), CacheMeasurement(kind: .analysis)])
        _ = try logger.write(results: [id: ParentScanResult(libraries: [library], issues: [])],
            folderPaths: [id: "/latest"], startedAt: Date())
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["latest.json"])
        let data = try Data(contentsOf: file)
        #expect(!String(decoding: data, as: UTF8.self).contains("earlier error"))
        let log = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(log["hasIssues"] as? Bool == false)
        #expect(log["issueCount"] as? Int == 0)
        let folders = try #require(log["folders"] as? [[String: Any]])
        let libraries = try #require(folders.first?["libraries"] as? [[String: Any]])
        let measurements = try #require(libraries.first?["measurements"] as? [[String: Any]])
        #expect(measurements.count == 2)
        #expect(measurements.allSatisfy { $0["bytes"] as? Int == 0 })
    }

    @Test func sortsFolderLibraryCandidateAndIssuePaths() throws {
        let root = try temporaryDirectory()
        let firstID = UUID(), secondID = UUID()
        let file = root.appendingPathComponent("latest.json")
        let library = Library(url: URL(fileURLWithPath: "/a/Z.fcpbundle"), measurements: [
            CacheMeasurement(kind: .render, candidates: [
                CacheCandidate(url: URL(fileURLWithPath: "/a/z"), bytes: 2),
                CacheCandidate(url: URL(fileURLWithPath: "/a/a"), bytes: 1)
            ], issues: [.failure(URL(fileURLWithPath: "/a/z"), "last"), .failure(URL(fileURLWithPath: "/a/a"), "first")])
        ])
        _ = try JSONScanDiagnosticLogger(fileURL: file).write(results: [
            secondID: ParentScanResult(libraries: [], issues: []),
            firstID: ParentScanResult(libraries: [library,
                Library(url: URL(fileURLWithPath: "/a/A.fcpbundle"), measurements: [])], issues: [])
        ], folderPaths: [secondID: "/z", firstID: "/a"], startedAt: Date())
        let log = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let folders = try #require(log["folders"] as? [[String: Any]])
        #expect(folders.compactMap { $0["path"] as? String } == ["/a", "/z"])
        let libraries = try #require(folders.first?["libraries"] as? [[String: Any]])
        #expect(libraries.compactMap { $0["path"] as? String } == ["/a/A.fcpbundle", "/a/Z.fcpbundle"])
        let measurements = try #require(libraries.last?["measurements"] as? [[String: Any]])
        let candidates = try #require(measurements.first?["candidates"] as? [[String: Any]])
        #expect(candidates.compactMap { $0["path"] as? String } == ["/a/a", "/a/z"])
        let issues = try #require(measurements.first?["issues"] as? [[String: Any]])
        #expect(issues.compactMap { $0["path"] as? String } == ["/a/a", "/a/z"])
    }

    @Test func distinguishesAuthorizedButUnscannedFoldersFromResultsWithoutRememberedPaths() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("latest.json")
        let pendingID = UUID(), completedID = UUID()
        _ = try JSONScanDiagnosticLogger(fileURL: file).write(
            results: [completedID: ParentScanResult(libraries: [], issues: [])],
            folderPaths: [pendingID: "/fixture/pending"], startedAt: Date())

        let log = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(log["authorizedFolderCount"] as? Int == 1)
        #expect(log["scannedFolderCount"] as? Int == 1)
        #expect(log["libraryCount"] as? Int == 0)
        #expect(log["candidateCount"] as? Int == 0)
        let folders = try #require(log["folders"] as? [[String: Any]])
        #expect(folders.count == 2)
        let pending = try #require(folders.first { $0["id"] as? String == pendingID.uuidString })
        #expect(pending["path"] as? String == "/fixture/pending")
        #expect(pending["hasResult"] as? Bool == false)
        #expect((pending["libraries"] as? [[String: Any]])?.isEmpty == true)
        let completed = try #require(folders.first { $0["id"] as? String == completedID.uuidString })
        #expect(completed["path"] is NSNull)
        #expect(completed["hasResult"] as? Bool == true)
    }

    @Test func writeFailureThrowsInsteadOfReportingSuccess() throws {
        let root = try temporaryDirectory()
        let blocker = root.appendingPathComponent("regular-file")
        try Data("not a directory".utf8).write(to: blocker)
        let logger = JSONScanDiagnosticLogger(fileURL: blocker.appendingPathComponent("latest.json"))
        #expect(throws: (any Error).self) {
            _ = try logger.write(results: [:], folderPaths: [:], startedAt: Date())
        }
        #expect(try Data(contentsOf: blocker) == Data("not a directory".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanDiagnosticLog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
