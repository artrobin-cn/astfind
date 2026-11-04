# 以图搜图 / 以图搜视频（M0.5 + M0.7）

> 状态：**M0.5 已实现（v0.3.0）；M0.7a/0.7b 已实现并验收，Finder 服务入口已上线**（2026-10-31）
> 来源：`Astfind-PRD-v2.0` §4.7 / §4.9；本文件记录实现取舍、验证数字与后续项。

## 1. 目标与边界

一个图片查询入口，跨本机 / 外置盘 / NAS 找到**相似图片与视频帧**：

- 结果按向量相似度降序；视频命中带时间码 `@mm:ss`
- 视频缩略图显示**命中时间点的真实帧**，不是视频海报
- 图片与视频帧共用一张向量表——以图搜视频是同一次查询的副产品
- 不做：人脸识别、自动删除、跨机查询；文本+图片联合查询在 M0.7b 补齐（见 §4）

## 2. 数据流

```
图片按钮 / 拖入 / ⌘V
        │
        ▼
ImageQuery.make         长边≤1024 JPEG（与入库缩略图同一预处理）+ SHA256 摘要
        │
        ▼
AstfindEngine.imageQueryOutcome
        │  缓存未命中 → .analyzing + 后台任务
        ▼
provider.embedImageData(image/jpeg) → semantic.search(queryVector:profile:limit:72)
        │
        ▼
ContentSupplementaryProvider.resolveImageHits
        │  按资产去重取最佳帧、类别过滤、路径反查、时间码标签
        ▼
SearchPresentation(sources:query:"") + supplement(preserveHitOrder:true)
        │
        ▼
面板结果行（相似度标签 + 命中帧缩略图）
```

## 3. 关键实现

| 位置 | 内容 |
|---|---|
| `AstfindKit/ImageQuery.swift` | 查询图归一化、摘要、能力/结果枚举；文件读取带 15s 看门狗 |
| `AstfindEngine.imageQueryOutcome` | 异步查询 + 60s 成功缓存 / 5s 失败缓存 + 在途去重 + 模式代次隔离 |
| `ContentSupplementaryProvider` | `ImageQuerySearchProvider`：接受图片、后台归一化、命中解析与资产去重 |
| `SearchPresentation(sources:query:)` | 无文本基座的展示；`supplement(..., preserveHitOrder:)` 固定相似度顺序 |
| `SearchField` / `PanelSurface` | 图片按钮、参考图 chip、拖入与 ⌘V 粘贴 |
| `ImageStateView` | 分析中 / 无结果 / 不可用 / 失败四态；失败态给“换一张图”或“打开设置” |
| `IconProvider.thumbnail(..., frameMs:)` | `AVAssetImageGenerator` 按毫秒抽帧，5s 超时回退文件缩略图 |
| `astfind-sources semantic image-search <路径>` | 无头实弹与标定入口 |
| `astfind-sources semantic joint-search <图片> <文字> [--alpha]` | 图文联合查询无头标定入口（输出 mode/fallback/耗时） |

### 3.1 为什么查询图必须先归一化

入库发的是长边 ≤1024 的 JPEG 缩略图；查询若发原图，等于换了一条输入通道，相似度分布会漂移。`ImageQuery` 与 `EmbeddingIndexer.downsampledJPEG` 使用同一组参数（1024 / 0.85）。

### 3.2 为什么必须异步

图片向量化本地约 1s、远程 2–3s；同步会破坏面板“输入即回”的热路径。查询先返回 `.analyzing`，完成后经 `onImageQueryComplete` 让面板重跑，第二轮走缓存。

### 3.3 缓存与模型切换

- 成功缓存 60s，失败/不可用 5s（失败也要缓存，否则失败态会被面板刷新反复重试）
- `setSemanticMode` / 关闭语义 → 清缓存并递增代次；在途的旧模型结果不得回写
- 同一张图（同摘要）在途只算一次

### 3.4 视频帧缩略图

`SupplementaryHit.thumbnailTimeMs` 携带命中毫秒；`ResultsView` 把它传给 `IconProvider`。文本语义与视频帧 OCR 命中同样享受该能力。抽帧失败回退文件缩略图，不出现空图标。

### 3.5 相似度地板

**当前不设地板**，返回前 24 条并显示相似度。现有 0.50 地板是“文本→图片”分布下标定的；图片→图片的分布未测，直接套用会误杀或漏噪。标定方法见 §5。

### 3.6 网盘性能（2026-10-30 修复）

实机：图片搜索命中 SMB 来源上的大体积视频后，`IconProvider` 的**串行**缩略图队列卡在 `fileThumbnail` 的网盘读上——整列图标不加载，打开文件明显卡顿（`sample` 实锤在 `CGImageSourceCreateWithURL`）。

