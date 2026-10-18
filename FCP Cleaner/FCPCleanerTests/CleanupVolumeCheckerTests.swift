// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

/// All URLs are synthetic. This reader never inspects mounted volumes or user files.
nonisolated struct TestCleanupVolumeResources: CleanupVolumeResourceReading {
    var properties = CleanupVolumeProperties(isLocal: true, isReadOnly: false)
    var ubiquitousPaths: Set<String> = []
    var volumeError: NSError?
    var ubiquitousErrors: [String: NSError] = [:]
    var missingUbiquitousMetadata = false

    func volumeProperties(at url: URL) throws -> CleanupVolumeProperties {
        if let volumeError { throw volumeError }
        return properties
    }

    func isUbiquitousItem(at url: URL) throws -> Bool? {
        if let error = ubiquitousErrors[url.path] { throw error }
        return missingUbiquitousMetadata ? nil : ubiquitousPaths.contains(url.path)
    }
}

@Suite
struct CleanupVolumeCheckerTests {
    private let externalTarget = URL(fileURLWithPath:
        "/Volumes/External SSD/Projects/Demo.fcpbundle/Event A/Render Files/High Quality Media")

    @Test(arguments: [
        "/Volumes/External SSD/Projects/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/外接固态硬盘/剪辑/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External HDD/Projects/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/mnt/custom-mount/Projects/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Users/test/Movies/Demo.fcpbundle/Event A/Render Files/High Quality Media"
    ])
    func acceptsWritableLocalVolumesRegardlessOfMountName(_ path: String) throws {
        let checker = LocalCleanupVolumeChecker(resources: TestCleanupVolumeResources())
        try checker.requireSupported(URL(fileURLWithPath: path))
    }

    @Test(arguments: [
        CleanupVolumeProperties(isLocal: false, isReadOnly: false),
        CleanupVolumeProperties(isLocal: nil, isReadOnly: false),
        CleanupVolumeProperties(isLocal: true, isReadOnly: true),
        CleanupVolumeProperties(isLocal: true, isReadOnly: nil),
        CleanupVolumeProperties(isLocal: nil, isReadOnly: nil)
    ])
    func rejectsNetworkReadOnlyAndUnknownVolumeState(_ properties: CleanupVolumeProperties) {
        var resources = TestCleanupVolumeResources()
        resources.properties = properties
        expectUnsupported(LocalCleanupVolumeChecker(resources: resources), at: externalTarget)
    }

    @Test(arguments: [
        "/Users/test/Library/CloudStorage",
        "/Users/test/Library/CloudStorage/Provider/Projects/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Users/test/library/cloudstorage",
        "/Users/test/LIBRARY/CLOUDSTORAGE/Provider/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Users/test/Library/Mobile Documents",
        "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Users/test/lIbRaRy/mObIlE dOcUmEnTs",
        "/Volumes/External SSD/Library/CloudStorage/Provider/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/Library/Mobile Documents/Demo.fcpbundle/Event A/Render Files/High Quality Media"
    ])
    func rejectsCloudLocationsIncludingRootsAndMixedCase(_ path: String) {
        let checker = LocalCleanupVolumeChecker(resources: TestCleanupVolumeResources())
        expectUnsupported(checker, at: URL(fileURLWithPath: path))
    }

    @Test(arguments: [
        "/Volumes/External SSD/Library/CloudStorage Archive/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/Library/Mobile Documents Backup/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/Film Library/CloudStorage/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/Library/Projects/CloudStorage/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/CloudStorage/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/Mobile Documents/Demo.fcpbundle/Event A/Render Files/High Quality Media"
    ])
    func cloudWordsInUnrelatedPathComponentsRemainAllowed(_ path: String) throws {
        let checker = LocalCleanupVolumeChecker(resources: TestCleanupVolumeResources())
        try checker.requireSupported(URL(fileURLWithPath: path))
    }

    @Test(arguments: [
        "/Volumes/External SSD/Projects/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/Projects/Demo.fcpbundle/Event A/Render Files",
        "/Volumes/External SSD/Projects/Demo.fcpbundle/Event A",
        "/Volumes/External SSD/Projects/Demo.fcpbundle",
        "/Volumes/External SSD/Projects",
        "/Volumes/External SSD",
        "/Volumes"
    ])
    func rejectsUbiquitousTargetOrAnyEnclosingLocation(_ ubiquitousPath: String) {
        var resources = TestCleanupVolumeResources()
        resources.ubiquitousPaths = [ubiquitousPath]
        expectUnsupported(LocalCleanupVolumeChecker(resources: resources), at: externalTarget)
    }

    @Test func absentUbiquitousFlagDoesNotRejectKnownWritableLocalVolume() throws {
        var resources = TestCleanupVolumeResources()
        resources.missingUbiquitousMetadata = true
        try LocalCleanupVolumeChecker(resources: resources).requireSupported(externalTarget)
    }

    @Test(arguments: [Int(EACCES), Int(ENODEV), Int(ENOENT)])
    func propagatesVolumeMetadataFailuresIncludingDisconnectedDevice(_ code: Int) {
        var resources = TestCleanupVolumeResources()
        resources.volumeError = NSError(domain: NSPOSIXErrorDomain, code: code)
        expectPOSIXFailure(code, checker: LocalCleanupVolumeChecker(resources: resources))
    }

    @Test(arguments: [
        "/Volumes/External SSD/Projects/Demo.fcpbundle/Event A/Render Files/High Quality Media",
        "/Volumes/External SSD/Projects/Demo.fcpbundle",
        "/Volumes/External SSD"
    ])
    func propagatesAncestorCloudMetadataFailure(_ path: String) {
        var resources = TestCleanupVolumeResources()
        resources.ubiquitousErrors[path] = NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV))
        expectPOSIXFailure(Int(ENODEV), checker: LocalCleanupVolumeChecker(resources: resources))
    }

    private func expectUnsupported(_ checker: LocalCleanupVolumeChecker, at target: URL,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try checker.requireSupported(target)
            Issue.record("Expected unsupportedVolume for \(target.path)", sourceLocation: sourceLocation)
        } catch CleanupExecutionError.unsupportedVolume {
            // The policy rejection must remain distinct from a resource-reading failure.
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    private func expectPOSIXFailure(_ code: Int, checker: LocalCleanupVolumeChecker,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try checker.requireSupported(externalTarget)
            Issue.record("Expected POSIX error \(code)", sourceLocation: sourceLocation)
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain, sourceLocation: sourceLocation)
            #expect(failure.code == code, sourceLocation: sourceLocation)
        }
    }
}
