// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import AppKit
import Foundation

enum FolderPicker {
    /// 选择存放资源库的父文件夹，由系统提供文件浏览和取消操作。
    @MainActor
    static func chooseLibraryParentFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "添加 Final Cut Pro 资源库"
        panel.message = "请选择存放 Final Cut Pro 资源库的文件夹。"
        panel.prompt = "选择资源库所在的文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.canCreateDirectories = false

        if let movies = FileManager.default.urls(
            for: .moviesDirectory,
            in: .userDomainMask
        ).first {
            panel.directoryURL = movies
        }

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }
}
