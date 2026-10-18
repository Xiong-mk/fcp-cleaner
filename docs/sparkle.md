# Sparkle 2 自动更新集成

对应开发手册第二、三部分。当前接入 **Sparkle 2.10.0**，保留 App Sandbox、用户选择文件访问与 security-scoped bookmarks。

## 已完成与当前状态

- Swift Package Manager 依赖已加入应用 target，`Package.resolved` 固定当前版本和修订。
- 应用生命周期内持有单一 `UpdaterManager`；菜单提供「检查更新…」，Settings 提供「软件更新」、版本/构建号、自动检查与自动下载开关。
- 开关直接读取和修改 Sparkle 的持久化偏好，观察 `canCheckForUpdates` / `allowsAutomaticUpdates`；检查中禁用重复检查，关闭自动检查时禁用自动下载选项。
- 默认自动检查开启，自动下载关闭；用户之后的选择优先于包内默认值。
- EdDSA 密钥已用官方工具生成，私钥保存在登录钥匙串（account：`fcp-cleaner`，service：`https://sparkle-project.org`），未导出到项目或日志。公钥写入 `Config/Updates.xcconfig`。
- `SPARKLE_FEED_URL` 已配置为 `https://Xiong-mk.github.io/fcp-cleaner/appcast.xml`；最终 App 为 0.1.0（构建 1）。
- 已准备并验证 ad-hoc 签名的双架构更新 ZIP 和 EdDSA 签名 appcast。附件由 GitHub Releases 托管，`docs/` 用于 GitHub Pages。

正式 feed 已配置，本地签名 ZIP 已验证；GitHub Release 和 Pages 线上部署待验收。实际升级安装尚未验收。发布步骤见 [GitHub 发布流程](publishing.md)，本次状态见 [发布清单](release.md)。

## 配置更新源

编辑 `FCP Cleaner/Config/Updates.xcconfig`：

```xcconfig
SPARKLE_FEED_URL = https:/$()/Xiong-mk.github.io/fcp-cleaner/appcast.xml
```

xcconfig 将 `//` 视为注释，因此 URL 必须使用上面的 `/$()/` 写法。构建产物会展开为正常的 `https://…`。也可在命令行构建时传入带引号的 `SPARKLE_FEED_URL=https://…`。未配置地址仍会明确显示未启用；正式构建应核对产物中的 `SUFeedURL` 与上面的 HTTPS 地址一致。

`Info.plist` 与 Xcode 生成的信息合并，包含：

| 键 | 值 |
| --- | --- |
| `SUFeedURL` | `$(SPARKLE_FEED_URL)` |
| `SUPublicEDKey` | `$(SPARKLE_PUBLIC_ED_KEY)` |
| `SUEnableAutomaticChecks` | Boolean `true` |
| `SUAutomaticallyUpdate` | Boolean `false` |
| `SUEnableInstallerLauncherService` | Boolean `true` |

更新源必须为 HTTPS。配置无效时不启动更新器，在设置中提示错误。应用通过出站网络权限获取更新信息，不启用 Downloader XPC 服务；Installer XPC 服务及仅限本应用 `-spks` / `-spki` 的 Mach lookup 例外支持沙盒安装。

## 密钥管理与后续签名

从仓库根目录解析依赖后，工具位于 `build/SourcePackages/artifacts/sparkle/Sparkle/bin`：

```sh
xcodebuild -resolvePackageDependencies \
  -project "FCP Cleaner/FCP Cleaner.xcodeproj" -scheme "FCP Cleaner" \
  -clonedSourcePackagesDirPath build/SourcePackages

# 查看本应用已经生成的公钥，不重新生成或导出私钥
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account fcp-cleaner -p
```

公钥必须与 `SPARKLE_PUBLIC_ED_KEY` 一致。私钥仍须由维护者在安全位置另做备份；请勿将导出的私钥放入仓库、构建输出、聊天或公开附件。其他机器上直接生成新密钥不会匹配当前应用公钥。

后续生成 appcast 或签名更新包时，必须指定相同 account：

```sh
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account fcp-cleaner /path/to/update-archives
```

EdDSA 更新包签名与 macOS 应用代码签名是两回事。当前代码签名仍为 ad-hoc 测试策略，尚未公证；完成此集成不表示已解决 Gatekeeper 或正式分发验收。

## 构建、签名与测试

`scripts/sign_adhoc.sh PATH.app` 按 Installer、Downloader、Autoupdate、Updater、framework、宿主的顺序签名。宿主权限中的 Bundle ID 根据目标 App 展开；Downloader 单独保留自身权限，其他 helper 不继承宿主沙盒权限。签名不使用 `--deep`，最终验证使用 `codesign --verify --deep --strict`。`build_dmg.sh` 已调用此流程，后续打包不会破坏 Sparkle helper 权限。

```sh
xcodebuild -project "FCP Cleaner/FCP Cleaner.xcodeproj" \
  -scheme "FCP Cleaner" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/SparkleValidation \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64' CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO DEVELOPMENT_TEAM= build

./scripts/test.sh -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

python3 scripts/prepare_release.py --check
```

测试脚本使用独立 Bundle ID，并显式清空更新源，避免配置正式地址后测试宿主自动检查更新。正常应用退出时，原有清理取消及等待收尾机制继续有效。

2026-10-18 验证：

- arm64 / x86_64 Release 构建通过；宿主、Sparkle framework、四个 helper 均为双架构。
- 全量 133 项测试通过（12 个 suite），含未配置、非 HTTPS、未展开变量和无效公钥等更新配置检查。
- 正式构建副本由内向外 ad-hoc 重签及 deep / strict 验证通过；宿主权限、动态 Bundle ID 与 helper 权限隔离检查通过。
- 独立测试副本设置页与菜单确认：当前版本 `0.1.0 (1)`、自动检查默认开、自动下载默认关、未启用提示及禁用状态正确。
- 另一个独立测试副本使用上游固定版本的测试 appcast、虚拟构建号 `999999`，手动检查成功获取 HTTPS 更新信息并显示「You’re up to date!」；没有下载或安装更新。测试 URL / 构建号仅存在忽略的 `build/` 副本，未写入工程配置。

本轮发布准备已补充：

- 133 项测试通过（12 个 suite）；正式 App 为 0.1.0（构建 1），宿主与 Sparkle helper 均为 arm64 / x86_64。
- 最终 App 代码签名验证通过；`scripts/prepare_update.py` 使用官方工具生成 ZIP 和 appcast，并独立验证 Ed25519 签名、下载 URL、字节长度与 SHA-256。
- 正式 feed 已写入构建产物；线上部署、从 Release 重新下载校验和应用内正式源检查待验收。

首发 appcast 只有构建 1，同版「已是最新版本」只能验证正式源联通与解析。完整升级验收需发布更高 `CFBundleVersion`，再从较旧构建验证发现、下载、校验、安装和重新启动。每次发版必须递增构建号；单独修改显示版本号不足以构成 Sparkle 升级。

## 官方参考

- [基础集成与 EdDSA 密钥](https://sparkle-project.org/documentation/)
- [SwiftUI 初始化](https://sparkle-project.org/documentation/programmatic-setup/)
- [设置与偏好持久化](https://sparkle-project.org/documentation/preferences-ui/)
- [沙盒、XPC 与签名顺序](https://sparkle-project.org/documentation/sandboxing/)
- [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)
