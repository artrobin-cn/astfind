# A0-b：本地多模态嵌入模型评测（2026-10）

> 本文是公开版评测记录，**不含真实文件路径与来源名**；完整逐条结果含真实路径，仅保留在开发者本机。查询集、脚本、聚合数据随仓库公开，便于复现与审阅。

## 结论

在中文教学/活动素材域的三源抽样上：

- **WeMM-2B（本地，2B/2048 维）质量最好**：174 图与 612 图子集真值 rank1 均为 **11/11**、MRR **1.0**，略高于远程 WeMM-9B（10/11、0.9545）。
- **EmbeddingGemma 2（本地，0.74B/768 维）是轻量备选**：rank1 7/11、MRR 0.818；速度/体积更优，但质量与分数区分度弱一档。
- **Chinese-CLIP（188M/512 维）** 是可跑通的快速基线，但本域质量不足（rank1 5/11、MRR 0.636）。
- 本仓库**不改变产品默认**：当前仍使用远程 WeMM-9B；WeMM-2B 作为本地对比/备用方案，是否切换由后续「语义模型设置」决定。

## 一表看结论（脱敏）

| 模型 | 真值 rank1 | MRR@20 | 单图 | 单查询 | 峰值内存 | 权重 |
|---|---:|---:|---:|---:|---:|---:|
| **WeMM-2B（本地）** | **11/11（174 & 612 都是）** | **1.000** | 1.06s | 125ms | 4.76GB | 5.2GB |
| WeMM-9B（远程） | 10/11 | 0.9545 | ≈0.7s（含网络） | ≈270ms | — | 远程 |
| EmbeddingGemma 2（本地） | 7/11 | 0.818 | 0.99s | 17ms | 2.95GB | 1.4GB |
| Chinese-CLIP B/16（v1，612 样本） | 5/11 | 0.636 | 39.5ms | 31ms | 2.2GB | 已清理 |

> **脱敏与口径**：样本为自建域内 612 图（174 为同来源池的独立小抽样），**不公开素材、路径、来源名与远端地址**；分数是域内配对相对结果，不是公开榜单分数。M4 / 16GB、512px 输入、MPS float16/float32、CPU 对照；WeMM-9B 单图/单查询含网络。WeMM-2B / Gemma 2 / Chinese-CLIP 均为本地回环、**零外发**；WeMM-9B 图片/查询出网。Chinese-CLIP 的 5/11 是另一批 612 样本，仅作参考。

一句话：**WeMM-2B 是质量、内存、零外发最均衡的本地候选；WeMM-9B 质量接近但出网；Gemma 2 轻量但弱一档；Chinese-CLIP 快但本域质量不足。**

## 模型与运行条件