修复：
- **SMB 视频不做命中帧抽帧**（时间码标签保留，显示通用视频图标）；本机/外置盘继续抽帧。
- 缩略图读取改为 **3 路并发 OperationQueue + 5s 看门狗**：一个坏文件只占一个槽位，不再堵死整列。
- 打开/在访达中显示不再在主线程 `FileManager.fileExists` + 同步 `NSWorkspace.open`；改用异步 `NSWorkspace.open(configuration:)` 与后台 reveal。

### 3.7 文件选择器的窗口层级（2026-10-30 修复）

搜索面板是 `floating` level；`NSOpenPanel.begin` 默认的普通窗口会被压在搜索面板后面。用户看到的是“面板关不掉”：`imagePicking` 阻止点空白隐藏，Esc 可能先关搜索面板而把文件选择器留在原地。

修复：
- `NSOpenPanel.level = .modalPanel`，让选择器始终浮在搜索面板之上；
- `imagePicking` 时 Esc 先 `cancel` 选择器，不再直接隐藏搜索面板；
- `SearchPanel.hide` 调用 `cancelImagePickerForHide()`，任何隐藏路径都不会留下孤立选择器；
- 双击图片按钮时用 `imagePicking` 幂等保护，避免叠出第二个选择器。

## 4. M0.7 增强（2026-10-31）

### 4.1 结果右键“找相似…”

- 图片结果（kind=4）与**带时间码的视频帧命中**（kind=5 且 `mediaStartMs != nil`）才启用；
- 图片直接读原文件，视频先用 `VideoFrameExtractor` 在命中毫秒抽帧（±0.1s、长边 1024、8s 看门狗）；
- 读取/抽帧在后台队列，面板显示进行中；失败提示“无法读取图片/视频帧”，不进入半成品查询；
- 抽帧失败**不会**回退视频海报——避免让用户误以为找的是海报；离线来源菜单置灰。

### 4.2 视频命中跳时间点

- `SupplementaryHit` 新增 `mediaStartMs`，与 `thumbnailTimeMs` 解耦：SMB 视频不做缩略图抽帧，但仍保留跳转时间码；
- 双击/回车：先判断默认播放器；只有 QuickTime Player (`com.apple.QuickTimePlayerX`) 才用 `/usr/bin/osascript` argv 传入路径和秒数，`set current time` + `play`；
- 非 QuickTime / 拒绝自动化授权 / 脚本超时或失败：回退 `NSWorkspace.open` 普通打开，并提示一次；
- 自动化授权拒绝会记录在当前会话，后续不再反复触发系统授权框；
- 右键“从头播放”普通打开、不 seek；无时码视频不显示该菜单项；
- `Info.plist` 增加 `NSAppleEventsUsageDescription`（打包脚本生成）。

### 4.3 图文联合查询

数据流：

```
图片模式 + 继续输入文字
        │ 防抖 280ms / 代次取消
        ▼
AstfindEngine.jointQueryOutcome(JointImageQuery{image,text,alpha=0.7})
        │ 图片向量 digest 缓存 10min；文本向量 profile+text 缓存 5min
        ▼
normalize(alpha * imageVec + (1-alpha) * textVec) → semantic.search
        │ 维度/非零/检索失败 → 降级
        ▼
图片召回 top 200 → 文本命中（文件名/OCR/FTS/缓存语义）重排
        │ 无文本命中 → 保留纯图结果 + footer 提示
        ▼
ContentSupplementaryProvider → detail 前缀【图+文 · 相似度 …】
```

- 图片与文本向量必须来自同一 Provider/profile；维度一致且非零才融合，默认 `alpha=0.7`；
- 查询缓存键：`image.digest + text + alpha + limit + profile.id + model generation`；成功 60s / 失败 5s；
- 图片向量按 digest 复用：同一参考图改文字不重复图片向量化；
- 面板：参考图 chip 与文字共存；清空文字回纯图，点 chip × 回纯文本；粘贴新图保留当前文字；
- 结果仍走 `semantic.search`，一次命中图片与视频帧；类别页签、按资产去重、时间码透传与纯图模式一致；
- 诊断：`jointMode = fused | filtered | imageOnly` 与 fallback 原因写入 `ASTFIND_HOME/debug.log`。

**待标定**：WeMM 文本/图片是否严格同空间、alpha=0.7 是否合适，仍需用真实素材做图文余弦与 20–30 组“图 + 文”查询复评；未达标时可只保留降级路径。

**2026-10-31 修复**：扫描期间 `store.version` 持续推进，图片/联合结果用 `isCurrent`（含版本相等）校验会被整批丢弃，面板一直停在“正在联合检索…”。现在图片/联合只校验来源集合身份（store 是否被替换），版本推进不再丢结果；扫描通知在图片/联合查询在途时也不推进代次。footer 在 analyzing 期间显示“已等待 N 秒”。

