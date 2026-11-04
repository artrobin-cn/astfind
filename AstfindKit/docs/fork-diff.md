# AstfindPanel 与上游 OilFindApp 的差异清单

> 基线：`oil-oil/oil-find` @ `e63c715`（ADR-121 批准的 App 层 fork，2026-10-19）。
> 同步上游时以本文件为核对清单：先复制上游新版，再重放以下差异。

## 结构性差异
1. **模块名**：`OilFindApp` → `AstfindPanel`（SwiftPM 禁止包图内同名 target；调用方 `import AstfindPanel`）。

## 品牌替换（MIT 合规：上游 LICENSE 原样保留于本仓库与发行物致谢）
2. 全部用户可见文案 `"Oil Find"` → `"Astfind"`（L10n 中英表 16 处、欢迎窗、菜单、更新提示等）。
3. **数据路径隔离**：`~/Library/Application Support/Oil Find/` → `.../Astfind/`（主盘索引、外置卷目录、ai-topics、license、CLI 缓存）——与用户已装的官方 Oil Find 共存时避免双进程写同一索引文件。副作用：升级到此版后主盘索引首启重建一次（多源快照不受影响）。
4. `import OilFindApp` → `import AstfindPanel`（仅本包内调用方，vendored 内部无自引用）。

## 功能差异
5. **上游更新器禁用且更新源切断**（`AppDelegate.swift` / `UpdateManager.swift`，2026-10-22 加强）：`UpdateManager.shared.start()` 与 onChange 接线注释掉；`UpdateManager` 新增 `AstfindUpdateFeedURL`（Info.plist）通道门——未配置时 `check()`/`install()` 直接返回、**零网络请求**，设置页"自动检查更新"开关与"检查更新…"按钮换成「自动更新尚未开通」提示，菜单"检查更新…"隐藏（`UpdateChannelTests` 钉住）。**绝不回退上游 `find.oiloil.org` appcast**——上游 Oil Find 1.7.1 曾被当成 Astfind 更新推给用户（0.2.0 实弹翻车）。自建渠道（B1）接线时在打包 Info.plist 写入该键即恢复全套更新 UI。
6. **呼出快捷键默认 ⌥⇧F**（`HotKey.swift` `Shortcut.astfindModifiers` + `AstfindAppExtension.seedDefaultHotkey()`）：上游默认 ⇧⌘F 与用户已装的官方 Oil Find 双弹面板（R1a 修复）。首启写应用域（`register(defaults:)` 注册域实测不被热键初始化链路读到，曾致装完唤不出面板）；面板内 fallback（`AppDelegate`）、设置页「重置」、欢迎窗/设置窗快照展示统一取 `astfindModifiers`，无任何路径退回上游默认。
7. **外置盘拔出后仍可检索（C 场景）**（`ExternalDriveCatalog.swift`，2026-10-19）：
   - 上游 `searchSources()` 只给 `session?.online == true` 的盘发搜索源——拔盘后本地索引文件仍在（`external-drives/<UUID>.oilfind`）但整源从搜索消失。
   - 本 fork：`reconcile()` 在线状态翻转时重建会话；卷不在但本地有快照时挂**离线会话**（`IndexManager.startOffline()` 从 dbURL 只读加载，不扫描）。`searchSources()` 对离线会话发 `SearchSource(isOnline: false)`——面板自动标「离线」、灰显、禁止打开（上游面板本就内建该渲染，只是 catalog 从不发离线源）。
   - `ExternalDriveIndex` 协议新增 `startOffline()`（`IndexManager` 天然满足）。
   - 验证：`ExternalDriveCatalogOfflineTests` 3 用例（拔盘重启可命中/插拔转换不断档/未建索引不出源）+ 真机实弹（真实外置盘 5.2MB 索引，diskutil 卸载走 DA 审批路径，卸载前后均 21 条命中「舞台演示」，离线源 `isOnline=false`）。
