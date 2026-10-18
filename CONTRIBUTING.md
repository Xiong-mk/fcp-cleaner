# 贡献指南

欢迎提交 Issue 和 Pull Request。先阅读 [README](README.md)、[架构](docs/architecture.md)和[安全边界](docs/security.md)。功能实现应以当前代码和测试为准，指南中的后续设想不等于已支持功能。

## 提交问题

说明应用版本、macOS/Xcode/FCP 版本、内置或外接盘及文件系统、重现步骤、预期和实际结果。最小样例应使用可丢弃的虚拟资源库。粘贴日志前删去个人名、磁盘名、完整路径等私密信息；不要提交真实素材、书签数据、证书、私钥或完整用户资源库。可通过 GitHub 仓库的 Security → Report a vulnerability 私下报告安全问题（维护者需先启用该入口）。

## 开发与验证

1. Fork 仓库，新建范围明确的分支，保持原生 SwiftUI/AppKit 交互与 App Sandbox。
2. 用 Xcode 27.1 打开 `FCP Cleaner/FCP Cleaner.xcodeproj`，使用共享 `FCP Cleaner` scheme。
3. 修改安全或文件系统行为时，补充能重现真实失败的测试。用可注入依赖模拟权限、断盘、FCP 运行、日志或系统废纸篓失败；文件系统集成测试仅使用本次创建的临时虚拟库。
4. 在仓库根目录运行 `./scripts/test.sh`，使用隔离 Bundle ID 全新构建并运行全部测试；Command-B 及 Release 构建也应通过。
5. 运行 `python3 scripts/prepare_release.py --check`，核对源文件声明、许可证、共享 scheme 和发布文件边界。
6. PR 描述解释触发场景、修改后行为、验证结果和未验证设备；行为变化同步更新文档和 `CHANGELOG.md`。

不要对真实工作资源库运行自动化清理，不要取消白名单、快照复验、明确选择、二次确认、日志及完成后的重扫。废纸篓 API 失败时保留数据并报告失败，不增加永久删除兜底。UI 容量必须来自真实操作结果与重扫，不能提前扣减或宣称释放空间。

Swift 文件放入现有功能分组，避免重复类型。测试使用 Swift Testing。保持改动聚焦，不为低影响改动添加仅复述实现的测试。

## 许可与来源

提交贡献即表示你有权提交该内容，并同意按项目 **GPL-3.0-or-later** 许可贡献；不要求转移版权。保留原有版权声明，按实际权属为新增代码添加自己的署名，不把其他人的代码改署为自己。

每个 Swift/Python/Shell 源文件保留相应注释形式的 SPDX，例如：

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Your Name
```

加入第三方代码、Swift Package、字体、图标或其他素材前，确认许可证兼容性，记录版本、来源、版权和须保留的通知，更新 `THIRD_PARTY_NOTICES.md`，并将需随二进制分发的通知加入 `Resources/Legal/`。禁止提交从参考产品提取的源码、Logo、专有资源，或用本项目许可证重新许可无权发布的材料。
