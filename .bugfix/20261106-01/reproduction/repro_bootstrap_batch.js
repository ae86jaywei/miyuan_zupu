'use strict';

/**
 * 复现：端侧 FamilyBootstrapService 以 MAX_BATCH_SIZE=200 组装批次，
 * 调用云端 family-bootstrap 后得到 code=400（对应调试日志中的持续失败）。
 *
 * 真实源码：
 *  - 端侧批次上限：Application/entry/src/main/ets/service/FamilyBootstrapService.ets
 *  - 云端函数：CloudProgram/cloudfunctions/family-bootstrap/index.js
 *  - 云端共享校验：CloudProgram/cloudfunctions/_shared/{index,validate,constants}.js
 *
 * 仅将 Cloud DB 替换为内存替身（db_stub.js），其余逻辑全部走项目原始源码。
 */

const path = require('path');
const fs = require('fs');
const Module = require('module');

const REPRO_ROOT = 'E:\\HarmonyOS\\miyuan_yunkaifa\\.bugfix\\20261106-01\\reproduction';
const FUNCTION_DIR = 'E:\\HarmonyOS\\miyuan_yunkaifa\\CloudProgram\\cloudfunctions\\family-bootstrap';
const SHARED_DIR = 'E:\\HarmonyOS\\miyuan_yunkaifa\\CloudProgram\\cloudfunctions\\_shared';
const CLIENT_SERVICE = 'E:\\HarmonyOS\\miyuan_yunkaifa\\Application\\entry\\src\\main\\ets\\service\\FamilyBootstrapService.ets';
const DB_STUB = path.join(REPRO_ROOT, 'db_stub.js');

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  const parentFile = parent && parent.filename ? parent.filename : '';
  // family-bootstrap/index.js 部署后通过 ./shared 引用共享库；复现时指向项目真实 _shared
  if (request === './shared' && /family-bootstrap[\\/]index\.js$/.test(parentFile)) {
    return originalLoad.call(this, path.join(SHARED_DIR, 'index.js'), parent, isMain);
  }
  // 所有共享模块中的 ./db 统一替换为内存替身，避免访问真实 Cloud DB
  if (request === './db' && /_shared[\\/][^\\/]+\.js$/.test(parentFile)) {
    return originalLoad.call(this, DB_STUB, parent, isMain);
  }
  return originalLoad.apply(this, arguments);
};

const handler = require(path.join(FUNCTION_DIR, 'index.js')).handler;
const stub = require(DB_STUB);

// 端侧 FamilyBootstrapService.MAX_BATCH_SIZE（从真实源码读取，保证复现与端侧契约一致）
function readClientBatchSize() {
  const text = fs.readFileSync(CLIENT_SERVICE, 'utf8');
  const matched = text.match(/MAX_BATCH_SIZE\s*:\s*number\s*=\s*(\d+)/);
  return matched ? Number(matched[1]) : 200;
}

const CLIENT_BATCH_SIZE = readClientBatchSize();

function buildPersons(count) {
  const persons = [];
  for (let i = 0; i < count; i++) {
    persons.push({
      uid: 'F' + String(i + 1),
      name: '族人' + String(i + 1),
      generation: 1,
      gender: 'M',
      birthDate: '',
      biography: ''
    });
  }
  return persons;
}

async function main() {
  const persons = buildPersons(CLIENT_BATCH_SIZE);
  const requestBytes = Buffer.byteLength(JSON.stringify(persons), 'utf8');
  const event = {
    headers: { 'x-user-id': 'hw-repro-user' },
    value: {
      familyId: 'fam-repro-001',
      cursor: 0,
      persons: persons,
      book: { title: '复现族谱' }
    }
  };

  const result = await handler(event, {}, null, console);

  console.log('[REPRO] client_batch_size=' + String(CLIENT_BATCH_SIZE));
  console.log('[REPRO] persons_json_bytes=' + String(requestBytes));
  console.log('[REPRO] response=' + JSON.stringify(result));
  console.log('[REPRO] db_writes=' + JSON.stringify(stub.getWriteStats()));

  if (result && result.code === 400) {
    console.log('[REPRO] DEFECT_REPRODUCED=1');
    console.log('[REPRO] failure_message=' + String(result.message || ''));
    process.exitCode = 0;
  } else if (result && result.code === 200) {
    console.log('[REPRO] FIX_CONFIRMED=1');
    console.log('[REPRO] written=' + String(result.data && result.data.written));
    process.exitCode = 0;
  } else {
    console.log('[REPRO] DEFECT_REPRODUCED=0');
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error('[REPRO] unexpected_error=' + (err && err.stack ? err.stack : String(err)));
  process.exitCode = 2;
});