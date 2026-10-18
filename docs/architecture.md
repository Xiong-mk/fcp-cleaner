# 架构与数据流

FCP Cleaner 是使用 SwiftUI、AppKit 和 Foundation 的原生 macOS 应用。界面状态由主 actor 上的 `LibraryListViewModel` 管理；目录遍历、预览复验和清理执行在后台任务中完成。文件系统、书签、卷检查、废纸篓和日志均有可注入协议，测试可以在虚拟文件系统或专门创建的临时资源库上验证行为。

## 源码分工

| 目录 | 职责与入口 |
| --- | --- |
| `App` | [应用入口](<../FCP Cleaner/FCP Cleaner/App/FCP_CleanerApp.swift>)、共享状态、正常退出时等待清理并释放授权 |
| `UI` | [主界面](<../FCP Cleaner/FCP Cleaner/UI/ContentView.swift>)、[系统文件夹选择](<../FCP Cleaner/FCP Cleaner/UI/FolderPicker.swift>)、[只读预览](<../FCP Cleaner/FCP Cleaner/UI/CleanupPreviewView.swift>)、[二次确认和结果](<../FCP Cleaner/FCP Cleaner/UI/CleanupResultView.swift>) |
| `ViewModels` | [LibraryListViewModel](<../FCP Cleaner/FCP Cleaner/ViewModels/LibraryListViewModel.swift>)：调度扫描、隔离过期结果、准备确认计划、清理后重扫 |
| `Models` | [资源库模型](<../FCP Cleaner/FCP Cleaner/Models/Library.swift>)：缓存类别、候选、完整或不完整容量、结构化错误 |
| `Services` | 授权、只读扫描、安全快照、预览、卷策略、废纸篓执行及本地日志 |
| `Resources` | 应用图标等随应用分发的资源 |

## 1. 选择与持久授权

[FolderPicker](<../FCP Cleaner/FCP Cleaner/UI/FolderPicker.swift>) 调用系统 `NSOpenPanel`，用户选择存放 `.fcpbundle` 的父文件夹。取消选择不保存记录、不启动新扫描。可以添加多个父文件夹，按真实路径去重。

[书签服务](<../FCP Cleaner/FCP Cleaner/Services/FolderBookmarkServices.swift>) 创建和解析 app-scoped security-scoped bookmark。[AuthorizedFolderStore](<../FCP Cleaner/FCP Cleaner/Services/AuthorizedFolderStore.swift>) 只有在书签解析、开启访问范围和目录验证都成功后才提供可访问 URL。恢复使用 `.withoutUI` 和 `.withoutMounting`；磁盘离线或授权失效时保留展示记录，等待重试或重新授权，不用保存的普通路径代替书签访问。

授权记录在应用的 Application Support 中原子保存为 `authorized-folders-v1.json`，含 UUID、最后确认的真实路径和书签数据。读取失败会保留原文件；添加、移除只有持久化成功后才提交状态变化。

## 2. 只读后台扫描

[LibraryScanner](<../FCP Cleaner/FCP Cleaner/Services/LibraryScanner.swift>) 只检查已授权父文件夹的直接子项 `.fcpbundle`，再读取资源库下一层的事件目录。不会递归发现其他位置的资源库，也不会读取外部媒体或自定义缓存位置。

资源库包根的 `.fcpcache`、`.fcpdata` 是保留管理入口：只记录并跳过，不跟随其目标。其他层级的符号链接和 Finder 别名会成为扫描问题。扫描包含隐藏缓存项；读取失败、容量缺失、非支持类型或溢出不会伪装为 `0 B`，对应分类显示“统计不完整”。

扫描器的 `LibraryScanFileSystem` 只有读取接口。后台任务持有独立的 `FolderScanAccess`，直到任务真正返回才关闭 scope。重新扫描或取消会取消旧任务，并用任务代次标识丢弃旧结果；移除授权也不会提前释放仍在工作的后台访问范围。

## 3. 两类精确路径白名单与快照

`L` 表示已授权父文件夹的直接子资源库，`E` 表示库内一个直接子事件目录。

| 类别 | 唯一候选目录 | 含义 |
| --- | --- | --- |
| 高质量渲染 | `L/E/Render Files/High Quality Media` | 整个匹配目录，包括其中所有渲染；不判断是否仍被时间线使用 |
| 分析文件 | `L/E/Analysis Files` | 整个匹配目录；使用资源库时可能需要重新分析 |

