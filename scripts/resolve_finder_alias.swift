// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve
import Foundation
import CoreFoundation

// Finder stores a classic AliasRecord inside its icon-view property list.
// Convert that record using the system compatibility API, then resolve without
// UI or mounting volumes. This does not modify the saved Finder layout.
let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Expected alias data and background path") }
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(nil, data as CFData) else {
    fatalError("Invalid Finder background AliasRecord")
}
var stale = false
let resolved = try URL(resolvingBookmarkData: bookmark.takeRetainedValue() as Data,
                       options: [.withoutUI, .withoutMounting], relativeTo: nil,
                       bookmarkDataIsStale: &stale)
let expected = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath()
guard resolved.resolvingSymlinksInPath() == expected,
      FileManager.default.fileExists(atPath: expected.path) else {
    fatalError("Finder background alias did not resolve within the remounted image")
}
print("Finder background alias resolved after remount")
