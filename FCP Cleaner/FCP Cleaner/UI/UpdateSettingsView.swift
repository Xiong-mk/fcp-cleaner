// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updaterManager: UpdaterManager

    var body: some View {
        Form {
            Section("软件更新") {
                LabeledContent("当前版本", value: currentVersion)
                Toggle("自动检查更新", isOn: Binding(
                    get: { updaterManager.automaticallyChecksForUpdates },
                    set: updaterManager.setAutomaticallyChecksForUpdates
                ))
                .disabled(!updaterManager.isStarted)

                Toggle("自动下载更新", isOn: Binding(
                    get: { updaterManager.automaticallyDownloadsUpdates },
                    set: updaterManager.setAutomaticallyDownloadsUpdates
                ))
                .disabled(!updaterManager.isStarted || !updaterManager.allowsAutomaticUpdates)

                Button("检查更新…", action: updaterManager.checkForUpdates)
                    .disabled(!updaterManager.isStarted || !updaterManager.canCheckForUpdates)

                if let message = updaterManager.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("软件更新")
    }

    private var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updaterManager: UpdaterManager

    var body: some View {
        Button("检查更新…", action: updaterManager.checkForUpdates)
            .disabled(!updaterManager.isStarted || !updaterManager.canCheckForUpdates)
    }
}