目录名称、层级和类别必须同时匹配。原始媒体、代理/优化媒体、数据库、备份、资源库包本体与外部存储位置不在白名单中。

[CleanupSafety](<../FCP Cleaner/FCP Cleaner/Services/CleanupSafety.swift>) 在扫描时为候选捕获内存快照：授权父目录到目标的祖先链，以及目标树内所有目录和文件的元数据。身份依据包含设备号、inode、创建时间；修改检测包含纳秒级 mtime、ctime、逻辑大小和链接数。快照不读取文件内容，也不持久化为可恢复的清理计划。

扫描结束、预览、准备二次确认和实际移动前都会检查路径与原始快照。发现对象替换、成员变化、跨设备、链接、非规范路径或缺失身份信息即拒绝，不把改变后的对象刷新为新的确认基准。

## 4. 勾选、复验与二次确认

[DryRunCleaner](<../FCP Cleaner/FCP Cleaner/Services/DryRunCleaner.swift>) 只读复验候选并返回逐项通过或拒绝原因。预览默认未勾选；仅勾选的通过项可以准备清理计划。

准备计划时再次复验并检查 Final Cut Pro 已退出。二次确认展示完整目标路径和估算容量，要求用户确认已结束编辑、渲染和导出任务。确认 ID、预览 ID、所选候选或父文件夹授权发生变化时，旧计划不能继续提交。

## 5. 逐项移到废纸篓

[CleanupExecutor](<../FCP Cleaner/FCP Cleaner/Services/CleanupExecutor.swift>) 串行处理候选，同一完整目标路径只执行一次。先处理渲染目录，再处理分析目录，避免本批次先移动分析目录改变事件祖先后，让尚未执行的渲染候选失效。

每一项先写 `pending` 日志，再检查授权、卷状态、原始快照和 Final Cut Pro 运行状态；等待主 actor 检查返回后，再次检查授权、卷和完整快照，随后调用唯一的真实移动适配器 `FileManager.trashItem`。没有永久删除兜底或自动重试。

`pending` 日志失败时不移动该项；最终日志失败时界面仍显示真实操作结果，并停止后续项。取消清理只会停止后续项，当前系统调用返回后才继续收尾，已经完成的移动不会撤回。批次结束后等待全新扫描，再显示最终报告；容量来自文件系统，不从界面数值中预先扣减。

## 6. 本地记录

所有路径相对于应用沙盒内的 `Application Support/<Bundle ID>/`：

| 文件 | 内容与保留方式 |
| --- | --- |
| `authorized-folders-v1.json` | 持久授权记录，随添加、移除或书签刷新更新 |
| `scan-logs-v1/latest.json` | [最近一次已完成扫描诊断](<../FCP Cleaner/FCP Cleaner/Services/ScanDiagnosticLog.swift>)，原子覆盖；包含路径、容量、问题与快照可用性，不含书签或完整快照 |
| `cleanup-logs-v1/<attempt UUID>.json` | 每项清理状态、批次、原路径、估算容量、时间、错误及系统返回的废纸篓路径；不自动恢复执行 |

扫描日志写入失败独立提示，不改变真实扫描结果。安全限制、外接磁盘及并发修改边界见[安全说明](security.md)；构建和测试入口见[README](../README.md)。

## 7. 软件更新

`FCPCleanerApp` 使用 `@StateObject` 在应用生命周期内持有单一 `UpdaterManager` 和 `SPUStandardUpdaterController`。菜单和设置页共享此实例，通过 Combine/KVO 同步可检查状态与 Sparkle 自身持久化的偏好，不另建一套 `AppStorage`。启动前验证 HTTPS 更新源和 32 字节 Ed25519 公钥；缺少更新源时停用更新器并在设置中提示。

`Config/Updates.xcconfig` 为 Debug / Release 共用配置，`Info.plist` 与 Xcode 生成信息合并。沙盒继续通过用户选择和书签管理资源库访问；Sparkle 通过独立 Installer XPC 服务安装应用更新。正常应用退出仍走现有等待清理结束的生命周期处理。详见 [Sparkle 集成与验收](sparkle.md)。
