#!/usr/bin/env node
/**
 * 字段一致性检查（本地 / CI 可跑）
 *
 * 背景：Person 字段同时出现在模型、补丁、SQLite、CSV、云同步等位置。
 * 本脚本只做静态检查，不修改代码：
 *   1. FIELD_METAS 的字段是否都进了协作补丁白名单；
 *   2. SQLite 建表列是否都被 PERSON_DB_COLUMNS 覆盖；
 *   3. CSV 列是否都有 fieldOf / applyImportCell 的 case。
 *
 * 用法：node Application/scripts/check-field-consistency.js
 * 退出码：0 全部通过；1 存在缺失。
 */
const fs = require('fs');
const path = require('path');

const ETS = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const BASE = path.join(__dirname, '..', 'common', 'base', 'src', 'main', 'ets');
const read = (rel) => fs.readFileSync(path.join(ETS, rel), 'utf8');
const readBase = (rel) => fs.readFileSync(path.join(BASE, rel), 'utf8');

function unique(list) {
  return [...new Set(list)];
}

function indexOfAll(text, regex) {
  const out = [];
  let m;
  while ((m = regex.exec(text)) !== null) out.push(m[1]);
  return out;
}

// 1. 模型字段
const person = readBase('model/Person.ets');
const metaBlock = person.match(/FIELD_METAS: FieldMeta\[\] = \[([^\]]*?)\]/);
const metaKeys = unique(indexOfAll(metaBlock[1], /key:\s*'([A-Za-z]+)'/g));

// 2. 注册表
const registry = readBase('model/FieldRegistry.ets');
const patchText = registry.match(/PATCH_TEXT_FIELD_KEYS: string\[\] = \[([^\]]*?)\]/);
const patchNum = registry.match(/PATCH_NUMBER_FIELD_KEYS: string\[\] = \[([^\]]*?)\]/);
const patchBool = registry.match(/PATCH_BOOLEAN_FIELD_KEYS: string\[\] = \[([^\]]*?)\]/);
const patchKeys = unique([
  ...indexOfAll(patchText[1], /'([A-Za-z]+)'/g),
  ...indexOfAll(patchNum[1], /'([A-Za-z]+)'/g),
  ...indexOfAll(patchBool[1], /'([A-Za-z]+)'/g),
]);

const dbKeys = unique(indexOfAll(registry, /column:\s*'([a-z_]+)'/g));
const csvCols = unique(indexOfAll(registry.match(/PERSON_CSV_COLUMNS: string\[\] = \[([^\]]*?)\]/)[1], /'([^']+)'/g));

// 3. 导出/导入覆盖
const exportService = read('service/ExportService.ets');
const fieldCases = unique(indexOfAll(exportService, /case '([^']+)':/g));

// 4. 建表列（DDL 已拆分到 service/db/DatabaseSchema.ets）
const schema = read('service/db/DatabaseSchema.ets');
const ddlStart = schema.indexOf('CREATE TABLE IF NOT EXISTS ${TABLE_PERSON}');
const ddlEnd = schema.indexOf(')`);', ddlStart);
const ddl = ddlStart < 0 ? '' : schema.slice(ddlStart, ddlEnd);
const ddlCols = unique(indexOfAll(ddl, /^\s*([a-z_]+)\s+(TEXT|INTEGER|REAL)/gm)).filter((c) => c !== 'id');

// 允许的例外：补丁不追踪表级/系统字段
const NON_PATCH = new Set(['bookId', 'book_id', 'createdAt', 'created_at', 'updatedAt', 'updated_at', 'rev', 'baseRev', 'dirty', 'deletedAt',
  'birthCalendar', 'deathCalendar', 'spouses']);

const problems = [];

// 1. 模型字段 → 补丁
const missingPatch = metaKeys.filter((k) => !NON_PATCH.has(k) && !patchKeys.includes(k));
if (missingPatch.length) problems.push('模型字段未进补丁白名单: ' + missingPatch.join(', '));

// 2. 建表列 → 注册表
const missingDb = ddlCols.filter((c) => !dbKeys.includes(c));
if (missingDb.length) problems.push('建表列未被 PERSON_DB_COLUMNS 覆盖: ' + missingDb.join(', '));

// 3. CSV 列 → 导出/导入 case
const missingCase = csvCols.filter((c) => !fieldCases.includes(c));
if (missingCase.length) problems.push('CSV 列缺 fieldOf/applyImportCell case: ' + missingCase.join(', '));

// 4. 补丁字段 → 注册表中是否有中文名（粗略：FIELD_METAS 或 EXTRA_LABELS）
const extraLabels = unique(indexOfAll(registry, /EXTRA_LABELS\.set\('([A-Za-z]+)'/g));
const missingLabel = patchKeys.filter((k) => !metaKeys.includes(k) && !extraLabels.includes(k));
if (missingLabel.length) problems.push('补丁字段缺中文名: ' + missingLabel.join(', '));

// 5. 云函数白名单 → 注册表（避免本地加字段、云侧漏字段导致补丁被丢弃）
const cloudPatchPath = path.join(__dirname, '..', '..', 'CloudProgram', 'cloudfunctions', '_shared', 'patch.js');
let cloudKeyCount = 0;
if (fs.existsSync(cloudPatchPath)) {
  const cloud = fs.readFileSync(cloudPatchPath, 'utf8');
  const cloudBlock = cloud.match(/PATCHABLE_FIELDS = \[([\s\S]*?)\];/);
  if (cloudBlock) {
    const cloudKeys = unique(indexOfAll(cloudBlock[1], /'([A-Za-z]+)'/g));
    cloudKeyCount = cloudKeys.length;
    const missingCloud = patchKeys.filter((k) => !cloudKeys.includes(k));
    if (missingCloud.length) problems.push('云函数白名单缺字段: ' + missingCloud.join(', '));
  } else {
    problems.push('云函数 patch.js 未找到 PATCHABLE_FIELDS');
  }
  const labelBlock = cloud.match(/FIELD_LABELS = \{([\s\S]*?)\};/);
  if (labelBlock) {
    const cloudLabels = unique(indexOfAll(labelBlock[1], /([A-Za-z]+):\s*'/g));
    const missingCloudLabel = patchKeys.filter((k) => !cloudLabels.includes(k));
    if (missingCloudLabel.length) problems.push('云函数缺字段中文名: ' + missingCloudLabel.join(', '));
  } else {
    problems.push('云函数 patch.js 未找到 FIELD_LABELS');
  }
} else {
  problems.push('未找到云函数 patch.js: ' + cloudPatchPath);
}

console.log('字段统计:');
console.log('  FIELD_METAS      ', metaKeys.length);
console.log('  补丁字段         ', patchKeys.length);
console.log('  SQLite 列        ', dbKeys.length, '(建表', ddlCols.length + ')');
console.log('  CSV 列           ', csvCols.length);
console.log('  云函数白名单     ', cloudKeyCount);
console.log('');

if (problems.length === 0) {
  console.log('PASS: 字段元数据一致。');
  process.exit(0);
}

console.log('FAIL:');
for (const p of problems) console.log('  - ' + p);
process.exit(1);