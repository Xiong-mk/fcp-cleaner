// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation

struct FolderBookmarkRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var path: String
    var bookmarkData: Data
}

@MainActor
protocol FolderBookmarkStorage {
    func load() throws -> [FolderBookmarkRecord]
    func save(_ records: [FolderBookmarkRecord]) throws
}

/// 只在应用的 Application Support（沙盒容器内）存放轻量授权记录。
@MainActor
struct JSONFolderBookmarkStorage: FolderBookmarkStorage {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.example.FCP-Cleaner")
            .appendingPathComponent("authorized-folders-v1.json")
    }

    func load() throws -> [FolderBookmarkRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return try JSONDecoder().decode([FolderBookmarkRecord].self, from: data)
    }

    func save(_ records: [FolderBookmarkRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

struct ResolvedFolderBookmark {
    let url: URL
    let isStale: Bool
}

@MainActor
protocol FolderBookmarkClient {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedFolderBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func canonicalFolderURL(for url: URL) throws -> URL
}

@MainActor
struct SecurityScopedFolderBookmarkClient: FolderBookmarkClient {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil // app-scoped，而非 document-scoped
        )
    }

    func resolve(_ data: Data) throws -> ResolvedFolderBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedFolderBookmark(url: url, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    func canonicalFolderURL(for url: URL) throws -> URL {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return canonical
    }
}
