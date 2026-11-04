'use strict';

const fs = require('fs');
const path = require('path');

const source = __dirname;
const functionRoot = process.cwd();
const target = path.join(functionRoot, 'shared');

if (!fs.existsSync(path.join(functionRoot, 'index.js'))) {
  console.error('[zupu-shared] run this script from a cloud function directory');
  process.exit(1);
}

fs.rmSync(target, { recursive: true, force: true });
fs.mkdirSync(target, { recursive: true });

for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
  if (entry.name === 'install-into-function.js' || entry.name === 'node_modules') {
    continue;
  }
  fs.cpSync(path.join(source, entry.name), path.join(target, entry.name), { recursive: true });
}

const credential = path.resolve(functionRoot, '../../agconnect-credential.json');
if (fs.existsSync(credential)) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(credential, 'utf8'));
  } catch (err) {
    console.error('[zupu-shared] invalid agconnect-credential.json');
    process.exit(1);
  }
  if (parsed.private_key || parsed.token_uri) {
    console.error('[zupu-shared] service account keys are not supported; use an AGC API client credential');
    process.exit(1);
  }
  if (parsed.type !== 'project_client_id' && parsed.type !== 'team_client_id') {
    console.error('[zupu-shared] unsupported credential type: ' + String(parsed.type));
    process.exit(1);
  }
  fs.copyFileSync(credential, path.join(functionRoot, 'agconnect-credential.json'));
}

console.log('[zupu-shared] synced to ' + target);