# Astfind (npm installer)

Local-first unified search for macOS: file names, document text, text in images,
text in videos, and natural-language image/video search. This npm package installs
the menu-bar app and provides an `astfind` launcher.

```bash
npm install -g @artrobin/astfind   # Apple Silicon, Node.js 18+
astfind                  # installs if needed, then launches
```

## What it does

- Installs `Astfind.app` into `~/Applications` (no sudo, no `/Applications` writes).
- Verifies the bundled payload before installing: SHA-256, bundle identifier,
  `arm64` architecture, and the code-signature seal.
- Replaces an existing install atomically; on failure the previous app is restored.
- Never downloads anything at install time: the app is shipped inside
  `@artrobin/astfind-darwin-arm64`.
- Does not start the app from the npm cache. A stable path is required for
  macOS privacy permissions (Full Disk Access) and for updates.

## Commands

```bash
astfind                 # launch (installs/upgrades if needed)
astfind --path          # print the installed app path
astfind --version       # CLI and app versions
astfind --uninstall     # remove the app installed by npm
astfind update          # print the update command
astfind --help
```

`npm install --ignore-scripts` also works: the CLI installs on first run.

## Requirements

- macOS 14 or later, Apple Silicon (arm64). Intel Macs are not supported yet.
- Node.js 18+ (only for the installer/launcher; the app is native).
- Full Disk Access is still granted by macOS on first launch. Astfind is a menu-bar
  app; use the global hotkey (default `⌥⇧F`) to open the panel.

## Security notes

- The checksum detects corruption, not a malicious package. Package authenticity
  comes from npm provenance and maintainer 2FA.
- The app is not notarized. Installing through npm usually avoids the browser
  quarantine flag, but macOS may still ask for confirmation on first launch.
- Astfind never sends file contents anywhere unless you explicitly configure a
  remote semantic-search endpoint; the local semantic mode is loopback-only.

## Uninstall

```bash
astfind --uninstall
rm -rf "$HOME/Library/Application Support/Astfind"   # optional: index, settings, logs
```

## Other install options

- DMG: https://github.com/artrobin-cn/astfind/releases
- Homebrew cask: see `packaging/homebrew/` in the repository.
- Source: `AstfindKit/scripts/build-astfind-app.sh`.

License: Apache-2.0 (this installer) + MIT for the bundled upstream engine.
See `LICENSE` and `NOTICE`.
