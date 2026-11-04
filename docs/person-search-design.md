# 人物检索 / 找人（M0.8）架构备忘

> 状态：**2026-11-03，M0.8b 已合并 main / App 318 内部试用；阈值/大规模与对外发布未完成**。
> 产品与验收口径见 `tasks/prd-m08-person-search.md`；本文只保留架构红线、部署模式和验证接入点。

## 1. 核心结论

现有 WeMM 图片/视频向量是“场景/构图/氛围”向量，不能稳定回答“这是谁”。人物检索需要独立链路：

```text
图片 / 视频帧
  → 人脸检测 + 质量过滤 + 对齐
  → 人脸特征向量（face embedding）
  → 人脸索引
  → 单张参考人脸查询
```

人脸向量与 WeMM 向量是不同模型、不同空间，不能混检索；结果必须标注来源（`face` / `semantic`）。人脸通道失败不得影响现有搜索。

首个产品闭环是本机离线参考照片找人。服务器 Embedding 是后续可选增强，团队共享另立 PRD，人物聚类命名和多参考图属于 P1。

## 2. 架构红线：一个生效事实源

同一素材库任意时刻只能有一个 `active_face_index` 配置，查询与后台任务只能使用该配置。这里的“一个”指**生效事实源**，不是磁盘上只能存在一份 profile 数据。

- 历史 profile 可以保留、归档或显式删除，便于审计和模型迁移；
- 模式/profile 切换必须递增 generation，旧缓存、在途查询和旧任务不得写入新代次；
- 本机索引与团队服务器索引不得同时生效；
- 不得通过删除历史数据或强制全量重嵌来完成普通模式切换。

| 模式 | Embedding 位置 | 索引位置 | 当前阶段 |
|---|---|---|---|
| 单机离线 | 本机 `buffalo_sc`（CPU/CoreML 候选） | 本机 | M0.8a 验证，M0.8b 待复审 |
| 单机增强 | GDUT `buffalo_l` API | 本机 | M0.8c，未批准 |
| 团队共享 | 服务器 | 服务器 | 另立 PRD，未批准 |

服务器增强只返回向量，不保存人脸图片、向量或索引；团队服务器索引若未来实施，则 Mac 不再建立本机人脸索引。

## 3. M0.8a 技术验证边界

M0.8a 只建立独立、可删除的 benchmark 管线：

- A/B 均使用 Apple Vision、相同质量过滤、关键点对齐和 112×112 输入；
- A 使用 GDUT `buffalo_l`，B 使用本机 `buffalo_sc`；
- 候选索引使用本机临时 benchmark 存储，不修改生产数据库和真实 `ASTFIND_HOME`；
- 不接入设置页、搜索面板、生产 `index_jobs` 或 M0.6 调度器；
- 原始人脸素材、真实路径、向量和逐条结果只留在本机验收目录，仓库仅保留脱敏聚合结果。

A/B 必须只改变识别模型。若检测器、对齐或预处理也发生变化，应作为新的实验组，不得把差异归因于识别模型。

### 3.1 已落地的评测基础

`FaceBenchmarkCore` 与 `astfind-face-benchmark` 已提供无第三方依赖的清单校验和指标计算，不读取图片、不调用模型、不访问生产索引：

```bash
cd AstfindKit
swift build --target astfind-face-benchmark
.build/debug/astfind-face-benchmark validate /path/to/manifest.json
.build/debug/astfind-face-benchmark evaluate /path/to/manifest.json /path/to/results.json
```

- 清单校验拒绝查询源图/近重复图泄漏、重复 ID、未知 gallery 人物和无效 profile；
- 评测按资产去重，输出 rank1、Recall@10、Precision@10、条件分组、未知人物误返和 nearest-rank P50/P95；
- 成功输出只有聚合计数与指标，不包含素材路径、人物 ID、人脸图片或向量；
- 真实域内 A/B 仍需授权评测集，当前 CLI 不代表模型精度已验收。

### 3.2 本机 CoreML 运行时验证（2026-11-01）

已验证 `Vision 五点对齐 → 112×112 BGRA → RGB/CHW float32 → CoreML → L2 归一化`：

- 官方 `buffalo_sc.zip` SHA-256：`57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72`；识别模型为 `w600k_mbf.onnx`。
- 一次性转换工具固定在隔离 `.venv`，使用 coremltools 5.2 的显式 ONNX converter；动态 batch 固定为 1，末尾二维 `Gemm → BatchNormalization` 做数学等价融合。转换工具、模型和样例不进入 App 依赖或仓库。
- 张量使用 `(pixel-127.5)/127.5`，与 InsightFace `swapRB=True` 对齐；当前 CoreVideo 环境不支持 `32RGBA`，使用显式 `32BGRA` 和字节偏移。
- InsightFace 官方 `t1.jpg` 冒烟：Vision 检出 6 脸，主脸对齐图已人工检查；原始 ONNX 与 Swift CoreML 归一化向量余弦 **0.9999944434**，最大绝对差 **0.0005172044**，单次推理约 **4.11ms**，输出 512 维且范数约 1.0。

