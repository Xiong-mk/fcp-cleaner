# v0.1.0 发布清单

目标仓库：[Xiong-mk/fcp-cleaner](https://github.com/Xiong-mk/fcp-cleaner)。已发布标签：**v0.1.0**（2026-10-19），应用版本 **0.1.0（构建 1）**。这是 ad-hoc 签名、未公证的预发布测试版；发布准备、线上托管验证与实际升级安装分开记录。

## 本地准备

- [x] 公开源码、GPL-3.0-or-later 许可、随应用分发的许可资料及第三方声明已整理。
- [x] App / UI / Models / Services / ViewModels / Resources 分组、共享 scheme 和测试宿主依赖已检查。
- [x] 已集成 Sparkle 2.10.0，设置页、菜单、EdDSA 公钥、沙盒安装服务及由内向外的 ad-hoc 签名流程已准备。
- [x] `SUFeedURL` 配置为 `https://Xiong-mk.github.io/fcp-cleaner/appcast.xml`。
- [x] GitHub 更新包与 appcast 准备脚本、源码允许列表审查、发布说明和 Pages 页面已准备。
- [x] 最终应用版本 0.1.0、构建 1，arm64 / x86_64 通用架构；代码签名与更新包 EdDSA 签名验证通过。
- [x] 本轮 133 项测试通过（12 个 suite）。
- [x] 最终源码 ZIP、SHA-256 和逐文件 manifest 已生成，82 项与 `v0.1.0` 标签源码一致。
- [x] 待提交文件已审查，未包含真实资源库、媒体、用户路径、书签、日志、证书或私钥。

更新 ZIP 为 `FCP-Cleaner-0.1.0.zip`，长度 **4,778,517 字节**，SHA-256：

```text
8290aa71ba68b1bb756ec306a69d199b393aa4e1155e8cbb91f24e65b054466f
```

此前构建与测试详情见 [任务七验证记录](task-seven-validation.md) 和 [Sparkle 验证记录](sparkle.md)。源码归档使用允许列表；`build/`、`inspection/` 和 `local-evidence/` 不是公开附件。

## GitHub 发布与线上验收

- [x] 公开仓库 `Xiong-mk/fcp-cleaner` 已创建。
- [x] 最终源码已推送到 `main`；`v0.1.0` 标签对应源码提交 `adaf168fe1e79521525d823a21a7cd7809ec9372`。
- [x] [GitHub Pre-release](https://github.com/Xiong-mk/fcp-cleaner/releases/tag/v0.1.0) 已发布，共 7 个附件：
  - `FCP-Cleaner-0.1.0.zip`：完整应用，供 Sparkle 使用与手动下载。
  - `FCP-Cleaner-v0.1.0-source.zip`：相同版本的完整对应源码。
  - 对应的 SHA-256、源码 manifest 和更新包元数据。
- [x] 从 Release 实际下载 ZIP；字节长度、SHA-256、CryptoKit Ed25519 验签、解压 App 代码签名、0.1.0（1）、正式 feed 和公钥核对均通过。
- [x] Pages 已选择 `Deploy from a branch` → `main` → `/docs`，部署完成，强制 HTTPS 已开启。
- [x] [项目主页](https://Xiong-mk.github.io/fcp-cleaner/) 与 [appcast.xml](https://Xiong-mk.github.io/fcp-cleaner/appcast.xml) 返回 HTTPS 200；远程 appcast 889 字节，与本地逐字节一致，XML 中附件 URL 可下载。
- [x] 公网源码 ZIP 已下载，SHA-256 与本地一致，82 项 manifest 与标签源码一致。
- [ ] 正式应用通过「检查更新…」成功读取正式源；首发同版本应显示已是最新版本（本轮尚未点击验证）。

公网源码 ZIP `FCP-Cleaner-v0.1.0-source.zip` 的 SHA-256：

```text
dad3f5e8a77ad298551818be9b224a2b219aab6bff8a1824d0c1ffb00a7a0cc6
```

`v0.1.0` 标签中的文档保留发版时快照，`main` 包含 2026-10-19 后续验收记录。Release 源码包继续对应原标签，勿因这些记录更新而重建或替换。

发布步骤见 [GitHub Pages + Releases 发布流程](publishing.md)，本版对外说明见 [v0.1.0 说明](releases/v0.1.0.md)。必须先上传并验证不再改动的更新 ZIP，再部署含该条目的 `docs/appcast.xml`。

首发 appcast 只有 **0.1.0（1）**，没有更高版本供其升级。同版「已是最新版本」可验证正式源联通与解析；它不证明更新包下载、安装与重启成功。后续每次发版必须递增 `CFBundleVersion`，再从真实旧版验证升级。

## 仍需设备与分发验收

- [ ] 在干净用户环境用原生面板完成选择、取消、授权恢复、退出重启及移除授权测试。
- [ ] 在独立 macOS 14、Intel Mac 与真实外接 SSD/HDD 上验收权限、废纸篓和拔插表现。
- [ ] 用专门创建且可丢弃的真实 FCP 测试库验证清理后重新渲染和分析，记录 FCP 版本。
- [ ] 在另一台 Mac 验收手动安装及 Gatekeeper 表现；当前 **ad-hoc、未公证**，不声称已通过 Developer ID 或公证验收。
- [ ] 后续更高构建号发布后，从较旧构建完成发现、下载、签名校验、安装、重新启动和版本确认。

当前 Bundle ID 为 `com.example.FCP-Cleaner`；更换身份前应评估 Sparkle helper 标识、沙盒数据与书签授权迁移。估算容量不等于实际释放空间；正式数据清理前仍应遵守应用的预览、退出 FCP 与二次确认流程。
