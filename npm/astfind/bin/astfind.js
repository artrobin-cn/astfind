#!/usr/bin/env node
'use strict';

const path = require('node:path');
const { execFileSync } = require('node:child_process');
const pkg = require('../package.json');
const {
  InstallError,
  defaultInstallRoot,
  ensureInstalled,
  install,
  installedAppVersion,
  resolveInstallRoot,
  targetPath,
  uninstall,
} = require('../lib/install');

const HELP = `Astfind — local-first unified search for macOS (Apple Silicon)

Usage:
  astfind                 Launch Astfind (installs/upgrades the app if needed)
  astfind open            Same as above
  astfind --path          Print the installed app path
  astfind --version       Print CLI and app versions
  astfind --verify        Verify the bundled payload without installing
  astfind --uninstall     Remove the app installed by this npm package
  astfind update          Show how to update
  astfind --help          Show this help

Install root: ${defaultInstallRoot()} (override with ASTFIND_INSTALL_ROOT)
The app is a menu-bar app; after launching, open the panel with the global hotkey.`;

function appVersion(installRoot) {
  return installedAppVersion(installRoot) || 'not installed';
}

function printVersions(installRoot) {
  console.log(`astfind ${pkg.version} (app ${appVersion(installRoot)})`);
}

function openApp(installRoot) {
  const installed = ensureInstalled({ installRoot });
  if (installed.replaced) {
    console.log(`Astfind ${installed.version} is ready at ${installed.path}`);
  }
  execFileSync('/usr/bin/open', [targetPath(installRoot)], { stdio: 'inherit' });
}

function main(argv) {
  const args = argv.slice(2);
  const command = args.find((arg) => !arg.startsWith('-')) || 'open';
  const installRoot = resolveInstallRoot();

  if (args.includes('--help') || args.includes('-h') || command === 'help') {
    console.log(HELP);
    return 0;
  }
  if (args.includes('--version') || args.includes('-v') || command === 'version') {
    printVersions(installRoot);
    return 0;
  }
  if (args.includes('--path') || command === 'path') {
    console.log(targetPath(installRoot));
    return 0;
  }
  if (args.includes('--verify') || args.includes('--dry-run') || command === 'verify') {
    const result = install({ dryRun: true });
    console.log(`Verified Astfind ${result.version}; nothing was installed.`);
    return 0;
  }
  if (args.includes('--uninstall') || command === 'uninstall') {
    const result = uninstall({ installRoot });
    console.log(result.removed ? `Removed ${result.path}` : `Nothing to remove at ${result.path}`);
    return 0;
  }
  if (command === 'update') {
    const installed = appVersion(installRoot);
    if (installed === pkg.version) {
      console.log(`Astfind ${pkg.version} is already installed.`);
    } else {
      console.log(`Installed app: ${installed}; npm package: ${pkg.version}.`);
      console.log('Update with: npm i -g astfind@latest');
    }
    return 0;
  }
  if (command === 'open') {
    openApp(installRoot);
    return 0;
  }

  console.error(`Unknown command: ${command}\n`);
  console.error(HELP);
  return 2;
}

try {
  process.exitCode = main(process.argv);
} catch (error) {
  if (error instanceof InstallError) {
    console.error(`astfind: ${error.message}`);
    console.error('You can also install the DMG from https://github.com/artrobin-cn/astfind/releases');
    process.exitCode = 1;
  } else {
    console.error(`astfind: ${error.message}`);
    process.exitCode = 1;
  }
}
