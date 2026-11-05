'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  InstallError,
  install,
  targetPath,
  uninstall,
} = require('../lib/install');

function tempDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function plist(bundleId, version) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${bundleId}</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
`;
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

// Builds the same shape as @artrobin/astfind-darwin-arm64: Astfind.zip + SHA256SUMS.
function makePayload({ bundleId = 'edu.astfind.app', version = '0.2.7', tamper = false } = {}) {
  const root = tempDir('astfind-payload-');
  const app = path.join(root, 'Astfind.app');
  fs.mkdirSync(path.join(app, 'Contents', 'MacOS'), { recursive: true });
  fs.writeFileSync(path.join(app, 'Contents', 'Info.plist'), plist(bundleId, version));
  const executable = path.join(app, 'Contents', 'MacOS', 'Astfind');
  fs.writeFileSync(executable, '#!/bin/sh\nexit 0\n');
  fs.chmodSync(executable, 0o755);
  const zip = path.join(root, 'Astfind.zip');
  execFileSync('/usr/bin/ditto', ['-c', '-k', '--keepParent', app, zip]);
  fs.writeFileSync(path.join(root, 'SHA256SUMS'), `${sha256(zip)}  Astfind.zip\n`);
  if (tamper) fs.appendFileSync(zip, 'tampered');
  return root;
}

function optionsFor(payloadDir, installRoot) {
  return {
    payloadDir,
    installRoot,
    skipCodesign: true,
    skipArchCheck: true,
    quiet: true,
  };
}

function readMarker(installRoot) {
  return JSON.parse(fs.readFileSync(path.join(installRoot, '.astfind-npm.json'), 'utf8'));
}

test('installs the payload, writes a 0600 marker, and reports the app version', (t) => {
  const payload = makePayload({ version: '0.2.7' });
  const installRoot = tempDir('astfind-applications-');
  t.after(() => fs.rmSync(payload, { recursive: true, force: true }));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  const result = install(optionsFor(payload, installRoot));
  assert.equal(result.version, '0.2.7');
  assert.equal(result.replaced, false);
  assert.ok(fs.existsSync(path.join(targetPath(installRoot), 'Contents', 'Info.plist')));

  const marker = readMarker(installRoot);
  assert.equal(marker.path, targetPath(installRoot));
  assert.equal(marker.appVersion, '0.2.7');
  assert.equal(fs.statSync(path.join(installRoot, '.astfind-npm.json')).mode & 0o777, 0o600);
});

test('rejects a tampered payload and leaves the target untouched', (t) => {
  const payload = makePayload({ tamper: true });
  const installRoot = tempDir('astfind-applications-');
  t.after(() => fs.rmSync(payload, { recursive: true, force: true }));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  assert.throws(() => install(optionsFor(payload, installRoot)), /checksum mismatch/);
  assert.equal(fs.existsSync(targetPath(installRoot)), false);
});

test('rejects a payload for a different bundle identifier', (t) => {
  const payload = makePayload({ bundleId: 'com.example.not-astfind' });
  const installRoot = tempDir('astfind-applications-');
  t.after(() => fs.rmSync(payload, { recursive: true, force: true }));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  assert.throws(() => install(optionsFor(payload, installRoot)), /unexpected bundle identifier/);
});

test('upgrades an existing install and removes the backup', (t) => {
  const installRoot = tempDir('astfind-applications-');
  const first = makePayload({ version: '0.2.7' });
  const second = makePayload({ version: '0.2.8' });
  t.after(() => fs.rmSync(first, { recursive: true, force: true }));
  t.after(() => fs.rmSync(second, { recursive: true, force: true }));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  install(optionsFor(first, installRoot));
  const result = install(optionsFor(second, installRoot));
  assert.equal(result.replaced, true);
  assert.equal(result.version, '0.2.8');
  assert.equal(readMarker(installRoot).appVersion, '0.2.8');
  assert.deepEqual(
    fs.readdirSync(installRoot).filter((name) => name.includes('.old-')),
    [],
  );
});

test('uninstall removes an app installed by npm', (t) => {
  const payload = makePayload();
  const installRoot = tempDir('astfind-applications-');
  t.after(() => fs.rmSync(payload, { recursive: true, force: true }));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  install(optionsFor(payload, installRoot));
  assert.equal(uninstall({ installRoot }).removed, true);
  assert.equal(fs.existsSync(targetPath(installRoot)), false);
  assert.equal(fs.existsSync(path.join(installRoot, '.astfind-npm.json')), false);
});

test('uninstall refuses an app that npm did not install', (t) => {
  const installRoot = tempDir('astfind-applications-');
  const app = targetPath(installRoot);
  fs.mkdirSync(path.join(app, 'Contents'), { recursive: true });
  fs.writeFileSync(path.join(app, 'Contents', 'Info.plist'), plist('edu.astfind.app', '0.2.7'));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  assert.throws(() => uninstall({ installRoot }), /not installed by npm/);
  assert.ok(fs.existsSync(app));
});

test('refuses unsupported platforms before touching the filesystem', (t) => {
  const payload = makePayload();
  const installRoot = tempDir('astfind-applications-');
  t.after(() => fs.rmSync(payload, { recursive: true, force: true }));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  assert.throws(
    () => install({ ...optionsFor(payload, installRoot), platform: 'linux' }),
    /macOS/,
  );
  assert.throws(
    () => install({ ...optionsFor(payload, installRoot), arch: 'x64' }),
    /Apple Silicon/,
  );
  assert.equal(fs.existsSync(targetPath(installRoot)), false);
});

test('surfaces InstallError for expected failures', (t) => {
  const payload = makePayload({ tamper: true });
  const installRoot = tempDir('astfind-applications-');
  t.after(() => fs.rmSync(payload, { recursive: true, force: true }));
  t.after(() => fs.rmSync(installRoot, { recursive: true, force: true }));

  assert.throws(() => install(optionsFor(payload, installRoot)), InstallError);
});

test('dry run verifies the payload without creating the install root', (t) => {
  const payload = makePayload({ version: '0.2.7' });
  const installRoot = path.join(tempDir('astfind-parent-'), 'Applications');
  t.after(() => fs.rmSync(payload, { recursive: true, force: true }));
  t.after(() => fs.rmSync(path.dirname(installRoot), { recursive: true, force: true }));

  const result = install({ ...optionsFor(payload, installRoot), dryRun: true });
  assert.equal(result.dryRun, true);
  assert.equal(result.version, '0.2.7');
  assert.equal(fs.existsSync(installRoot), false);
});
