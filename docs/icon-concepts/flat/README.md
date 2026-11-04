# Astfind · 扁平 / 线条候选

> **已定稿：C1++ · 层叠镜外（放大版）**（2026-10-23）。`c-flat-layers-bigger.icns` 已拷入
> `AstfindKit/Resources/AppIcon.icns`，v0.2.7 装机；整图占底板 75%，镜圈 R132。
> 其余各版保留作后续微调（改 `make-flat-icons.swift` 顶部常量重跑即可）。

从 A（透镜 + 文档）与 C（多源层叠 + 透镜）两个方向重画，去掉渐变、高光与内阴影，只留白色底板 + 平涂或墨线，参照飞书 / ChatGPT / Qoder 的笔法。

## 共同规范

- 1024 画布，824 圆角底板（continuous 圆角、186 半径），白色底 + 8% 墨色细边 + 柔和触地阴影
- 墨色 `#1B2432`，品牌蓝 `#2F7CF6`，浅蓝 `#BBD2FB` / `#7FB0F8`
- 镜柄起笔定在镜圈正中半径上，圆头笔帽正好覆盖圈带：镜内侧不冒头，外侧轮廓无台阶
- 所有形状按目标尺寸原生绘制（不是缩放位图），16–1024 全尺寸的 `.icns` 由 `iconutil` 合成

## 七版

| 编号 | 文件 | 构图 | 适合 |
|---|---|---|---|
| **A1 · 平涂透镜** | `a-flat-lens-doc` | 墨圈 + 蓝色页面 + 三行白字 | 最直白：一眼是“搜索文档”。两色，16px 仍读作放大镜 |
| **A2 · 墨线透镜** | `a-line-lens-doc` | 通体墨线，页面只留轮廓与字行 | 最接近 Qoder 那种纯线稿气质，安静、克制 |
| **C1 · 层叠镜外** | `c-flat-layers` | 三张来源卡扇出镜外，镜内一点白 | 保留原 C 的“多来源”叙事；整图 62%，偏小 |
| **C1+ · 整图 +10%** | `c-flat-layers-big` | 同 C1，等比放大 | 比例不动、只补足留白；整图 68% |
| **C1++ · +16% 且镜圈加大** ★ | `c-flat-layers-bigger` | 整图 75%，镜圈 R132、镜心下移 36 | **定稿版**：搜索的权重更足，32px 下镜圈更清楚 |
| **C2 · 层叠镜内·线** | `c-line-layers` | 三张卡收进镜内，纯线无填充 | 与 A2 同一笔法，线稿里层叠最干净的一版 |
| **C3 · 层叠镜内·涂** | `c-inside-stack` | 同 C2 构图，蓝色平涂 | 与 A1 同一家族，小尺寸下最稳的“多源搜索” |

C 之所以分“镜外 / 镜内”两种收法：卡片留在镜外时，镜圈压在卡片边缘上必须靠白色隔离边分开，
而隔离边一定会在卡角切出一小截残线；把层叠收进镜内就没有这个问题，代价是丢掉“卡片堆在桌上”的空间感。

## 定稿那一版的三个数

`c1-scale.png` 是决版对比（现版 / C1+ / C1++），放大过程不是等比拉一遍就完事：

| | 整图 | 占底板宽 | 镜圈 |
|---|---|---|---|
| C1 | 511 × 408 | 62% | R116 / 线宽 44 / 落点 26 |
| C1+ | 562 × 449 | 68% | 比例不变 |
| C1++ | 615 × 473 | 75% | R132 / 48 / 30，镜心下移 36 |

镜圈单独放大时必须把镜心往卡里压：原地放大会让卡片上沿横切镜内，白色落点正好卡在切线上，看着像没对准；
压进底卡后镜内是一整片蓝，落点稳稳居中。

## 重新生成

```bash
cd docs/icon-concepts/flat
swift make-flat-icons.swift                 # 全部变体：1024 PNG + icns
swift make-flat-icons.swift sheet preview-flat.png          # 全量对比图
swift make-flat-icons.swift sheet c1-scale.png c-flat-layers c-flat-layers-big c-flat-layers-bigger
```

接入应用：`AstfindKit/Resources/AppIcon.icns` 是打包时唯一的图标来源，由
`AstfindKit/scripts/build-astfind-app.sh` 拷进 `Astfind.app/Contents/Resources/`，Info.plist 里
`CFBundleIconFile=AppIcon`。换版只需把对应 `.icns` 拷成 `AstfindKit/Resources/AppIcon.icns` 再打包；
Finder / Dock 缓存用 `touch` 应用 + `lsregister -f` + `killall Finder Dock` 刷新。

## 菜单栏图标（2026-10-31）

菜单栏不直接放彩色 App 图标：白色底板在菜单栏里会变成一块“瓷砖”，而且 16–18 pt 下
配色和镜内白点都会糊掉。这里把 C1++ 的图形抽成**单色模板**——三张来源卡 + 镜圈/镜柄，
玻璃留空——由系统按菜单栏明暗自动反色，和旁边的 SF Symbols 保持同一套笔法。

- 绘制代码：`AstfindKit/Sources/AstfindPanel/MenuBarIcon.swift`，矢量 26×18（内容 23.6×16，左右 1.2 pt / 上下 1 pt 留白），
  `isTemplate = true`。菜单栏高度只有 22 pt、图形高度最多 16 pt，所以宽度靠“把卡片整体左移 36、镜圈右移 36 设计单位”横向展开，
  不拉伸任何形状；状态项长度相应设为 26 pt（`MenuBarIcon.statusItemLength`）
- 几何常量直接对应 `cStyleLoud`（C1++）；只去掉底板、配色和镜内白点
- 卡片之间用 keyline 挖空分开，镜圈/镜柄外再留一圈 halo，避免小尺寸下和卡片粘成一块
- 改 logo 构图时同步改该文件顶部的常量即可，无需重新导出位图
