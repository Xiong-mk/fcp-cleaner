# 安装包隐私检查与构建

Release 继续保留 `dwarf-with-dsym`，通过 Swift / Clang 的 file 和 debug prefix maps 将源路径映射到 `/source/FCP-Cleaner`。发布脚本还将允许列表源码与锁定依赖复制到权限为 0700 的中性临时工作区，避免编译器、链接器和 Finder 记录维护者的个人目录。调试符号与构建日志单独保留在本机，不能作为 Release 附件上传；本地 LLDB 可用 `settings set target.source-map /source/FCP-Cleaner <本地工程目录>` 恢复源码定位。

构建通用架构应用：

```sh
./scripts/build_release.sh --output 'build/releases/FCP Cleaner.app'
```

脚本保留项目现有的 ad-hoc 代码签名策略，按 Sparkle 沙盒组件要求从内向外签名，然后执行 strict / deep 验证。ad-hoc 签名不等于 Developer ID 签名或 Apple 公证。

生成 ZIP 与 appcast：

```sh
python3 scripts/prepare_update.py \
  --app 'build/releases/FCP Cleaner.app' \
  --repository Xiong-mk/fcp-cleaner --tag v0.1.0 \
  --output-dir build/publish/privacy-revision --retire-build 1
```

`--retire-build` 只用于已确认需要撤下的历史条目，必须显式指定已有构建号，并且新应用的数字构建号必须更高。此次隐私修订保持显示版本 0.1.0，将构建号从 1 递增至 2，使既有用户能够发现更新。旧条目的附件 URL、长度和签名不再保留在新 feed 中。后续普通更新不要传这个选项。

ZIP 不保存扩展属性或资源叉，不应包含 AppleDouble、构建日志、dSYM 或开发输出。签名使用 Sparkle 官方工具直接读取原钥匙串项目；脚本只读取公钥并独立验证 Ed25519 签名，不导出私钥。ZIP 完成后还会重新解包，核对应用信息、架构与代码签名。

生成 DMG：

```sh
./scripts/build_dmg.sh --app 'build/releases/FCP Cleaner.app' \
  --output build/releases/FCP-Cleaner-0.1.0.dmg
```

Finder 在中性挂载路径保存 `.DS_Store`；背景、图标位置、安装说明和 Applications 链接继续保留。脚本在压缩前及只读回挂后扫描全部内容，检查 `.DS_Store` 的原始字节及扩展属性，然后验证应用代码签名。不要直接修改已签名的可执行文件。

每次上传前执行：

```sh
python3 scripts/privacy_scan.py index
python3 scripts/prepare_release.py --check
python3 scripts/privacy_scan.py release \
  build/publish/privacy-revision/updates/FCP-Cleaner-0.1.0.zip \
  build/releases/FCP-Cleaner-0.1.0.dmg
```

还需逐项核对附件 SHA-256、ZIP 字节数、appcast 下载 URL、EdDSA 签名与 bundle 公钥，以及源码 manifest 与实际发布 tag 的逐文件一致性。应先上传并匿名下载验证最终 ZIP，再部署指向它的 appcast。替换已公开的附件涉及删除旧资产；必须事先备份、验证替代包并取得维护者最终批准。

发布后从公开 URL 重新下载全部附件，重复扫描、哈希与签名验证。记录原始 Asset ID 的不可访问性；仅更改资产名称不构成内容替换。旧下载副本和 GitHub 缓存的处理状态必须另行记录，不能由新构建扫描结果推断。
