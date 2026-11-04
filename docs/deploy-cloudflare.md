# 部署到 Cloudflare Pages（astfind.robyn.top）

> 当前状态（2026-11-04）：已上线，Cloudflare 自定义域名状态 Active，HTTPS 200。

> 站点是纯静态页面，源目录 `docs/`，不需要构建命令。  
> 自定义域名是二级域名 `astfind.robyn.top`，**不需要把 robyn.top 的 NS 迁到 Cloudflare**；在阿里云 DNS 加一条 CNAME 即可。

## 一、首次部署

```bash
cd ~/videcoding/astfind
npx wrangler login
npx wrangler pages project create astfind --production-branch main --force
npx wrangler pages deploy docs --project-name astfind --branch main
```

- 第一次运行会打开浏览器授权 Cloudflare；
- Wrangler 4.157 默认把 Pages 项目创建委派给 Workers；首次创建需要 `--force` 走回 Pages（仅首次创建用，后续部署不要加）；
- 如果 `astfind` 这个 Pages 项目名被占用，换成 `astfind-robyn`，后面的 `*.pages.dev` 和 CNAME 目标一起换；
- 部署完成后会得到 `https://<hash>.astfind.pages.dev`，生产地址是 `https://astfind.pages.dev`；
- 只上传 `docs/`，不会把仓库其他内容带上。

## 二、添加自定义域名

1. 打开 Cloudflare Dashboard → **Workers & Pages** → `astfind`；
2. 进入 **Custom domains** → **Set up a domain**；
3. 填 `astfind.robyn.top`，继续；
4. Cloudflare 会显示需要配置的 CNAME 目标（通常是 `astfind.pages.dev`，以 Dashboard 显示为准）。

> 必须先在这里添加域名，再去阿里云加 CNAME。  
> 只加 CNAME、不在 Pages 里关联，会得到 522。

## 三、阿里云 DNS 加 CNAME

阿里云控制台 → 云解析 DNS → `robyn.top` → 解析设置 → 添加记录：

| 字段 | 值 |
|---|---|
| 记录类型 | `CNAME` |
| 主机记录 | `astfind` |
| 解析线路 | 默认 |
| 记录值 | `astfind.pages.dev`（以 Cloudflare 显示为准） |
| TTL | 600（或 10 分钟） |

不要动 `robyn.top` 现有的 AAAA 记录；CNAME 只作用于 `astfind` 子域。

如果 Cloudflare 额外要求 TXT 验证记录，也在阿里云按它给的主机名和值添加。

## 四、等待生效

```bash
dig +short astfind.robyn.top CNAME
# 应指向 astfind.pages.dev

curl -I https://astfind.robyn.top/
# 期望 200，证书有效
```

通常几分钟内生效；DNS 缓存最长可能几十分钟。Cloudflare 会自动签发 SSL 证书。

如果仍是 522 / SSL 错误：

- 确认 Pages → Custom domains 里域名状态是 Active；
- 确认 CNAME 目标没有写错；
- 确认阿里云没有给 `astfind` 加冲突的 A/AAAA 记录；
- 检查 `robyn.top` 是否有 CAA 限制（当前查询没有看到 CAA，可忽略）。

## 五、上线后检查

```bash
curl -I https://astfind.robyn.top/
curl -I https://astfind.robyn.top/assets/site.css
curl -I https://astfind.robyn.top/robots.txt
curl -I https://astfind.robyn.top/sitemap.xml
```

- 桌面 1440、移动 390 打开首页；
- Hero、场景 Tab、People 示意、下载按钮；
- 无 404 资源、无横向滚动；
- 如果下载按钮仍指向 GitHub Releases，确认 Release 资产已上传；
- 应用内更新检查 `https://astfind.robyn.top/updates/latest.json` 返回 200，zip 大小与 SHA-256 与清单一致。

## 六、后续更新

只更新官网：

```bash
./AstfindKit/scripts/deploy-site.sh
```

同时发布应用内更新（DMG/zip 已构建，`AstfindKit/build/latest.json` 已生成）：

```bash
./AstfindKit/scripts/deploy-site.sh 0.4.1
```

脚本会把 `AstfindKit/build/Astfind-<version>.zip` 与 `latest.json` 复制到 `docs/updates/` 再上传；该目录是本地产物，不入库。

应用内更新固定读取：

```text
https://astfind.robyn.top/updates/latest.json
```

清单里的 `url` 必须与清单同 HTTPS 主机，且 `size`、`sha256`、`version`、`build` 必须与 zip 和 App 完全一致。生成清单：

```bash
node AstfindKit/scripts/make-update-manifest.mjs \
  --zip AstfindKit/build/Astfind-0.4.1.zip \
  --version 0.4.1 --build 401 --published 2026-11-05 \
  --notes docs/releases/v0.4.1.notes.json \
  --output AstfindKit/build/latest.json
```

每次改 `docs/` 后重新部署即可。HTML 里 CSS/JS/图片已经带版本 query，静态资源可以放心缓存。

也可以在 Cloudflare Pages 里接 GitHub 仓库自动部署：

- Framework preset：`None`
- Build command：留空
- Build output directory：`docs`

## 七、可选：关闭 pages.dev 直接访问

自定义域名生效后，可在 Cloudflare 用 Bulk Redirect 把 `astfind.pages.dev` 重定向到 `https://astfind.robyn.top/`，避免两个地址同时被索引。