| 模型 | 参数 | 维度 | 权重 | 本机运行 |
|---|---:|---:|---:|---|
| [`tencent/WeMM-Embedding-2B`](https://huggingface.co/tencent/WeMM-Embedding-2B) | 2B | 2048（MRL 64–2048） | ~5.2GB | MPS float16，transformers 5.2.0 |
| [`google/embeddinggemma-2`](https://huggingface.co/google/embeddinggemma-2) | 0.74B | 768（MRL 128–768） | ~1.4GB | MPS float32，transformers 5.20.2 |
| [`tencent/WeMM-Embedding-9B`](https://huggingface.co/tencent/WeMM-Embedding-9B)（对照） | 9B | 4096（MRL 64–4096） | ~19GB | 本项目为远程部署；本机 BF16 需 ≥24GB 显存 |
| [`OFA-Sys/chinese-clip-vit-base-patch16`](https://huggingface.co/OFA-Sys/chinese-clip-vit-base-patch16)（参考） | 188M | 512 | ~753MB | CPU，transformers 4.46.3 |

硬件：Apple M4 / 16GB / macOS 26.4。模型权重放在外接 SSD，本机只保留虚拟环境与 512px 图片缓存。

> **权重与许可**：权重不随本仓库分发，均可从 Hugging Face 公开下载；WeMM 与 EmbeddingGemma 2 标注 Apache-2.0（WeMM 的 HF 元数据以 `license_name` 标注），Chinese-CLIP 以模型卡为准。官方模型卡在 MMEB-v2 / MMEB-v3 上报告了同尺寸领先的成绩（具体分数与口径见模型卡），与本文 11 条自建真值不可直接比较；9B 本机 BF16 约需 21GB 显存。下载与启动步骤见 [本地语义服务指引](local-semantic-server.md#模型选择与下载)。

## 评测方法

- **样本**：3 个在线来源（两个 NAS 目录 + 一个外接 SSD）各抽 200 张，加 12 张虚构演示图 = **612 张**；另跑 174 张子集（每源 54 张 + 12 张演示图）。每张都已有远程 WeMM-9B 向量，构成严格同图配对。
- **查询**：`AstfindKit/scripts/a0/a0-queries-zh.tsv` 的 36 条：真值 12、通用 16、负例 8。image-only 轮次中 1 条纯视频目标不计入真值聚合（11 条）。
- **图片输入**：512px 缓存图（与产品下采样口径一致）；视频帧本轮不测。
- **指标**：真值 rank / hit@1/5/10/20 / MRR；负例 top-20 泄漏随地板变化；通用 top1；hub（top-10 路径 Gini）；单图/单查询时延；峰值 RSS；是否外发。
- **可比性**：本地与远程使用同一批图、同一套查询；绝对分数会随样本/库规模变化，表中只做同装置相对比较。

## 结果

### 质量（174 图子集）

| 模型 | hit@1 | hit@5 | hit@10 | hit@20 | MRR@20 |
|---|---:|---:|---:|---:|---:|
| **WeMM-2B（本地）** | **11/11** | **11/11** | **11/11** | **11/11** | **1.000** |
| WeMM-9B（远程） | 10/11 | 11/11 | 11/11 | 11/11 | 0.9545 |
| EmbeddingGemma 2（本地） | 7/11 | 11/11 | 11/11 | 11/11 | 0.8182 |
| Chinese-CLIP B/16（参考，另一 612 样本） | 5/11 | 10/11 | 10/11 | 10/11 | 0.636 |

### 612 图复验

| 指标 | WeMM-2B（本地） | WeMM-9B（远程） |
|---|---:|---:|
| 真值 hit@1 / @5 / @10 / @20 | **11/11 / 11/11 / 11/11 / 11/11** | 10/11 / 11/11 / 11/11 / 11/11 |
| MRR@20 | **1.000** | 0.9545 |
| 单图时延 | 1057.6ms | ≈700ms（含网络） |
| 单查询文本 | 124.7ms | ≈270ms |
| 612 图模型总耗时 | 647s | — |
| 峰值 RSS | 4.76GB | — |
| 负例地板 | **0.41–0.43 零泄漏 + 11/11** | 0.50 零泄漏 + 11/11 |
| 通用 top1 同资产 | 6/16 | — |
| Hub Gini | **0.338** | 0.372 |

### 负例地板（模型专用，不能互抄）

| 模型 | 推荐地板 | 负例泄漏 | 真值保留 |
|---|---:|---:|---:|
| WeMM-2B | **0.42** | 0/8 | 11/11 |
| WeMM-9B | 0.50 | 0/8 | 11/11 |
| EmbeddingGemma 2 | 0.70 | 0/8 | 10/11 |
| Chinese-CLIP B/16 | 0.41 | 1/8 | 9/11 |

### 逐条真值（174 图，WeMM-2B / WeMM-9B）

| 查询 | WeMM-2B | WeMM-9B |
|---|---|---|
| 蓝鲸发布会 | rank 1 | rank 1 |
| 深空蓝发布会主视觉 | rank 1 | rank 1 |
| 发布会签到处 | rank 1 | rank 1 |
| 发布会主会场 | rank 1 | rank 1 |
| 发布会嘉宾席 | rank 1 | rank 1 |
| 会议幻灯片 | rank 1 | rank 1 |
| 数据图表 | rank 1 | rank 1 |
| 红色舞台海报 | **rank 1** | rank 2 |
| 舞台剧宣传图 | rank 1 | rank 1 |
| 发布会邀请函 | rank 1 | rank 1 |
| 会议白板 | rank 1 | rank 1 |
| 舞台灯光演示视频 | 视频目标，不计 | 视频目标，不计 |

### 通用查询 top1 抽查

WeMM-2B 与 WeMM-9B 同资产 6/16（174 子集 7/16）。一致项包括：讲台上的一位老师、白板上的字、幻灯片课件、获奖证书、高楼建筑、山峰风景、沙滩上的人。差异集中在开放域查询（海边日落、二维码、微信聊天截图、猫等），两者都没有 ground truth，不能单凭这组判优劣。

### 时延与资源

| 模型 | 单图（512px） | 单查询 | 峰值 RSS | 外发 |
|---|---:|---:|---:|---|
| WeMM-2B | 1.06s（MPS） | 125ms | 4.76GB | **0** |
| EmbeddingGemma 2 | 0.99s（MPS） | 17ms | 2.95GB | **0** |
| WeMM-9B | ≈0.7s（远程） | ≈270ms | — | 图片/查询出网 |
| Chinese-CLIP B/16 | 39.5ms（CPU） | 31ms | 2.2GB | **0** |

WeMM-2B 约 **0.95 图/s**，与现有远程泵（0.65–1.15 图/s）同量级；11.4 万图重嵌入约 34 小时。它不是“本地大幅提速”，价值在**质量 + 零外发 + 去掉远端依赖**。

## 复现

```bash
# 权重：见上表链接（需按各自模型卡安装；部分模型要求 trust_remote_code）
# 查询集：AstfindKit/scripts/a0/a0-queries-zh.tsv
# 脚本：AstfindKit/scripts/a0/a0b-bench-next.py、a0b-serve-next.py

# WeMM-2B（174 图子集）
TRANSFORMERS_OFFLINE=1 HF_HUB_OFFLINE=1 <weemm-venv>/bin/python \
  AstfindKit/scripts/a0/a0b-bench-next.py --backend weemm2b \
  --model-dir <WeMM-2B> --device mps --dtype float16 \
  --limit-per-source 54 --batch 3 --out a0b-next-weemm2b.json

# EmbeddingGemma 2
TRANSFORMERS_OFFLINE=1 HF_HUB_OFFLINE=1 <gemma-venv>/bin/python \
  AstfindKit/scripts/a0/a0b-bench-next.py --backend gemma2 \
  --model-dir <EmbeddingGemma-2> --device mps --dtype float32 \
  --limit-per-source 54 --batch 8 --out a0b-next-gemma2.json
```

聚合结果见 [`docs/data/a0b-benchmark-summary.json`](data/a0b-benchmark-summary.json)。逐条结果文件含真实路径，已 gitignore，不入公开仓库。

## 边界与注意事项

- 612/174 图是抽样；真值 11 条、演示语料 12 张，绝对指标会随样本与库规模变化。
- 视频帧本轮未做本地抽帧；产品视频语义通道需下一轮补。
- 未跑“语义 vs OCR/FTS 文本基线 +15pt”门禁；该门禁需等真实查询真值积累后另评。
- WeMM-2B 未装 flash-linear-attention/causal-conv1d，M4 MPS 走 torch fallback；CUDA 上会更快。本机 16GB 内存下 4.8GB 峰值可接受，但与 OCR/嵌入泵并发时需实测。
- 两个本地模型依赖不同 transformers 版本（5.2.0 vs 5.20.2），必须分开虚拟环境；不要混装。
- 模型许可证：WeMM-2B 为 Apache-2.0 条款（见模型卡 LICENSE）；EmbeddingGemma 2 为 Apache-2.0。仅评测用途，未改变产品默认 Provider。
