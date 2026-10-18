# 第三方版权与素材声明

本项目源代码的项目许可证为 **GPL-3.0-or-later**；该声明不改变第三方材料、系统组件或商标的权利。审查日期：2026-10-18。

## 应用与测试依赖

| 组件 | 使用方式 | 来源与权利说明 |
| --- | --- | --- |
| SwiftUI、AppKit、Foundation、Observation、Darwin | Apple SDK / 系统模块 | 由 macOS、Swift 工具链及 Xcode 提供；本仓库不内嵌这些框架源码或二进制。各组件适用其原有条款，不由本项目重新许可。 |
| Swift Testing (`Testing`) | 仅测试 target | 工具链提供；上游 [swiftlang/swift-testing](https://github.com/swiftlang/swift-testing) 使用 Apache-2.0 with Runtime Library Exception，本仓库未复制其源码或作为应用运行时分发。 |
| SF Symbols / 系统图形 | SwiftUI `systemImage` 系统调用 | 由系统渲染，未导出或打包独立符号素材；适用 Apple 对系统图形的条款。 |
| Sparkle 2.10.0 | Swift Package Manager 依赖；随应用嵌入 `Sparkle.framework`，提供自动更新 | 上游 [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle/tree/2.10.0)。主许可证为 MIT，另含 bsdiff、sais-lite、Ed25519 及签名验证代码的版权与许可声明；完整原文随应用保存在 `Resources/Legal/Sparkle-LICENSE.txt`。 |

`Package.resolved` 记录 Sparkle 2.10.0 的解析版本与源码修订。`Resources/Legal/Sparkle-LICENSE.txt` 原样复制自该版本官方二进制包中的 `LICENSE`，保留其第三方许可声明。升级或新增依赖时，应同步检查并更新相关版权与许可文本。

## 应用图标

`FCP Cleaner/FCP Cleaner/Resources/Assets.xcassets/AppIcon.appiconset/` 中的蓝色场记板与扫帚图标为 **AI 生成**，由维护者提供；来源已于 2026-10-18 经维护者确认。现有记录未注明生成服务、模型或生成日期，不据此虚构绘制作者或第三方授权。

维护者将其有权许可的该图标部分按 GPL-3.0-or-later 随项目提供；AI 输出是否构成可受版权保护的作品取决于适用规则。本声明不保证生成服务的条款或第三方权利，正式分发前维护者应保留生成来源与可使用该素材的记录。它不是 Apple 或参考产品提供的官方图标。

## GNU GPLv3 许可证正文

根目录 `LICENSE` 及应用内 `Resources/Legal/LICENSE.txt` 是 GNU GPLv3 官方完整原文（Version 3, 29 June 2007），版权归 Free Software Foundation, Inc.。许可证文本本身的复制规则保留原样。下载来源、字节数与校验值见 [license-provenance.md](docs/license-provenance.md)。`or-later` 的项目选择由 README 和 SPDX 声明表达，未改写官方许可正文。

## 参考材料与商标

公开项目不包含参考产品的提取 JavaScript、source map、专有图标或品牌素材。本地 `inspection/`、技术分析及 `local-evidence/` 是不随仓库或发布包分发的工作材料，不在本项目 GPL 授权范围。

Final Cut Pro、macOS、Xcode、SwiftUI 等名称或商标属于相应权利人；提及这些名称仅用于说明兼容性或技术用途，不代表 Apple Inc. 或其他第三方认可本项目。
