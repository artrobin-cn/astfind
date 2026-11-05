#!/usr/bin/env node
// Stages publishable npm packages from a built Astfind.app.
//
//   node npm/scripts/stage.mjs [path/to/Astfind.app]
//
// Output: AstfindKit/build/npm/
//   astfind/                  main package (CLI + installer)
//   darwin-arm64/             @artrobin/astfind-darwin-arm64 payload (Astfind.zip)
//   artifacts/*.tgz           npm pack output
//
// Nothing is published. The platform package must be published before the main
// package so that optionalDependencies can resolve it.

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const sourceMain = path.join(repo, 'npm', 'astfind');
const sourcePlatform = path.join(repo, 'npm', 'darwin-arm64');
const output = path.join(repo, 'AstfindKit', 'build', 'npm');
const app = path.resolve(process.argv[2] || path.join(repo, 'AstfindKit', 'build', 'Astfind.app'));

function run(file, args, options = {}) {
  return execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options });
}

function fail(message) {
  console.error(`stage: ${message}`);
  process.exit(1);
}

function plistValue(key, plist) {
  return run('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', plist]).trim();
}

function copy(source, destination) {
  fs.cpSync(source, destination, { recursive: true, filter: (item) => !item.includes('node_modules') });
}

if (!fs.existsSync(path.join(app, 'Contents', 'Info.plist'))) {
  fail(`not an app bundle: ${app}`);
}
const infoPlist = path.join(app, 'Contents', 'Info.plist');
const version = plistValue('CFBundleShortVersionString', infoPlist);
const bundleId = plistValue('CFBundleIdentifier', infoPlist);
const executable = path.join(app, 'Contents', 'MacOS', 'Astfind');
const archs = run('/usr/bin/lipo', ['-archs', executable]).trim().split(/\s+/);
if (bundleId !== 'edu.astfind.app') fail(`unexpected bundle identifier: ${bundleId}`);
if (!archs.includes('arm64')) fail(`Astfind binary is not arm64: ${archs.join(', ')}`);

// Gate on the installer tests before producing artifacts.
console.log('== running npm installer tests ==');
run(process.execPath, ['--test', path.join(sourceMain, 'test', 'install.test.js')], { cwd: sourceMain, stdio: 'inherit' });

fs.rmSync(output, { recursive: true, force: true });
const artifactDir = path.join(output, 'artifacts');
fs.mkdirSync(artifactDir, { recursive: true });

// --- main package -----------------------------------------------------------
const mainDir = path.join(output, 'astfind');
fs.mkdirSync(mainDir, { recursive: true });
for (const name of ['bin', 'lib', 'scripts', 'README.md']) {
  copy(path.join(sourceMain, name), path.join(mainDir, name));
}
for (const name of ['LICENSE', 'NOTICE']) {
  fs.copyFileSync(path.join(repo, name), path.join(mainDir, name));
}

const mainManifest = JSON.parse(fs.readFileSync(path.join(sourceMain, 'package.json'), 'utf8'));
mainManifest.version = version;
mainManifest.optionalDependencies = { '@artrobin/astfind-darwin-arm64': version };
delete mainManifest.scripts.test; // tests are not published
fs.writeFileSync(path.join(mainDir, 'package.json'), `${JSON.stringify(mainManifest, null, 2)}\n`);

// --- platform payload -------------------------------------------------------
const platformDir = path.join(output, 'darwin-arm64');
fs.mkdirSync(platformDir, { recursive: true });
for (const name of ['README.md']) {
  copy(path.join(sourcePlatform, name), path.join(platformDir, name));
}
for (const name of ['LICENSE', 'NOTICE']) {
  fs.copyFileSync(path.join(repo, name), path.join(platformDir, name));
}

const platformManifest = JSON.parse(fs.readFileSync(path.join(sourcePlatform, 'package.json'), 'utf8'));
platformManifest.version = version;
fs.writeFileSync(path.join(platformDir, 'package.json'), `${JSON.stringify(platformManifest, null, 2)}\n`);

const zip = path.join(platformDir, 'Astfind.zip');
console.log(`== packing ${app} (${version}, ${archs.join(' ')}) ==`);
run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip]);
const hash = crypto.createHash('sha256').update(fs.readFileSync(zip)).digest('hex');
fs.writeFileSync(path.join(platformDir, 'SHA256SUMS'), `${hash}  Astfind.zip\n`);
console.log(`Astfind.zip sha256=${hash} size=${fs.statSync(zip).size}`);

// --- npm pack ---------------------------------------------------------------
function pack(directory) {
  const before = new Set(fs.readdirSync(artifactDir));
  run('npm', ['pack', '--pack-destination', artifactDir], { cwd: directory, stdio: 'inherit' });
  const added = fs.readdirSync(artifactDir).filter((name) => !before.has(name));
  if (added.length !== 1) fail(`expected one tarball from ${directory}`);
  return path.join(artifactDir, added[0]);
}

const platformTarball = pack(platformDir);
const mainTarball = pack(mainDir);

for (const tarball of [platformTarball, mainTarball]) {
  const listing = run('/usr/bin/tar', ['-tzf', tarball]);
  if (listing.includes('/test/')) fail(`tests leaked into ${path.basename(tarball)}`);
  console.log(`${path.basename(tarball)}  ${fs.statSync(tarball).size} bytes`);
}

console.log(`
Staged packages in ${artifactDir}

Publish (platform first, then the CLI), from a machine logged in to npm:

  npm publish ${platformTarball} --access public
  npm publish ${mainTarball} --access public

For provenance, run the same two commands in a supported CI provider
(GitHub Actions with id-token: write) and append --provenance.

Local smoke test without publishing:

  ASTFIND_PAYLOAD_DIR=${platformDir} node ${path.join(mainDir, 'bin', 'astfind.js')} --path
  ASTFIND_PAYLOAD_DIR=${platformDir} node ${path.join(mainDir, 'bin', 'astfind.js')} --verify
`);
