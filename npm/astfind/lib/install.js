'use strict';

// Installs the Astfind.app payload shipped inside @astfind/darwin-arm64.
//
// Design constraints:
// - No network at install time: the payload is already in node_modules.
// - No sudo: the app always goes to ~/Applications (or ASTFIND_INSTALL_ROOT).
// - Stable location: never run from the npm/npx cache; TCC grants and updates need a fixed path.
// - Verify before replacing anything: SHA-256 of the zip, bundle identifier, architecture,
//   and the code signature seal.
// - Never follow symlinks and never delete an app this package did not install.

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const BUNDLE_ID = 'edu.astfind.app';
const APP_NAME = 'Astfind.app';
const PAYLOAD_FILE = 'Astfind.zip';
const SUMS_FILE = 'SHA256SUMS';
const MARKER_FILE = '.astfind-npm.json';
const MARKER_SCHEMA = 1;

class InstallError extends Error {}

function fail(message) {
  throw new InstallError(message);
}

function run(file, args) {
  try {
    return execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) {
    const detail = String(error.stderr || error.message).trim();
    return fail(`${path.basename(file)} failed: ${detail}`);
  }
}

function defaultInstallRoot() {
  return path.join(os.homedir(), 'Applications');
}

function resolveInstallRoot(options = {}) {
  const configured = options.installRoot || process.env.ASTFIND_INSTALL_ROOT || defaultInstallRoot();
  if (!path.isAbsolute(configured)) {
    fail(`install root must be an absolute path: ${configured}`);
  }
  return path.resolve(configured);
}

function targetPath(installRoot) {
  return path.join(installRoot, APP_NAME);
}

function markerPath(installRoot) {
  return path.join(installRoot, MARKER_FILE);
}

function platformProblem(options = {}) {
  const platform = options.platform || process.platform;
  const arch = options.arch || process.arch;
  if (platform !== 'darwin') {
    return 'Astfind is a macOS app; this package only installs on macOS.';
  }
  if (arch !== 'arm64') {
    return 'Astfind currently ships an Apple Silicon (arm64) build only; Intel Macs are not supported yet.';
  }
  return null;
}

function resolvePayloadDir(options = {}) {
  const candidates = [];
  if (options.payloadDir) {
    candidates.push(options.payloadDir);
  } else if (process.env.ASTFIND_PAYLOAD_DIR) {
    candidates.push(process.env.ASTFIND_PAYLOAD_DIR);
  } else {
    // Development checkout: npm/darwin-arm64 next to npm/astfind.
    candidates.push(path.join(__dirname, '..', '..', 'darwin-arm64'));
    try {
      const manifest = require.resolve('@astfind/darwin-arm64/package.json', {
        paths: [path.join(__dirname, '..')],
      });
      candidates.push(path.dirname(manifest));
    } catch {
      // Optional dependency missing (wrong platform or --ignore-scripts during install).
    }
  }
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(path.join(candidate, PAYLOAD_FILE))) {
      return path.resolve(candidate);
    }
  }
  return fail(
    'Astfind payload not found. Reinstall the package (npm i -g astfind) or install the DMG from the releases page.',
  );
}

function sha256File(file) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function expectedPayloadHash(payloadDir) {
  const sumsPath = path.join(payloadDir, SUMS_FILE);
  if (!fs.existsSync(sumsPath)) {
    return fail(`missing ${SUMS_FILE} next to ${PAYLOAD_FILE}`);
  }
  const line = fs
    .readFileSync(sumsPath, 'utf8')
    .split('\n')
    .map((entry) => entry.trim())
    .find((entry) => /^[0-9a-fA-F]{64}\s+\*?Astfind\.zip$/.test(entry));
  if (!line) {
    return fail(`invalid ${SUMS_FILE}: expected "<sha256>  Astfind.zip"`);
  }
  return line.split(/\s+/)[0].toLowerCase();
}

function verifyPayload(payloadDir) {
  const zip = path.join(payloadDir, PAYLOAD_FILE);
  const expected = Buffer.from(expectedPayloadHash(payloadDir), 'hex');
  const actual = crypto.createHash('sha256').update(fs.readFileSync(zip)).digest();
  if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) {
    fail('Astfind payload checksum mismatch; refusing to install.');
  }
  return zip;
}

function checkPayloadVersion(payloadDir) {
  const manifestPath = path.join(payloadDir, 'package.json');
  if (!fs.existsSync(manifestPath)) {
    return; // Test fixtures and local payload directories may omit it.
  }
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch {
    return fail(`invalid payload package.json in ${payloadDir}`);
  }
  const own = require('../package.json');
  if (payload.name && payload.name !== '@astfind/darwin-arm64') {
    return fail(`unexpected payload package: ${payload.name}`);
  }
  if (payload.version && payload.version !== own.version) {
    fail(
      `Astfind payload version ${payload.version} does not match CLI ${own.version}; ` +
        'reinstall with: npm i -g astfind@latest',
    );
  }
}

function isInside(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function verifyApp(app, options = {}) {
  const stat = fs.lstatSync(app);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail('Astfind.app in the payload is not a directory.');
  }

  const infoPlist = path.join(app, 'Contents', 'Info.plist');
  const bundleId = run('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', infoPlist]).trim();
  if (bundleId !== BUNDLE_ID) {
    fail(`unexpected bundle identifier: ${bundleId || '(missing)'}`);
  }
  const version = run('/usr/bin/plutil', [
    '-extract',
    'CFBundleShortVersionString',
    'raw',
    '-o',
    '-',
    infoPlist,
  ]).trim();

  if (!options.skipArchCheck) {
    const executable = path.join(app, 'Contents', 'MacOS', 'Astfind');
    const archs = run('/usr/bin/lipo', ['-archs', executable]).trim().split(/\s+/);
    if (!archs.includes('arm64')) {
      fail(`Astfind binary does not contain arm64: ${archs.join(', ')}`);
    }
  }

  if (!options.skipCodesign) {
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  }

  return { version };
}

