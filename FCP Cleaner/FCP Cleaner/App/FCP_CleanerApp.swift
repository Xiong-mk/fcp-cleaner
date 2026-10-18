// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import AppKit
import SwiftUI

@main
struct FCPCleanerApp: App {
    @State private var viewModel = LibraryListViewModel()
    @StateObject private var updaterManager = UpdaterManager()
    @NSApplicationDelegateAdaptor(CleanerAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("FCP Cleaner") {
            ContentView(viewModel: viewModel)
                .onAppear { delegate.viewModel = viewModel }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    viewModel.cancelScan()
                    viewModel.folderStore.stopAllAccess()
                }
        }
        .defaultSize(width: 880, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FCP Cleaner", action: showAboutPanel)
                Button("开源许可证（GPL-3.0-or-later）") { openLegalDocument("LICENSE") }
                Button("第三方与素材声明") { openLegalDocument("THIRD_PARTY_NOTICES") }
                Button("Sparkle 许可证") { openLegalDocument("Sparkle-LICENSE") }
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updaterManager: updaterManager)
            }
        }

        Settings {
            UpdateSettingsView(updaterManager: updaterManager)
        }
    }

    private func showAboutPanel() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "V\(version)",
            .version: "",
            .credits: NSAttributedString(string: "作者：Steve · Copyright © 2026 Steve\nGPL-3.0-or-later · 不提供任何担保\n可按 GPL 第 3 版或任何后续版本修改与分发。\n完整许可证见应用菜单「开源许可证」。", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraphStyle
            ])
        ])
    }

    private func openLegalDocument(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class CleanerAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: LibraryListViewModel?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.isCleaning else { return .terminateNow }
        if !terminationPending {
            terminationPending = true
            viewModel.cancelCleanup()
            Task {
                await viewModel.waitForCleanup()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
