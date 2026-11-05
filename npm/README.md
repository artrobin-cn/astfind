# npm 分发

把 `Astfind.app` 通过 npm 装到用户的 `~/Applications`，并提供 `astfind` 启动器。
面向已有 Node.js 的开发者；普通用户优先用 DMG 或 Homebrew cask。

## 目录

```
npm/
  astfind/              主包：bin/astfind、lib/install.js、scripts/postinstall.js
  darwin-arm64/         平台负载包：发布时放入 Astfind.zip + SHA256SUMS
  scripts/stage.mjs     从已构建的 Astfind.app 生成可发布包
```

- `astfind` 在主包里声明 `optionalDependencies: { "@artrobin/astfind-darwin-arm64": "<version>" }`。
- 平台包用 `os: ["darwin"]`、`cpu: ["arm64"]` 限定，npm 只会在 Apple Silicon Mac 上安装它。
- 安装时不解压到 npm/npx 缓存：必须落到稳定目录，否则 TCC（完全磁盘访问）和更新身份都会失效。

## 本地开发与验证

```bash
cd npm/astfind
npm test                      # 9 个安装器测试（临时目录，不碰真实 ~/Applications）
```

从现有构建产物打可发布包：

```bash
# 先构建 App（或复用 AstfindKit/build/Astfind.app）
AstfindKit/scripts/build-astfind-app.sh

node npm/scripts/stage.mjs
# → AstfindKit/build/npm/astfind/
# → AstfindKit/build/npm/darwin-arm64/
# → AstfindKit/build/npm/artifacts/*.tgz
```

`stage.mjs` 会先跑安装器测试，再校验 bundle ID / arm64，最后 `npm pack` 两个包，并检查测试文件没有漏进 tarball。

不安装、只验证真实签名与架构：

```bash
ASTFIND_PAYLOAD_DIR=AstfindKit/build/npm/darwin-arm64 \
  node AstfindKit/build/npm/astfind/bin/astfind.js --verify
```

## 发布

版本号的唯一来源是 App 的 `CFBundleShortVersionString`；`stage.mjs` 会把它写进两个 `package.json`。不要手工维护三处版本。

按顺序发布（平台包先发，主包的 optionalDependency 才能解析）：

```bash
npm login
npm publish AstfindKit/build/npm/artifacts/artrobin-astfind-darwin-arm64-<version>.tgz --access public
npm publish AstfindKit/build/npm/artifacts/artrobin-astfind-<version>.tgz --access public
```

也可以一条命令完成发布、版本查询和安装 smoke test：

```bash
./npm/scripts/publish.sh              # 已配置 bypass-2FA token
./npm/scripts/publish.sh 123456      # 临时传 6 位 OTP
```

- `@artrobin` 是账号自动拥有的 scope，不需要另外建 org；平台包必须带 `--access public`。
- 建议在 GitHub Actions 里用 OIDC 发布并加 `--provenance`（`id-token: write`）；本地 `npm publish --provenance` 不可用。
- 账号开 2FA。发布脚本的 postinstall 本身就是执行通道，账号被盗等于供应链失守。
- 发布前确认 `npm/astfind/package.json` 的 `repository` / `homepage` 指向公开仓库。

## 安装器行为

1. 检查 macOS + arm64；失败时给出可读原因，不写任何文件。
2. 找到平台包里的 `Astfind.zip`，用 `SHA256SUMS` 做常量时间比对。
3. 解压到目标目录内的临时目录（同一文件系统），校验：
   - 顶层 `Astfind.app` 不是符号链接、未逃出解压目录；
   - `CFBundleIdentifier == edu.astfind.app`；
   - 可执行文件包含 arm64；
   - `codesign --verify --deep --strict` 通过（校验签名完整性，不评估 Apple 信任）。
4. 原子替换 `~/Applications/Astfind.app`，失败自动恢复旧版本。
5. 在 `~/Applications/.astfind-npm.json` 写 0600 标记（版本、路径、时间）。
6. `--uninstall` 只删有标记且 bundle ID 匹配的 App；DMG 装的 App 会被拒绝删除。

`npm install --ignore-scripts` 也兼容：`astfind` 首次运行时会懒安装。

## 环境变量

| 变量 | 用途 |
|---|---|
| `ASTFIND_INSTALL_ROOT` | 覆盖安装目录（必须是绝对路径；默认 `~/Applications`） |
| `ASTFIND_PAYLOAD_DIR` | 直接指定负载目录（开发/测试；默认找 `@artrobin/astfind-darwin-arm64`） |
| `ASTFIND_SKIP_INSTALL=1` | 跳过 postinstall（CI 或只想要 CLI 时） |

## 安全边界

- 校验和只能证明“包没损坏”，不能证明“包是官方发布的”；真实性靠 npm provenance + 2FA + 受保护的账号。
- 应用未公证。npm 安装通常不带浏览器 quarantine，但这是分发渠道行为，不是安全背书。
- npm 只负责首次安装；更新仍走 App 内 B1 渠道或 `npm i -g @artrobin/astfind@latest`，不要同时启用两条自动更新路径。
- 模型权重不随 npm 包分发。

## 相关

- Homebrew cask：`packaging/homebrew/README.md`
- DMG / GitHub Releases：https://github.com/artrobin-cn/astfind/releases
