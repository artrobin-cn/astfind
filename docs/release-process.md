# 开发与公开发布流程（私有仓 → 公开仓）

本文适用于 Astfind 的双仓结构：

| 仓库 | 角色 | 内容 |
|---|---|---|
| 私有开发仓 | **唯一开发主线** | 完整历史、`tasks/`、`docs/superpowers/`、内部评测、A0 结果、实验记录 |
| 公开发布仓 | **脱敏发布快照** | 源码、公开文档、README、官网、发布说明、打包脚本 |

核心原则只有一句：

> **所有开发都在私有仓完成；公开仓只在发布时由私有仓生成快照，不直接开发。**

公开仓不是 fork，也不是长期并行分支，而是私有仓某个 commit 的“可公开子集”。因此：

- 不要直接在公开仓改代码；
- 不要把公开仓的 commit 合并回私有仓；
- 不要把私有仓历史 force-push 到公开仓；
- 公开仓的 history 是一串 release snapshot commit，不是完整开发历史，这是有意的。

---

## 一、日常开发

```bash
cd ~/videcoding/astfind
git switch main
# 开发、测试、提交
git add ...
git commit -m "..."
git push github main        # 私有仓
git push origin main        # Gitee 私有镜像（可选）
```

日常不需要动公开仓。公开仓可以落后于私有仓，直到你准备发布。

---

## 二、版本发布链路

### 1. 在私有仓完成版本收口

- 更新版本号/构建号；
- 更新 `docs/releases/vX.Y.Z.md` 与 `docs/releases/vX.Y.Z.notes.json`；
- 更新 README、官网 footer/下载链接；
- 更新 npm/Homebrew 版本；
- 跑测试、构建、签名、升级演练；
- 确认公开内容没有内部数据。

### 2. 构建发布产物

```bash
cd AstfindKit
ASTFIND_VERSION=0.4.2 \
ASTFIND_BUILD=402 \
ASTFIND_UPDATE_FEED_URL=https://astfind.robyn.top/updates/latest.json \
./scripts/build-astfind-app.sh
```

产物：

```text
AstfindKit/build/Astfind-0.4.2.dmg
AstfindKit/build/Astfind-0.4.2.zip
AstfindKit/build/Astfind-0.4.2.dmg.sha256
AstfindKit/build/Astfind-0.4.2.zip.sha256
```

生成更新清单：

```bash
node AstfindKit/scripts/make-update-manifest.mjs \
  --zip AstfindKit/build/Astfind-0.4.2.zip \
  --version 0.4.2 --build 402 --published 2026-11-06 \
  --notes docs/releases/v0.4.2.notes.json \
  --output AstfindKit/build/latest.json
```

### 3. 先在私有仓提交

同步脚本只读取 **已提交** 的 HEAD（`git archive HEAD`），所以发布前必须先 commit：

```bash
git add -A
git commit -m "release: 0.4.2"
git tag -a v0.4.2 -m "Astfind 0.4.2"
```

> 私有仓的 tag 和公开仓的 tag 会指向不同的 commit（内容不同、历史不同），这是正常的；版本号相同即可。

### 4. 生成公开快照

推荐把公开仓 clone 在私有仓旁边，例如：

```bash
cd ~/videcoding
git clone https://github.com/artrobin-cn/astfind.git astfind-public
```

同步：

```bash
cd ~/videcoding/astfind
./scripts/sync-public.sh ../astfind-public
```

脚本会：

1. 检查私有仓工作树干净；
2. 用 `git archive HEAD` 生成临时快照；
3. 移除 `tasks/`、`docs/superpowers/`、内部 m06 报告；
4. `rsync --delete` 覆盖公开仓工作树（保留 `.git`）；
5. 对公开仓的已跟踪文件做敏感串扫描；
6. 在公开仓创建一个 release snapshot commit；
7. 打印 diff 统计。

确认后推送：

```bash
./scripts/sync-public.sh --push ../astfind-public
```

