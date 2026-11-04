#!/bin/bash
# Astfind .app 打包：构建 → bundle 组装 → 稳定证书签名 → DMG + 应用内更新 zip。
# 正式 Developer ID 签名/公证归 R1（需证书；本脚本产出可分发测试的内测包）。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${ASTFIND_VERSION:-0.4.1}"
WEBSITE_URL="${ASTFIND_WEBSITE_URL:-https://astfind.robyn.top/}"
UPDATE_FEED="${ASTFIND_UPDATE_FEED_URL:-}"
CONFIGURATION="${ASTFIND_CONFIGURATION:-release}"
# CFBundleVersion 必须是整数：更新器用 Int 解析它，并与清单里的 build 做“必须相等”的校验。
# 默认由语义版本派生（0.4.1 → 401）；发布流水线可用 ASTFIND_BUILD 覆盖，
# 但 latest.json 的 build 必须与这里写入的值一致，否则安装会（安全地）拒绝。
BUILD="${ASTFIND_BUILD:-$(printf '%s' "$VERSION" | awk -F. '{printf "%d", ($1+0)*10000 + ($2+0)*100 + ($3+0)}')}"
APP="build/Astfind.app"
DIST="build/dist"

echo "== [1/5] build ($CONFIGURATION) =="
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "== [2/5] assemble .app =="
rm -rf "$APP" "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
cp "$BIN_DIR/Astfind" "$APP/Contents/MacOS/Astfind"
strip -S "$APP/Contents/MacOS/Astfind" || true
# SwiftPM 资源 bundle（OilFindApp 的面板资源等）全部并入 app bundle
find "$BIN_DIR" -name "*.bundle" -maxdepth 1 -exec cp -R {} "$APP/Contents/Resources/" \; 2>/dev/null || true
# App 图标：AstfindKit/Resources/AppIcon.icns 是唯一来源（由 docs/icon-concepts/flat 生成后拷入），
# Info.plist 的 CFBundleIconFile 指向它
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 许可与第三方声明随包分发（再分发合规：副本须附带许可证、NOTICE 与上游版权声明）
UPSTREAM_LICENSE="../oil-find/LICENSE"
[ -f "$UPSTREAM_LICENSE" ] && cp "$UPSTREAM_LICENSE" "$APP/Contents/Resources/OilFind-LICENSE.txt" || echo "warn: 上游 LICENSE 未找到（$UPSTREAM_LICENSE）"
for file in LICENSE NOTICE LICENSING.md; do
  if [ -f "../$file" ]; then
    cp "../$file" "$APP/Contents/Resources/Astfind-$file.txt"
  else
    echo "warn: $file 未找到（../$file）"
  fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Astfind</string>
	<key>CFBundleExecutable</key>
	<string>Astfind</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>edu.astfind.app</string>
	<key>CFBundleName</key>
	<string>Astfind</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<!-- 向量 Provider 常为明文 http（本机 Ollama / 校园网 GPU 服务器）；ATS 默认拦截 http，
	     而外发授权由应用内 ContentEgressPolicy 显式把关（默认拒绝、仅回环放行）。
	     注意：不可同时写 NSAllowsLocalNetworking——文档规定其存在时 ArbitraryLoads 被忽略（10-21 实锤）。 -->
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- B1 自建更新渠道接线时启用（UpdateManager 读此键；缺省 = 更新入口隐藏、零网络，
	     绝不访问上游 find.oiloil.org appcast）。清单与 zip 须同源 https 主机。
	<key>AstfindUpdateFeedURL</key>
	<string>https://example.invalid/updates/latest.json</string>
	-->
	<!-- Astfind 官网；缺省 = 更新失败弹窗不显示“打开官网”按钮，绝不回退上游站点。
	<key>AstfindWebsiteURL</key>
	<string>https://example.invalid/astfind</string>
	-->
	<key>NSDesktopFolderUsageDescription</key>
	<string>Astfind 需要读取文件名与内容以建立本地搜索索引。</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Astfind 需要读取文件名与内容以建立本地搜索索引。</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Astfind 需要读取文件名与内容以建立本地搜索索引。</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>Astfind 需要读取外置卷文件名以建立离线可查的本地索引。</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Astfind 使用 AppleScript 让 QuickTime Player 跳到视频命中的时间点；拒绝后仍会普通打开视频。</string>
	<!-- 方案 A：Finder 右键 → 服务/快速操作 → 在 Astfind 中找相似。
	     不引入 Finder Sync 扩展：Services 对任意目录的图片都生效，且无需沙盒 appex。 -->
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>在 Astfind 中找相似</string>
				<key>zh_CN</key>
				<string>在 Astfind 中找相似</string>
				<key>zh-Hans</key>
				<string>在 Astfind 中找相似</string>
				<key>en</key>
				<string>Find Similar in Astfind</string>
				<key>empty</key>
				<string>在 Astfind 中找相似</string>
			</dict>
			<key>NSKeyEquivalent</key>
			<dict/>
			<key>NSRequiredContext</key>
			<dict/>
			<key>NSMessage</key>
			<string>findSimilar</string>
			<key>NSPortName</key>
			<string>Astfind</string>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.image</string>
			</array>
			<key>NSRestricted</key>
			<false/>
		</dict>
	</array>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Add :AstfindWebsiteURL string ${WEBSITE_URL}" "$APP/Contents/Info.plist"
if [ -n "$UPDATE_FEED" ]; then
  /usr/libexec/PlistBuddy -c "Add :AstfindUpdateFeedURL string ${UPDATE_FEED}" "$APP/Contents/Info.plist"
fi

# 签名策略（2026-10-22，FDA 跨版本保留）：优先环境变量 ASTFIND_SIGN_IDENTITY（未来
# Developer ID 直接切），其次本机自签证书 "Astfind Local Signing"（身份锚定在证书，
# 跨版本稳定 → TCC 完全磁盘访问等授权不丢；adhoc 的身份=单次构建哈希，每次打包都变）。
# 都没有则回退 adhoc（本机构建首次需创建证书，见 docs）。
SIGN_IDENTITY="${ASTFIND_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -q "Astfind Local Signing"; then
  SIGN_IDENTITY="Astfind Local Signing"
fi
echo "== [3/5] codesign ($([ -n "$SIGN_IDENTITY" ] && echo "identity: $SIGN_IDENTITY" || echo "adhoc 回退")) =="
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier edu.astfind.app "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

echo "== [4/5] DMG =="
cp -R "$APP" "$DIST/"
ln -s /Applications "$DIST/Applications"
hdiutil create -volname "Astfind" -srcfolder "$DIST" -ov -format UDZO "build/Astfind-${VERSION}.dmg" -quiet

echo "== [5/5] update zip =="
# 应用内更新使用 zip（清单与 zip 同源 HTTPS）。zip 根目录必须只有 Astfind.app；
# 安装器会拒绝绝对路径、..、反斜杠、符号链接以及根目录之外的条目。
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/Astfind-${VERSION}.zip"
echo "OK: $(pwd)/build/Astfind-${VERSION}.dmg"
echo "OK: $(pwd)/build/Astfind-${VERSION}.zip"
shasum -a 256 "build/Astfind-${VERSION}.dmg" "build/Astfind-${VERSION}.zip"
