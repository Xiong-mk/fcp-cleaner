// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

@Suite
struct ScanIssueTests {
    private let path = URL(fileURLWithPath: "/fixture/Demo.fcpbundle/Event/Analysis Files")

    @Test(arguments: [Int(EACCES), Int(EPERM)])
    func recognizesPermissionFailureWrappedByFoundation(_ code: Int) {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: code)
        let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                            userInfo: [NSUnderlyingErrorKey: inner,
                                       NSLocalizedDescriptionKey: "读取缓存失败，请检查文件访问权限"])

        let issue = ScanIssue.reading(path, error: outer)

        #expect(issue.reason == .permission)
        #expect(issue.url == path)
        #expect(issue.detail == outer.localizedDescription)
    }

    @Test(arguments: [Int(ENOENT), Int(ENODEV), Int(ENXIO), Int(EIO), Int(ESTALE), Int(ENOTCONN)])
    func recognizesDisconnectedOrUnavailableStorageInsideWrapper(_ code: Int) {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: code)
        let outer = NSError(domain: "FixtureFileSystem", code: 1,
                            userInfo: [NSUnderlyingErrorKey: inner])

        #expect(ScanIssue.reading(path, error: outer).reason == .unavailable)
    }

    @Test func permissionFailureTakesPrecedenceOverOuterMissingFileError() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                            userInfo: [NSUnderlyingErrorKey: inner])

        #expect(ScanIssue.reading(path, error: outer).reason == .permission)
    }

    @Test func unknownFailureIsNotMisreportedAsMissingStorage() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))

        #expect(ScanIssue.reading(path, error: error).reason == .failed)
    }

    @Test func existingScanIssueRetainsOriginalPathAndExclusionReason() {
        let original = ScanIssue.excluded(path)

        let issue = ScanIssue.reading(URL(fileURLWithPath: "/different/parent"), error: original)

        #expect(issue.url == original.url)
        #expect(issue.reason == .excluded)
        #expect(issue.detail == original.detail)
        #expect(issue.id == original.id)
    }
}
