#!/usr/bin/env node
// Generates the self-hosted update manifest (latest.json) for an Astfind zip.
//
//   node AstfindKit/scripts/make-update-manifest.mjs \
//     --zip AstfindKit/build/Astfind-0.4.1.zip \
//     --version 0.4.1 --build 401 \
//     --notes AstfindKit/build/update-notes.json \
//     --output AstfindKit/build/latest.json
//
// The manifest and the zip must be published on the same HTTPS host; the app
// rejects cross-host URLs and verifies size + SHA-256 before installation.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) {
    if (fallback !== undefined) return fallback;
    throw new Error(`missing --${name}`);
  }
  if (index + 1 >= process.argv.length) throw new Error(`missing value for --${name}`);
  return process.argv[index + 1];
}

const zipPath = path.resolve(argument('zip'));
const version = argument('version');
const build = Number(argument('build'));
const baseURL = argument('base-url', 'https://astfind.robyn.top/updates').replace(/\/+$/, '');
const notesPath = path.resolve(argument('notes'));
const outputPath = path.resolve(argument('output', 'AstfindKit/build/latest.json'));
const minimumSystemVersion = argument('minimum-system', '14.0');
const published = argument('published', new Date().toISOString().slice(0, 10));

if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(version)) throw new Error(`invalid version: ${version}`);
if (!Number.isInteger(build) || build < 0) throw new Error(`invalid build: ${build}`);

const archive = fs.readFileSync(zipPath);
const notes = JSON.parse(fs.readFileSync(notesPath, 'utf8'));
if (!Array.isArray(notes.zh) || notes.zh.length === 0) throw new Error('notes.zh must be a non-empty array');
if (!Array.isArray(notes.en) || notes.en.length === 0) throw new Error('notes.en must be a non-empty array');

const manifest = {
  version,
  build,
  url: `${baseURL}/Astfind-${version}.zip`,
  size: archive.length,
  sha256: crypto.createHash('sha256').update(archive).digest('hex'),
  minimumSystemVersion,
  published,
  notes,
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, JSON.stringify(manifest, null, 2) + '\n');
console.log(`Wrote ${outputPath}`);
console.log(`  ${manifest.url}`);
console.log(`  size ${manifest.size}`);
console.log(`  sha256 ${manifest.sha256}`);
