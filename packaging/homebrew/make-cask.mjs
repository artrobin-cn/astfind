#!/usr/bin/env node
// Renders the Homebrew cask for a built DMG.
//
//   node packaging/homebrew/make-cask.mjs [path/to/Astfind-X.Y.Z.dmg]
//
// The output goes to AstfindKit/build/astfind.rb. Publish it in a tap repository
// named homebrew-astfind under Casks/astfind.rb. The DMG must already be attached
// to a GitHub release (the URL in the cask points at releases/download/vX.Y.Z/).

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const repoURL = (process.env.ASTFIND_REPO || 'https://github.com/artrobin-cn/astfind').replace(/\/+$/, '');
const buildDir = path.join(repo, 'AstfindKit', 'build');

function latestDMG() {
  if (!fs.existsSync(buildDir)) return null;
  const candidates = fs
    .readdirSync(buildDir)
    .filter((name) => /^Astfind-\d+\.\d+\.\d+\.dmg$/.test(name))
    .map((name) => ({ name, time: fs.statSync(path.join(buildDir, name)).mtimeMs }))
    .sort((a, b) => b.time - a.time);
  return candidates.length ? path.join(buildDir, candidates[0].name) : null;
}

const dmg = path.resolve(process.argv[2] || process.env.ASTFIND_DMG || latestDMG() || '');
if (!dmg || !fs.existsSync(dmg)) {
  console.error('make-cask: DMG not found; pass a path or build one with AstfindKit/scripts/build-astfind-app.sh');
  process.exit(1);
}
const match = path.basename(dmg).match(/^Astfind-(\d+\.\d+\.\d+)\.dmg$/);
if (!match) {
  console.error(`make-cask: unexpected DMG name: ${path.basename(dmg)}`);
  process.exit(1);
}
const version = match[1];
const sha256 = crypto.createHash('sha256').update(fs.readFileSync(dmg)).digest('hex');
const url = `${repoURL}/releases/download/v${version}/Astfind-${version}.dmg`;
const template = fs.readFileSync(path.join(here, 'astfind.rb.tmpl'), 'utf8');
const cask = template
  .replaceAll('{{VERSION}}', version)
  .replaceAll('{{SHA256}}', sha256)
  .replaceAll('{{URL}}', url)
  .replaceAll('{{HOMEPAGE}}', repoURL);

const output = path.join(buildDir, 'astfind.rb');
fs.writeFileSync(output, cask);
console.log(`Wrote ${output}`);
console.log(`  version ${version}`);
console.log(`  sha256  ${sha256}`);
console.log(`  url     ${url}`);
console.log(`
Publish:
  1. Attach ${path.basename(dmg)} to the v${version} GitHub release.
  2. Copy ${output} to homebrew-astfind/Casks/astfind.rb and push.
  3. Users: brew install --cask artrobin-cn/astfind/astfind
`);
