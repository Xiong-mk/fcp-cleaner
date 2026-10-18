# 任务七：开源发布准备验证

日期：2026-10-18（Asia/Shanghai）。实测：macOS 27.0，Xcode 27.1（27A9275），Apple Swift 6.4，My Mac / arm64。部署目标保持 macOS 14.0。首版候选版本统一为 0.1.0，构建号 1。

## 工程与许可

- 应用源码按 App、UI、Models、Services、ViewModels、Resources 整理；保留现有 Xcode 工程入口路径与测试分组。
- 共享 scheme 的应用/测试 target ID 已与工程真实 ID 对齐，补上 `PBXTargetDependency`、`PBXContainerItemProxy` 和 `TestTargetID`，修复干净检出后的宿主构建顺序。
- 清除 iOS/visionOS 模板设置，平台保持 macOS。通过 `FCPCLEANER_BUNDLE_IDENTIFIER` 构建变量支持隔离测试身份，默认开发身份不变。
- GNU 官方 GPLv3 原文下载并原样保存，来源与校验值见 [许可证记录](license-provenance.md)。26 个 Swift 文件和两个发布/测试脚本均含 GPL-3.0-or-later SPDX 与版权通知。
- 应用包内含 `LICENSE.txt`、`COPYING.txt`、`THIRD_PARTY_NOTICES.txt`；About 显示版权、GPL-3.0-or-later 及无担保通知，应用菜单可打开许可正文与第三方声明。
- 维护者确认既有图标为 AI 生成，已记录来源状态；没有虚构生成服务或素材作者。
- 第三方静态检查材料、原技术分析和此前含个人路径的验收材料保留本地，根 `.gitignore` 与 `.gitattributes` 阻止常规提交/导出。发布脚本另以允许列表限定源码包内容。
- 两处旧回归测试原先沿用了本机卷名与项目名，已替换为明确虚构的内存测试路径；发布脚本同时检查用户路径和非演示卷名，避免这些名称进入公开源码。

## 构建与测试结果

| 验证 | 结果 |
| --- | --- |
| Xcode MCP `BuildProject`（当前应用工程，Debug） | 成功，无构建错误 |
| `./scripts/test.sh` 从 `clean` 开始构建并测试 | 成功，证明共享 scheme 和显式宿主依赖适用于全新测试构建 |
| 全量测试 | 129 个测试声明 / 11 个 suite，展开参数为 **232 个执行用例**；全部通过，失败 0、跳过 0、预期失败 0 |
| Release `xcodebuild … -configuration Release … build` | 成功，arm64，应用版本 0.1.0 / 1，最低系统元数据 14.0 |
| Release 许可资源 | 三份文本均存在，打包的 LICENSE 与官方正文 SHA-256 相同，第三方声明与根文档逐字节一致 |
| Release 签名完整性与权限 | 本机签名可验证；App Sandbox、用户选择文件读写、app-scoped bookmarks 三项权限存在，无测试路径例外 |
| Xcode 分类结果预览 | 渲染成功，README 截图仅使用虚构演示路径与容量 |
| `python3 scripts/prepare_release.py --check` | 通过：许可、头部声明、版本、共享 scheme 与发布文件边界一致 |
| 源码 ZIP | 61 个允许列表文件，逐文件哈希匹配；排除本地材料；解压后无 `.git` 也能审查；重复生成的 ZIP 校验值相同 |

本次新增 17 个测试声明，展开参数为 **26 个用例**，原有 206 个用例均通过。覆盖缓存容量 `Int64` 上限/溢出与负值、异常目录枚举越界/重复/循环、特殊文件、空嵌套目录、分类合计溢出隔离、嵌套系统错误分类、选择合计边界以及未扫描/无路径扫描记录。

Swift Testing 控制台按声明汇总为 129；xcresult 的设备配置展开总数为 232，其中 27 个声明包含动态参数。两种口径不混用。

初次受限 shell 调用因系统 XPC 权限中止；后续在允许 Xcode 系统服务的环境运行。新增测试首次编译遇到 Swift Testing 宏的 key path 推断问题，改用等价闭包后完成上述全量通过。应用首次构建发现 About panel 不支持所用版权键，已将通知放入 credits，最终构建成功。

构建仅出现“未依赖 AppIntents，跳过元数据提取”的工具提示；测试宿主还记录系统 `com.apple.linkd.autoShortcut` 连接信息。最终无编译错误或测试失败，xcresult 未报告 runtime warning。

## 测试隔离与验证边界

`scripts/test.sh` 每次使用新 UUID 派生的独立应用 Bundle ID，测试宿主不会加载原应用保存的书签。所有文件系统集成数据均由测试新建在临时目录；实际废纸篓调用仅操作本次创建的虚拟缓存。未扫描或清理真实工作资源库，未永久删除文件或清空废纸篓。虚拟数据保留供本地核对。原始构建日志、xcresult 汇总与旧证据保存在忽略的本地目录，不进入发布源码。

本地 Release 使用开发签名，含调试访问权限，不是 Developer ID 公证安装包；没有向 GitHub 推送、创建标签或公开发布。独立 macOS 14、Intel、原生面板授权后的进程重启、外接设备物理拔插、不同文件系统废纸篓及真实可丢弃 FCP 库重新渲染/分析仍需人工验收。完整发布步骤见[首版清单](release.md)。