function writeMarker(installRoot, payload) {
  const marker = {
    schema: MARKER_SCHEMA,
    packageVersion: require('../package.json').version,
    appVersion: payload.appVersion,
    path: targetPath(installRoot),
    arch: process.arch,
    installedAt: new Date().toISOString(),
  };
  const file = markerPath(installRoot);
  fs.writeFileSync(file, `${JSON.stringify(marker, null, 2)}\n`, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}

function readMarker(installRoot) {
  try {
    const marker = JSON.parse(fs.readFileSync(markerPath(installRoot), 'utf8'));
    return marker && marker.schema === MARKER_SCHEMA ? marker : null;
  } catch {
    return null;
  }
}

function installedAppVersion(installRoot) {
  const app = targetPath(installRoot);
  if (!fs.existsSync(app)) return null;
  try {
    return run('/usr/bin/plutil', [
      '-extract',
      'CFBundleShortVersionString',
      'raw',
      '-o',
      '-',
      path.join(app, 'Contents', 'Info.plist'),
    ]).trim();
  } catch {
    return null;
  }
}

function log(options, message) {
  if (!options.quiet) console.log(message);
}

function install(options = {}) {
  const problem = platformProblem(options);
  if (problem) return fail(problem);

  const installRoot = resolveInstallRoot(options);
  const payloadDir = resolvePayloadDir(options);
  checkPayloadVersion(payloadDir);
  const zip = verifyPayload(payloadDir);

  // Extract inside the destination directory so the final rename is atomic.
  // A dry run extracts to the system temp dir and never touches the install root.
  let staging;
  if (options.dryRun) {
    staging = fs.mkdtempSync(path.join(os.tmpdir(), 'astfind-verify-'));
  } else {
    fs.mkdirSync(installRoot, { recursive: true });
    staging = fs.mkdtempSync(path.join(installRoot, '.astfind-install-'));
  }
  fs.chmodSync(staging, 0o700);

  const target = targetPath(installRoot);
  let backup = null;
  let installed = false;
  try {
    run('/usr/bin/ditto', ['-x', '-k', zip, staging]);
    const extracted = path.join(staging, APP_NAME);
    if (!fs.existsSync(extracted)) {
      fail('payload does not contain Astfind.app at its root.');
    }
    const realStaging = fs.realpathSync(staging);
    if (!isInside(realStaging, fs.realpathSync(extracted))) {
      fail('payload escapes the extraction directory.');
    }
    const { version } = verifyApp(extracted, options);
    if (options.dryRun) {
      log(options, `Verified Astfind ${version}; dry run, nothing installed.`);
      return { path: target, version, replaced: false, dryRun: true };
    }

    let replaced = false;
    if (fs.existsSync(target) || isSymlink(target)) {
      if (isSymlink(target)) {
        fail(`${target} is a symbolic link; refusing to replace it.`);
      }
      backup = path.join(installRoot, `.${APP_NAME}.old-${process.pid}-${Date.now()}`);
      fs.renameSync(target, backup);
      replaced = true;
    }

    try {
      fs.renameSync(extracted, target);
      installed = true;
    } catch (error) {
      if (backup) fs.renameSync(backup, target);
      throw error;
    }
    if (backup) {
      fs.rmSync(backup, { recursive: true, force: true });
      backup = null;
    }

    writeMarker(installRoot, { appVersion: version });
    log(options, `Astfind ${version} installed at ${target}`);
    return { path: target, version, replaced };
  } catch (error) {
    if (!installed && backup && fs.existsSync(backup) && !fs.existsSync(target)) {
      try {
        fs.renameSync(backup, target);
      } catch {
        // The original error is more useful than a second failure.
      }
    }
    throw error;
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

function isSymlink(file) {
  try {
    return fs.lstatSync(file).isSymbolicLink();
  } catch {
    return false;
  }
}

function ensureInstalled(options = {}) {
  const installRoot = resolveInstallRoot(options);
  const version = installedAppVersion(installRoot);
  const marker = readMarker(installRoot);
  const own = require('../package.json');
  if (
    version &&
    marker &&
    marker.packageVersion === own.version &&
    path.resolve(marker.path) === path.resolve(targetPath(installRoot))
  ) {
    return { path: targetPath(installRoot), version, replaced: false };
  }
  return install({ ...options, installRoot });
}

function uninstall(options = {}) {
  const installRoot = resolveInstallRoot(options);
  const target = targetPath(installRoot);
  if (!fs.existsSync(target)) {
    return { removed: false, path: target };
  }
  if (isSymlink(target)) {
    fail(`${target} is a symbolic link; refusing to remove it.`);
  }
  const marker = readMarker(installRoot);
  if (!marker || path.resolve(marker.path) !== path.resolve(target)) {
    fail(`${target} was not installed by npm; refusing to remove it.`);
  }
  const infoPlist = path.join(target, 'Contents', 'Info.plist');
  const bundleId = run('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', infoPlist]).trim();
  if (bundleId !== BUNDLE_ID) {
    fail(`refusing to remove ${target}: unexpected bundle identifier ${bundleId || '(missing)'}`);
  }
  fs.rmSync(target, { recursive: true, force: false });
  fs.rmSync(markerPath(installRoot), { force: true });
  return { removed: true, path: target };
}

module.exports = {
  APP_NAME,
  BUNDLE_ID,
  InstallError,
  defaultInstallRoot,
  ensureInstalled,
  install,
  installedAppVersion,
  readMarker,
  resolveInstallRoot,
  targetPath,
  uninstall,
};