### 4.4 访达服务入口（方案 A：macOS Services）

不在本迭代的 Finder Sync 扩展范围内，采用系统 Services：

- `Info.plist` 注册 `NSServices`：`NSMessage=findSimilar`、`NSPortName=Astfind`、`NSSendFileTypes=public.image`；
- App 启动时 `NSApp.servicesProvider = FinderServiceProvider`，Finder 右键图片 → **服务/快速操作 → 在 Astfind 中找相似**；
- 服务只取第一张图片，清空旧查询文字后以该图为参考图进入纯图检索；多选暂不逐张查询；
- 不引入 `.appex`、不需要 App Sandbox 改造，也不依赖 App Group；
- 首次安装后 macOS 可能需要重新登录才能刷新服务缓存；用户可在“系统设置 → 键盘 → 键盘快捷键 → 服务”启用/分配快捷键。

## 5. 验证记录（2026-10-30 / 2026-10-31）

- 单元测试：`ImageQueryTests` 9 条——归一化边界/摘要稳定、红蓝图排序、缓存不重复向量化、无 Provider 不可用、Provider 失败分类、视频帧按资产去重 + 相似度保序 + 命中帧缩略图、搜索框图片入口/chip 布局、⌘V 粘贴进入图片模式（含面板接线）、SMB 视频保留时间码但不抽帧
- 真机引擎：真实库 **129,784 条向量**，本地图片查询 **5.2s** 返回图片与带 `@06:26` 时间码的视频帧命中（`semantic image-search`）
- NAS 坏文件：读取超时 **15.9s** 返回错误，不再无限等待
- 测试：基线 121 条改动前全绿；新增 9/9；受影响集合（Embedding / VideoSemantic / SemanticMode / Content / Provider / SupplementaryContent / ExtractionProgress / SourceSession）分组复跑全绿。整套一次跑会被运行中的 Astfind（17–43% CPU）拖慢扫描等待类用例，收口采用分组验证。

### 5.1 M0.7（2026-10-31）

- 分组测试：`swift test --filter 'ImageQueryTests|ContentTests|SupplementaryContentTests'` 40 条全绿（ImageQuery 22 / Content 14 / SupplementaryContent 4）
  - M0.7a：视频帧指定毫秒抽帧、抽帧超时分类、QuickTime seek / 非 QuickTime / 权限拒绝 / 脚本失败降级、SMB 视频保留 `mediaStartMs` 但不抽缩略图
  - M0.7b：融合数学（归一化、维度/零向量）、文字改变排序、图片/文本向量缓存、文本向量失败 filtered 降级、无命中 imageOnly、关闭语义后缓存不复用、面板输入保留图片并进入联合、清空回纯图、chip × 回纯文
  - Finder 服务：图片文件识别、非图片拒绝、面板清空旧文字并进入图片模式；`NSPerformService("在 Astfind 中找相似")` 端到端调用成功，面板显示 `finder service find-similar` / `panel show` 日志
- 已完成：负责人真机验收（右键找相似、视频帧找相似、QuickTime 跳转/拒绝授权降级、图文联合、Finder 服务入口）；现网可用。
- 待补：正式 129,784 向量库联合查询 p95、20–30 组“图 + 文”alpha 标定、大规模图文余弦基准（不阻塞 M0.7 验收）。
- 真实库冒烟（2026-10-31，`semantic image-search` / 新 `semantic joint-search`）：129,784 向量、WeMM 4096 维；纯图 5.57s（基线 5.2s 量级，无退化）；`joint-search <参考图> 室内` 5.25s、`舞台 --alpha 0.5` 5.08s，均 `mode=fused`，命中含图片与带时间码视频帧。正式 p95 与 alpha 标定仍需 20–30 组查询。

## 6. 待办

1. **真实素材标定**：准备 ≥30 张查询图与相关/不相关真值，统计 rank1 / MRR@20 / 各相似度区间的假阳性；再决定是否加地板（参考 A0-a 的方法与脚本）
2. **交互验收**：图片按钮、拖入、⌘V（截图 / Finder 图片文件）、NAS 图片、离线源命中、类别页签过滤、右键找相似、QuickTime 跳转、拒绝授权降级、图+文切换
3. **联合查询标定**：WeMM 图文余弦同空间验证、alpha 0.7 复评、真实 129,784 向量库冷/热 p95（目标冷 ≤8s、缓存 ≤2s）
4. 可选增强：多图联合、第三方播放器（VLC/IINA）seek、Finder Services
5. 文档截图：合成素材上的以图搜图面板截图（避免真实路径入库）
