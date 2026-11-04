#!/usr/bin/env node
'use strict';

// Installs the app during `npm i -g astfind`. The CLI also installs lazily, so
// `npm install --ignore-scripts` still works on first run.

if (process.env.ASTFIND_SKIP_INSTALL === '1') {
  console.log('Astfind: postinstall skipped (ASTFIND_SKIP_INSTALL=1). Run `astfind` to install on first launch.');
  process.exit(0);
}

const { install } = require('../lib/install');

try {
  install();
} catch (error) {
  console.error(`\nAstfind: could not install the app: ${error.message}`);
  console.error('Install the DMG instead: https://github.com/artrobin-cn/astfind/releases');
  process.exit(1);
}
