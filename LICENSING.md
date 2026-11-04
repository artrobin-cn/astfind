# 许可证 / Licensing

本仓库按**代码来源**采用两种许可证。根目录 [`LICENSE`](LICENSE) 为 Apache-2.0；上游 Oil Find 的 MIT 许可保留在 [`oil-find/LICENSE`](oil-find/LICENSE)。

| 路径 | 许可证 | 说明 |
|---|---|---|
| `oil-find/**` | **MIT** | 上游 Oil Find 的最小源码子集（`OilFindCore` + `COilFind`），版权归 Lin Zhihuang；见 `oil-find/LICENSE` |
| `AstfindKit/Sources/AstfindPanel/**` | **MIT** | Oil Find 面板的 fork；上游部分版权归 Lin Zhihuang，Astfind 的修改沿用 MIT |
| `AstfindKit/Sources/AstfindKit/{AstfindEngine,SQLite,SourceRegistry,ScanScheduler,SourceSession,VolumeIdentity}.swift` | **MIT** | Astfind 的核心搜索/索引引擎：文件名索引、扫描调度、来源登记、卷身份 |
| 其余 `AstfindKit/Sources/AstfindKit/**`（内容/OCR、图片与视频语义、Provider、SMB 身份、迁移、AppExtension） | **Apache-2.0** | Astfind 自研的内容与图片/视频检索模块 |
| `AstfindKit/Sources/astfind-sources/**`、`astfind-registry-demo/**`、`AstfindKit/Tests/**`、`AstfindKit/scripts/**` | **Apache-2.0** | CLI、测试与脚本 |
| `npm/**`、`packaging/**` | **Apache-2.0** | npm 安装器/启动器与 Homebrew cask 模板（分发的 App 仍按上述路径拆分许可） |
| `docs/**`、`README.md`、`AstfindPoC/**` | **Apache-2.0** | 文档、评测与 Phase 0 装置 |

- 根 `LICENSE`、`NOTICE` 与 `oil-find/LICENSE` 必须随源码或二进制一起分发。
- 模型权重不随本仓库分发。WeMM-Embedding-2B/9B 与 EmbeddingGemma 2 的模型卡标注 Apache-2.0；Chinese-CLIP 以模型卡为准。下载与使用权重时请遵守各自许可。
- M0.8a 人脸 benchmark 使用的 InsightFace `buffalo_l` / `buffalo_sc`：代码 MIT，但权重和训练数据仅限非商用研究；权重不进入仓库或发布包。对外发布前必须取得商业授权或更换模型。详见 `docs/superpowers/reports/2026-11-01-m08a-license-review.md`。
- 演示截图使用虚构素材，路径与来源名已脱敏。
- Apache-2.0 允许商业使用与再分发；本仓库的拆分用于区分来源、保留上游署名，并不限制上游或第三方的商业产品。
- 这不是法律意见；公开分发前如有商业或合规疑问，请咨询律师。
