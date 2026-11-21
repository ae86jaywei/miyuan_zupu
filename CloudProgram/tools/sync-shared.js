'use strict';

/**
 * 一键把 _shared/ 同步到所有云函数的 shared/ 目录。
 *
 * 用法：node tools/sync-shared.js   （或 npm run sync-shared）
 *
 * 设计：复用各函数已有的 _shared/install-into-function.js，对每个云函数目录
 * 以子进程执行一次，保证复制规则、agconnect-credential.json 校验逻辑与
 * npm preinstall 完全一致，避免两套逻辑漂移。
 *
 * 解决的问题：改 _shared/ 后无需逐个函数手动跑 install，一条命令同步全部；
 * 配合 DevEco「Before Launch」步骤可在部署前自动触发，实现改完直接部署。
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const cloudFunctionsRoot = path.join(__dirname, '..', 'cloudfunctions');
const installer = path.join(cloudFunctionsRoot, '_shared', 'install-into-function.js');

if (!fs.existsSync(installer)) {
  console.error('[sync-shared] 找不到安装脚本：' + installer);
  process.exit(1);
}

const functions = fs.readdirSync(cloudFunctionsRoot, { withFileTypes: true })
  .filter((d) => d.isDirectory() && d.name !== '_shared')
  .map((d) => path.join(cloudFunctionsRoot, d.name))
  .filter((fn) => fs.existsSync(path.join(fn, 'index.js')));

if (functions.length === 0) {
  console.error('[sync-shared] 未找到任何云函数目录（需含 index.js）');
  process.exit(1);
}

let count = 0;
for (const fn of functions) {
  execFileSync(process.execPath, [installer], { cwd: fn, stdio: 'inherit' });
  count++;
}
console.log('[sync-shared] 已同步 ' + count + ' 个云函数的 shared/ 目录（源：_shared/）');
