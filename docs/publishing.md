# 使用 GitHub Pages + GitHub Releases 发布更新

本项目将完整应用 ZIP 托管于 [GitHub Releases](https://github.com/Xiong-mk/fcp-cleaner/releases)，将 `docs/appcast.xml` 托管于 [GitHub Pages](https://Xiong-mk.github.io/fcp-cleaner/appcast.xml)。Pages 来源为 **main 分支的 `/docs`**，不需要网站构建工具。

首版 **v0.1.0 / App 0.1.0 / 构建 1** 已发布，标为 ad-hoc 预发布测试版。本次状态见 [发布清单](release.md)；以下流程也供未来版本重复使用。命令均从仓库根目录运行；下例保留首发版本，后续请换成新版本，不要重复创建已发布的标签或附件。

此次 0.1.0（构建 2）隐私修订是经专项备份、验证和最终批准后更新现有标签及附件的例外；按 [隐私构建与检查](release-privacy.md) 操作，不要把下面首发示例直接用于覆盖已发布资产。普通后续发版仍使用新的版本标签。

托管已经准备好，不需要另购服务器或域名。之后每次发布只需：递增版本与构建号 → 构建和签名 → 生成更新包与 appcast → 上传并验证 Release 附件 → 最后将 appcast 推送到 Pages。

## 1. 准备最终应用

先完成 Release 构建与最终签名，保留 Sparkle helper 的独立权限。当前发行策略为 ad-hoc、未公证；构建与签名方法见 [Sparkle 配置](sparkle.md) 和 [DMG 制作](dmg.md)。

最终应用应包含正确的版本、构建号、Bundle ID、许可资料、Sparkle 公钥和更新源。工程内 `FCP Cleaner/Config/Updates.xcconfig` 使用：

```xcconfig
SPARKLE_FEED_URL = https:/$()/Xiong-mk.github.io/fcp-cleaner/appcast.xml
```

`/$()/` 用来避免 xcconfig 将 `//` 解释为注释；应用产物中必须展开为正常 HTTPS 地址。维护者钥匙串中的 Sparkle 私钥使用 account `fcp-cleaner`，不得导出到仓库或附件。

## 2. 生成并验证更新 ZIP 与 appcast

将 `--app` 指向最终签名的应用，例如：

```sh
python3 scripts/prepare_update.py \
  --app "build/Release/Build/Products/Release/FCP Cleaner.app" \
  --repository Xiong-mk/fcp-cleaner \
  --tag v0.1.0
```

脚本使用 Sparkle 官方 `generate_appcast --account fcp-cleaner` 和 macOS `ditto`，检查应用版本、tag、正式源、公钥与钥匙串匹配、代码签名，并验证生成包的 Ed25519 签名、URL、字节长度和 SHA-256。私钥留在钥匙串。默认输出：

```text
build/publish/v0.1.0/
  updates/FCP-Cleaner-0.1.0.zip
  updates/appcast.xml
  FCP-Cleaner-0.1.0.json
  FCP-Cleaner-0.1.0.sha256
docs/appcast.xml
```

脚本在全部验证通过后更新 `docs/appcast.xml`；此时文件仍是**本地待部署**。已有输出不会覆盖；需要重新准备时使用新的 `--output-dir`。已有 appcast 的历史条目必须保留，同一构建号不能再次添加。后续版本先递增显示版本与 `CFBundleVersion`，同步 tag 和源码归档脚本版本，再运行流程。

生成后的 ZIP 与 appcast 签名绑定，上传前后都不得重新压缩、替换或改动 ZIP。源码 ZIP 不放入 `updates/`，避免被 Sparkle 当作更新包。

## 3. 审查并生成对应源码

先补齐本版文档、发布说明和公开静态文件，再运行：

```sh
python3 scripts/prepare_release.py --check
python3 scripts/prepare_release.py \
  --output build/publish/v0.1.0/FCP-Cleaner-v0.1.0-source.zip
git status --short --untracked-files=all
git diff --check
```

生成源码 ZIP、同名 `.sha256` 与 `.manifest.json`。脚本按允许列表收集源码、测试、资源、依赖锁、构建脚本和许可资料，拒绝私钥、真实用户路径及清单外已跟踪文件。仍需人工审查待提交文件与 diff，勿强制添加忽略目录。源码包必须与最终标签内容匹配；修改源码或文档后重新生成。

## 4. 先推送版本标签并上传 Release 附件

将全部最终公开内容（含本版 appcast）在本地提交，创建版本标签，先只推送这个标签，在该标签创建 Release，采用对应版本的发布说明（首版见 [v0.1.0 发布说明](releases/v0.1.0.md)）。当前签名策略对应的首版标记为 **Pre-release**。上传：

- `FCP-Cleaner-0.1.0.zip`：Sparkle 的完整应用更新包。
- `FCP-Cleaner-v0.1.0-source.zip` 及其 `.sha256`、`.manifest.json`：完整对应源码及审查信息。
- `FCP-Cleaner-0.1.0.sha256` 和 `FCP-Cleaner-0.1.0.json`：更新包校验与版本元数据。

DMG 是可选的手动安装附件，不能替代 appcast 指向的 ZIP。不要上传钥匙串导出、真实资源库或整个构建目录。

**此时先不要推送 `main`，也不要使用 `git push --all`。** Pages 已自动监听 `main` 的 `/docs`；提前推送会让 appcast 宣布一个附件尚不可下载的更新。只推送版本标签可以先公开同一提交的源码和 Release，待附件验证后再部署更新源。

发布后从以下地址实际下载附件，核对本地元数据中的 SHA-256、长度、版本和签名：

```text
https://github.com/Xiong-mk/fcp-cleaner/releases/download/v0.1.0/FCP-Cleaner-0.1.0.zip
```

若 ZIP 有任何变化，应重新生成 appcast 和校验文件；已经提供给用户的构建应使用新的构建号发布修订。不要悄悄替换已发布的签名更新包。

## 5. 启用 Pages 并部署 appcast

确认 Release 附件下载与校验成功后，再将上述同一提交推送到 `main`，部署最终 `docs/appcast.xml` 及静态页面。这样 Release 标签、源码包和更新清单对应同一版内容。仓库 **Settings → Pages** 已配置如下，后续无需每次重新设置：

1. Source：`Deploy from a branch`。
2. Branch：`main`。
3. Folder：`/docs`，保存并等待部署完成。

`docs/.nojekyll` 让这些文件直接静态发布。检查以下地址返回 HTTPS 200；XML 中 enclosure 的地址、版本、长度与 EdDSA 签名必须和最终 ZIP 一致：

- [项目主页](https://Xiong-mk.github.io/fcp-cleaner/)
- [正式 appcast](https://Xiong-mk.github.io/fcp-cleaner/appcast.xml)

不要在 Release 附件尚不可下载时让 appcast 宣布该更新。

## 6. 验收正式更新源

在最终应用里执行「检查更新…」。首发只有 0.1.0（1）时应显示已经是最新版本，这可以确认正式源可获取并解析。记录结果后更新 [发布清单](release.md)。

完整升级验收必须另发更高 `CFBundleVersion`，从实际较旧构建完成发现、下载、签名校验、安装、重启和版本确认。同版检查、浏览器能打开 XML、脚本签名验证各自只覆盖一部分；它们不等于实际升级安装已通过。
