// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Combine
import Foundation
import Sparkle

/// Validate before starting Sparkle so a build without a feed remains usable.
enum UpdateConfiguration {
    enum Issue: Equatable {
        case missingFeed, invalidFeed, invalidPublicKey
    }

    static func issue(feedURL: String?, publicKey: String?) -> Issue? {
        guard let feedURL, !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingFeed
        }
        guard !feedURL.contains("$("),
              let url = URLComponents(string: feedURL),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.fragment == nil else { return .invalidFeed }
        guard let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32 else {
            return .invalidPublicKey
        }
        return nil
    }
}

/// One controller for the application's lifetime. Sparkle owns persisted preferences.
@MainActor
final class UpdaterManager: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var isStarted = false
    @Published private(set) var statusMessage: String?

    private let updaterController: SPUStandardUpdaterController

    init(bundle: Bundle = .main) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = updaterController.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main).assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.allowsAutomaticUpdates)
            .receive(on: RunLoop.main).assign(to: &$allowsAutomaticUpdates)

        let issue = UpdateConfiguration.issue(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        if let issue {
            statusMessage = issue == .missingFeed
                ? "更新服务尚未启用，当前版本仍可正常使用。"
                : "更新服务配置无效，请联系开发者。"
            return
        }
        do {
            try updater.start()
            isStarted = true
        } catch {
            statusMessage = "无法启动更新服务：\(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard isStarted, canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isStarted else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard isStarted, allowsAutomaticUpdates else { return }
        updaterController.updater.automaticallyDownloadsUpdates = enabled
    }
}