复现入口：

```bash
cd AstfindKit
swift build --product astfind-face-benchmark
.build/debug/astfind-face-benchmark align /path/to/input.jpg /path/to/aligned.png
.build/debug/astfind-face-benchmark embed /path/to/model.mlmodelc /path/to/aligned.png /path/to/onnx-normalized.json
```

该结果只证明本机运行时与预处理一致，不是中国人物/活动素材的 rank1、误返或视频召回证据，也不改变 `buffalo_*` 权重许可限制。

## 4. 数据与查询契约

### 4.1 资产关联

人脸表不复制定期会变化的 `source_id / relative_path / start_ms`。M0.8b 的设计基线是：

```text
face_embeddings
  face_id
  segment_id        → media_segments，ON DELETE CASCADE
  profile_id
  bbox_json
  quality
  vector_blob
  content_change_token
  indexed_at
```

资产定位和时间码通过 `media_segments/assets` 关联获得，与现有 WeMM 共用资产生命周期事实，但不写 WeMM `embeddings` 表。

### 4.2 Profile

profile 至少包含：

```text
detector + detector revision
+ alignment / crop revision
+ preprocessing revision
+ recognition model / revision
+ dimension + normalization + quantization
```

只写 `face-buffalo_sc-v1` 或 `face-buffalo_l-v1` 不足以防止未来预处理变化造成向量空间漂移。

### 4.3 查询与缓存

索引时保存素材中全部符合质量门槛的人脸；一次查询只使用一张参考人脸。多脸参考图可以切换所选人脸，但不同选择必须形成不同查询键。

缓存键至少包含：选中人脸裁剪 digest/bbox、完整 profile、active index generation、模式、阈值、筛选条件和 limit。按资产去重取最佳脸，视频取最佳帧并输出 `mediaStartMs`。

## 5. 视频边界

现有语义视频默认每 10 秒采样、每视频最多 60 帧。直接复用时只能承诺“已索引视频帧可检索”，不能承诺“找出所有实际镜头”。

M0.8a 必须分别报告：

- 已抽帧条件召回；
- 原视频实际人物的端到端镜头召回（样本不足时为诊断项）。

是否提高密度、使用镜头检测或自适应采样，由召回/成本报告决定；不得把全视频召回问题静默推给识别模型。

## 6. 模型与许可

| 模型 | 用途 | 许可与限制 |
|---|---|---|
| InsightFace `buffalo_l` | 服务器高精度候选 | 代码 MIT；权重非商用研究，仅限内部验证，发布前需授权或替换 |
| InsightFace `buffalo_sc` | 本机轻量候选 | 同上；约 13–16MB 识别模型，运行时与量化需实测 |
| SeetaFace6 | 商用备选 | 代码、权重和具体模型卡的许可需分别核实；macOS 集成需验证 |
| Apple Vision | 检测/关键点/质量 | 系统 API，不提供公开身份向量 |

模型按需下载，不默认打包。下载不等于获得商用授权；对外发布前必须完成许可审查。

用户侧下载、SHA-256、ONNX → CoreML 转换与 App 内配置步骤见 [模型下载与配置](model-setup.md#二buffalo_sc人物检索模型)。

## 7. 合规与安全

- 功能默认关闭，开启后才下载模型和建立索引；模型下载完成后，本机模式索引与查询不出网。
- 人脸是敏感个人信息；本机删除必须覆盖向量、任务、缓存和在途工作，不影响原资产和 WeMM 数据。
- 远程实验与增强必须复用外发门和显式授权，并使用 TLS 或加密隧道。
- 服务器“不留存”同时约束业务存储、multipart 临时文件、访问/调试日志和崩溃转储。
- 团队模式若未来实施，必须先定义跨机器 `library/share identity`、权限、审计、删除传播和本地挂载映射，不能复用本机 `source_id` 作为共享身份。

## 8. 与 M0.6 的并行边界

M0.6 正在修改 `AstfindEngine`、内容任务、扫描调度、设置页和 OilFindCore Scanner。M0.8a 使用独立 worktree，且不得进入这些文件或生产 migration。

M0.8b 的设置页、任务泵和引擎接线原则上等待 M0.6 集成后再开始。真实 NAS 性能实验必须串行，测试数据目录和 `.build` 必须隔离。最终验收必须在同时包含 M0.6、M0.7 和 M0.8 的集成构建上完成。

详细文件责任与升级规则见 `tasks/prd-m08-person-search.md` §8。

## 9. M0.8a 必须回答的问题

1. Vision 的小脸/侧脸检测召回是否足够；不足时是否增加 SCRFD/SeetaFace6 实验组。
2. `buffalo_l` 与 `buffalo_sc` 在授权域内素材上的 rank1、Recall@10、Precision@10 和未知人物误返。
3. 各 profile 的阈值、量化损失、查询延迟、峰值内存与存储。
4. 5k 资产建索引成本，以及更大人脸向量规模下的容量表现。
5. 现有视频采样与候选密度的召回/成本取舍。
6. 模型许可是否允许目标发布方式；不允许时，替代模型是否达到同一验收口径。
