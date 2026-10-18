// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Testing
@testable import FCP_Cleaner

@Suite
struct UpdateConfigurationTests {
    private let publicKey = Data(repeating: 1, count: 32).base64EncodedString()

    @Test(arguments: [nil, "", "  \n"] as [String?])
    func absentFeedKeepsUpdaterStopped(_ feed: String?) {
        #expect(UpdateConfiguration.issue(feedURL: feed, publicKey: publicKey) == .missingFeed)
    }

    @Test(arguments: ["http://updates.example.com/appcast.xml", "file:///tmp/appcast.xml",
                      "$(SPARKLE_FEED_URL)", "https://", "https://user:password@updates.example.com/appcast.xml"])
    func refusesUnsafeOrUnexpandedFeed(_ feed: String) {
        #expect(UpdateConfiguration.issue(feedURL: feed, publicKey: publicKey) == .invalidFeed)
    }

    @Test(arguments: [nil, "", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()] as [String?])
    func refusesMissingOrMalformedPublicKey(_ key: String?) {
        #expect(UpdateConfiguration.issue(feedURL: "https://updates.example.com/appcast.xml", publicKey: key) == .invalidPublicKey)
    }

    @Test func acceptsHTTPSAndEd25519PublicKey() {
        #expect(UpdateConfiguration.issue(feedURL: "https://updates.example.com/appcast.xml", publicKey: publicKey) == nil)
    }
}
