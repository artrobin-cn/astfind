# Homebrew cask

`make-cask.mjs` renders `astfind.rb` from a built DMG:

```bash
AstfindKit/scripts/build-astfind-app.sh
node packaging/homebrew/make-cask.mjs
# → AstfindKit/build/astfind.rb
```

The generated cask points at:

```
https://github.com/artrobin-cn/astfind/releases/download/v<version>/Astfind-<version>.dmg
```

## Publishing the tap

1. Create a repository named `homebrew-astfind` under the same account.
2. Put the generated file at `Casks/astfind.rb`.
3. Push, then test with:

```bash
brew audit --cask --new artrobin-cn/astfind/astfind
brew install --cask artrobin-cn/astfind/astfind
```

Users can then install with:

```bash
brew install --cask artrobin-cn/astfind/astfind
```

## Notes

- Regenerate the cask for every version: both `version` and `sha256` change.
- The DMG must exist as a GitHub release asset before the tap works.
- Homebrew downloads usually do not carry the browser quarantine flag, so the
  first launch is typically smoother than a manually downloaded DMG. The app is
  still not notarized; Gatekeeper policy can change between macOS releases.
- The app is Apple Silicon only. Add a `depends_on arch: :arm64` line if you want
  Homebrew to refuse Intel Macs explicitly.