### 5. 在公开仓打 tag

```bash
cd ../astfind-public
git tag -a v0.4.2 -m "Astfind 0.4.2"
git push origin main
git push origin v0.4.2
```

### 6. 发布产物

1. GitHub Release：上传 DMG、zip、`latest.json`、SHA-256；
2. 官网：`./AstfindKit/scripts/deploy-site.sh 0.4.2`；
3. Homebrew：重新生成 cask，更新 tap；
4. npm：`node npm/scripts/stage.mjs` → `./npm/scripts/publish.sh`；
5. 用旧版本做一次 `UpdateExercise` 升级演练；
6. 更新 Obsidian 发布记录。

---

## 三、公开仓允许出现什么

允许：

- 源码、测试、公开文档；
- README、官网、发布说明；
- 打包/部署/npm/Homebrew 脚本；
- 公开的演示素材（DemoSSD / DemoNAS、虚构素材）。

不允许：

- `tasks/`、`docs/superpowers/`、内部 m06 报告；
- 真实教师/活动目录名、内部项目代号、真实照片名；
- 内部分数、真实参考图命中结果；
- 内部 NAS host、共享名、本机绝对路径；
- 模型权重、真实索引、`.benchmark` 结果；
- `.env`、token、API key、SSH 私钥、内部 IP。

同步脚本内置了常见敏感串扫描；新增敏感类型时，把它加入 `scripts/sync-public.sh` 的 `SENSITIVE_PATTERN`。

---

## 四、常见问题

### Q1：公开仓落后很多，可以只同步一部分文件吗？

不建议。公开仓是完整快照，用 `--delete` 保证和私有仓的公开子集一致。只同步部分文件会让公开仓和实际发布版本漂移。

### Q2：外部用户给公开仓提了 PR，怎么办？

1. 先把 PR 的改动应用到私有仓（cherry-pick / patch）；
2. 在私有仓测试；
3. 重新跑 `sync-public.sh`；
4. 公开仓会生成新的快照 commit，PR 的原始 commit 不会保留在公开历史里。

这样公开仓始终是“私有仓 HEAD 的公开子集”，不会出现两边代码不同步。

### Q3：只想改公开 README 的一个错别字，也要走私有仓吗？

是。所有改动都先改私有仓，再同步。否则下一次 `sync-public.sh --delete` 会把公开仓的直接修改覆盖掉。

### Q4：私有仓和公开仓的 tag 需要指向同一个 commit 吗？

不需要，也不可能（历史不同）。只需要版本号一致，产物由私有仓构建，公开仓提供对应版本的源码和 Release 资产。

### Q5：公开仓要不要开 Issues / PR？

可以开 Issues 收集反馈；PR 需要按 Q2 的流程先落到私有仓。若暂时不想处理 PR，可以在仓库设置里关闭 PR，或 README 写明“请先开 Issue”。

### Q6：热修复怎么做？

在私有仓修 → 测试 → 发 patch 版本（如 `0.4.3`）→ 同步公开仓 → 打 tag → 发布产物。不要直接在公开仓改。

---

## 五、发布 Checklist

- [ ] 私有仓工作树干净，测试通过；
- [ ] 版本号/build 已更新；
- [ ] 发布说明与 notes JSON 已更新；
- [ ] 构建、签名、SHA 校验通过；
- [ ] `latest.json` 的 size/sha/version/build 与 zip 一致；
- [ ] 升级演练通过（含重启确认与清理）；
- [ ] README/官网/npm/Homebrew 版本一致；
- [ ] 私有仓 commit + tag；
- [ ] `sync-public.sh --push` 完成；
- [ ] 公开仓 tag + push；
- [ ] GitHub Release 资产上传；
- [ ] 官网部署（DMG + zip + latest.json）；
- [ ] Homebrew cask 更新；
- [ ] npm 平台包 → 主包发布；
- [ ] 公开仓敏感串扫描为空；
- [ ] Obsidian 发布记录更新。
