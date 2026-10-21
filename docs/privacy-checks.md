# 提交与发布隐私检查

本项目使用两个互补的检查层：`scripts/privacy_scan.py` 检查个人邮箱、本机目录、认证 URL、私钥格式、高熵 Base64 密钥候选及本地诊断文件；Gitleaks 使用默认供应商规则识别常见 Token 和 API Key。任何扫描失败、输入缺失、无法读取扩展属性或缺少 Gitleaks 都使完整检查失败。输出只包含脱敏文件标签、规则和行号，不打印命中值。

## 安装本地提交检查

从 [Gitleaks 官方发行页](https://github.com/gitleaks/gitleaks/releases) 安装并核验工具的官方 SHA-256；本次整改使用 8.30.1。然后在本仓库配置：

```sh
git config --local core.hooksPath .githooks
# 工具不在 PATH 时，替换为本机已核验工具的绝对位置。
git config --local privacy.gitleaksPath /path/to/verified-gitleaks
python3 scripts/test_privacy_scan.py
python3 scripts/privacy_scan.py index
```

Gitleaks 查找顺序为环境变量 `GITLEAKS_BIN`、显式 `--gitleaks-bin`、仓库本地配置 `privacy.gitleaksPath`、`PATH`。本机工具路径只保存在本地 Git 配置，不能写进公开脚本。新的克隆需要重新安装工具及启用 hook。完整供应商集成测试需要设置 `GITLEAKS_BIN`；未设置时，测试结果会明确显示相应测试被跳过。

`index` 只读取本次新增或修改的实际暂存 blob。暂存内容有问题时，即使工作区已经改干净仍会阻止提交；未暂存和未跟踪的本地文件不会被误当作本次提交。被强制加入暂存区的忽略文件仍会检查。未解决的合并和未经单独审查的子模块会阻止检查通过。

`.gitignore` 保护证书私钥、环境变量、诊断日志、测试结果及本地会话。宣传项目中的原始 JSON/TXT 验证记录保持本地忽略；设计、视频和其他素材保留。原有三个含路径的验证文件也在根忽略规则中精确列出。忽略规则不能移除已跟踪或已公开的文件，应同时检查：

```sh
git diff --cached --name-status
git ls-files -- fcp-cleaner-promo/evidence
git log --all --oneline -- fcp-cleaner-promo/evidence
```

## 公开数据与测试样例

`.gitleaks.toml` 继承全部默认规则，只豁免应用已发布 Sparkle 公钥的**精确值**。标准库层使用同一固定值；其他不同的公钥或私钥候选不会因此得到豁免。合法 GitHub noreply 地址、保留的 example 域名、项目现有的 `demo` / `test` 合成用户和列明的演示卷名属于测试数据。第三方 Sparkle 许可证仅在文件名与已核验完整 SHA-256 同时匹配时保留其法定署名邮箱。

appcast 的 64 字节 Ed25519 签名仅在相应 XML 字段中归类为公开签名；发布元数据须同时包含精确匹配的应用公钥。签名资源哈希仅按 `_CodeSignature/CodeResources` 的 plist 结构归类。发布检查还会用固定公钥独立验证 ZIP 的 Sparkle 签名，不能把形式正确的签名当作已验签。增加新的例外必须限制到确切数据及用途，不能关闭整个密钥检测类别。

## 发布检查清单

先运行项目的中性路径 Release 构建、测试、由内向外代码签名及 ZIP/DMG 打包流程。源码归档的允许列表逐文件扫描，包含尚未加入 Git 的候选公开文档和脚本，不读取无关本地目录。提交前与源码允许列表检查均不能代替最终安装包检查。

对最终、不再修改的产物运行：

```sh
python3 scripts/privacy_scan.py release /path/to/final-artifacts \
  --appcast /path/to/final-appcast.xml \
  --checksums /path/to/update.sha256 \
  --checksums /path/to/source.sha256
```

- 检查最终 App、更新 ZIP、源码 ZIP、DMG、元数据及其他准备公开的附件，不能只检查构建目录中的 App。
- 逐字节检查 Mach-O、Finder `.DS_Store`、UTF-16 路径以及文件、目录和符号链接的扩展属性。无论显式传入 DMG 还是传入包含 DMG 的目录，均递归以只读方式挂载检查其文件系统，检查结束后卸载；压缩的 DMG 容器原始字节不作为文本扫描，宿主文件名和扩展属性仍检查；检查保留 `.DS_Store` 的安装布局。
- ZIP 检查每个成员、开发文件、路径越界、重复成员、外部链接和经链接写入的后续成员；二进制中的可打印文本与 UTF-16 字符串也传给 Gitleaks，不能以 NUL 或扩展名跳过供应商规则。嵌套 ZIP 必须另外展开并审查；超出扫描大小限制或无法读取的内容会阻止通过。
- 提供所有 SHA-256 文件。检查其中每个附件的散列，并要求选中范围内的 ZIP/DMG 均有对应散列。提供 appcast 后检查 HTTPS、附件名称、字节长度，并独立验证其 Ed25519 签名。此步骤只读取公钥，不读取或导出签名私钥。
- 另行执行 `codesign --verify --deep --strict`、Bundle 版本与架构检查，实际检查 DMG 安装窗口及拖入 Applications 的流程。Sparkle 更新验签与 macOS 代码签名分别验证。
- 发布前确认 checksum、manifest、更新包长度、签名、appcast URL、Release 标签和版本一致。上传后重新下载全部公开附件，重复同样检查。

构建流程可用 `--builtin-only` 先运行字节隐私层，但该模式不运行 Gitleaks，不能作为完整提交或最终发布检查。`release` 不带 `--appcast` / `--checksums` 时只检查内容，不能声称已完成附件一致性与签名验收。

## 历史与记录保护

```sh
python3 scripts/privacy_scan.py history --repo /path/to/isolated-repository
```

`history` 检查所有引用可达的 blob、Commit Author/Committer 及附注 Tag 元数据。它不证明 GitHub 旧 SHA、缓存、PR 引用或已经下载的副本已消失，仍须独立公开访问复审。

审计报告、原始证据和历史备份应保存在仓库外的受限目录。公开文档和提交消息不保留真实邮箱、用户名、原始命中行或本机工具路径。扫描器的失败输出也不得被误当作附件发布。
