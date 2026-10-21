# v0.1.0 隐私修订发布清单

隐私修订保持显示版本 **0.1.0**，将构建号从 **1** 递增到 **2**；目标仍为 [v0.1.0 Pre-release](https://github.com/Xiong-mk/fcp-cleaner/releases/tag/v0.1.0)。发布应保留 Release 本体，替换旧安装包及所有依赖其内容的校验/元数据/源码附件。此清单描述本次产物和验收要求，远程实际附件以 Release 页面为准。

## 产物与本地验证

- App 为 arm64 / x86_64 通用架构，最低 macOS 14.0；保留原 SwiftUI、App Sandbox、授权/扫描/二次确认/系统废纸篓功能。
- Release 在中性工作区构建，Swift / Clang 源和调试路径映射到中性位置；dSYM 与构建日志保留本机，不能上传。
- 原有 ad-hoc 签名策略保留，包处理后由内向外重签，使用 strict / deep 验证。此版本仍未经过 Developer ID 签名或 Apple 公证。
- 133 项 Swift 测试通过（12 个 suite）；真实外接盘、最低系统及另一台 Intel Mac 不能由此视为通过。
- 使用实际暂存 blob、源码允许列表字节和最终 ZIP/DMG 的独立隐私检查；不要仅凭 .gitignore 或最新源码零命中决定可发布。

| 附件 | 用途 |
|---|---|
| `FCP-Cleaner-0.1.0.zip` | Sparkle 完整更新包及手动安装 |
| `FCP-Cleaner-0.1.0.dmg` | 保留背景、安装说明及 Applications 拖拽入口 |
| `FCP-Cleaner-0.1.0.json` / `.sha256` | 包长度、版本、公钥、签名、哈希及 appcast 关联 |
| `FCP-Cleaner-0.1.0.dmg.sha256` | DMG 校验 |
| `FCP-Cleaner-v0.1.0-source.zip` / `.sha256` / `.manifest.json` | 与修订标签逐文件一致的完整对应源码 |
| `SHA256SUMS.txt` | 以上发布附件及 appcast 的汇总校验 |

附件的精确哈希和长度由脚本写入机器可检查的元数据与校验文件，避免文档中的旧值被误用于新包。源码包修改后必须重新生成，包含实际发布的构建脚本、许可和依赖锁。

## 更新兼容与发布顺序

现有构建 1 和修订构建 2 使用同一个 Sparkle 公钥、Bundle ID 与 HTTPS feed。新 feed 只保留可用的安全修订条目；不要继续保留指向旧问题包的构建 1 签名/长度。构建号比较和 Ed25519 验签通过不等于实际安装与重启已测试。

先在本地完成所有替代品验证，备份旧资产并取得最终批准；随后上传并匿名下载验证新附件，最后部署 `main:/docs/appcast.xml`，防止更新源宣布不可下载的包。旧 Asset ID 和旧文件名 URL 必须单独复核：文件名复用时，应验证返回的是新内容，不能把 HTTP 200 直接当成旧文件仍存在或旧文件已消失。

历史作者隐私整改会改变提交 SHA 和标签指向。源码 manifest 必须与更新后的标签一致；普通追加验收记录无需重做源码包，本次源码/构建修订需要重做。具体操作见 [发布流程](publishing.md)、[隐私构建与检查](release-privacy.md) 和 [提交/发布隐私检查](privacy-checks.md)。

## 需要单独验收的范围

- 干净用户环境中的原生面板授权、书签恢复及重启。
- 从真实旧构建完整发现、下载、验签、安装、重新启动和版本确认；没有记录的项目不得标为通过。
- 独立 macOS 14、Intel Mac、真实外接 SSD/HDD 与断盘/重连。
- 可丢弃真实 FCP 测试库中的重新渲染和分析。
- 另一台 Mac 的安装及 Gatekeeper；不建议关闭系统安全设置。

本地清理的最终路径竞态仍存在，使用条件与后续方案见 [安全边界](security.md) 和 [竞态技术方案](cleanup-race-design.md)。估算占用不等于实际释放空间；系统废纸篓失败不会改用永久删除。