8. **离线术语统一**（`L10n.swift`）：`source.offline`「未连接」→「离线」；`source.unavailable`（离线结果点击提示）→「「%@」已离线，连接后才能打开。」；设置页驱动器行 `driveOffline`（"未连接 · 上次连接 %@"）保留——描述物理连接状态，语义不同。
9. **设置页末尾致谢区块**（`SettingsWindow.swift`，2026-10-19）：MIT 致谢行按开发者要求从「统一搜索来源」区块内挪到整个设置窗 Form 的最后一个 Section（居中、footnote、secondary）。
10. 保留未动：`com.oiloil.find.*` 内部通知名/队列标签、`com.oiloil.find` URL scheme（内部机制，不影响用户；与官方 App 共享唤起通知为已知低频瑕疵）。

## M0.6 后台索引 I/O 优先级（2026-10-31）
11. **Scanner 安全点 Pacer hook**（`OilFindCore/Scanner.swift`、`OilFindCore/ScanPacing.swift`、`OilFindCore/IndexManager.swift`）：
    - `ScanPacing` 协议 + 固定参数 `ScanPacer`；在目录 `open` 前和每次 `sift_read_dir` 前取许可，系统调用结束后的所有路径释放。
    - 仅 SMB 来源注入；本地/外置来源 `scanPacerFactory` 返回 nil，零等待直通。
    - 交互时同一 Scanner 最多 1 个扫描 I/O 在飞；批次间隔初始 25ms，Pacer 主动等待上限 250ms。
    - 不调用 `IndexManager.stop` / `Scanner.cancel` / `SourceSession.cancelActiveScan` 实现降速；取消仍走原生命周期。
    - 诊断：`ScanPacerMetrics` 记录 `ioDuration` / `maxIODuration` / `slow500` / `slow1s` / `slow2s`；`IndexManager` 以 `ScanPacerPass` 记录每个 Scanner/pass，并把 `lastScanPacerMetrics` 聚合到整个测量会话。日志里的 `artificialMs` / `permitWaitMs` / `ioMs` 是聚合值，不再只代表最后一个 Pacer。
    - 验收标定可用 `ASTFIND_M06_BATCH_MS` / `ASTFIND_M06_MAX_WAIT_MS` / `ASTFIND_M06_MAX_IN_FLIGHT` / `ASTFIND_M06_INTERVAL_SCOPE` / `ASTFIND_M06_READ_BUFFER_KB` 临时覆盖；默认仍为 25ms / 250ms / 1 / perPermit / 256KB。
    - 上游同步注意：保留安全点位置与 `beginIO/endIO` 成对释放；不要在校验、覆盖统计或目录 hook 锁内等待。
12. **Astfind 调度接线**（`AstfindKit/ForegroundActivityCoordinator.swift`、`AstfindKit/ScanPacingController.swift`）：
    - `setInteractive(visible:typing:)` 内部迁移到协调器，签名与 M0.7 调用点不变。
    - 分块首扫 `ScanScheduler.scanChunk` 与权威重扫 `SourceSession.scanOnline` 都通过 `IndexManager.scanPacerFactory` 为每个 Scanner 安装独立 Pacer。
    - `SourceSession.scanOnline` 在 `start()` 已经实际全扫时跳过冗余 `rescan()`，避免同一 run 的第二次完整遍历；保留“快照加载后再权威重扫”的路径。
    - QuickLook 可见性通过 `AstfindPanel/QuickLook.swift` 的 M0.6 钩子转发到引擎。
    - 用户开关 `astfindSMBInteractionPriority` 默认开启；关闭后唤醒等待者并在下一个安全点恢复全速。
13. **同来源内容批次去重**（`AstfindKit/ContentBatchGate.swift`）：只门控实际 `runPending` 执行批次；`enqueuePending` 与 `limit=0` 不受影响，后到触发快速返回。
14. **验收材料**：`AstfindKit/docs/m06-acceptance-runbook.md`、`AstfindKit/scripts/m06-nas-baseline.py`；真实 NAS 原始样本不入库。

## 已知非用户可见残留
- `OilFindCore`（path 依赖，保持原样）中的 stderr 诊断前缀 "Oil Find: ..."（3 处）——日志输出，非 UI。
