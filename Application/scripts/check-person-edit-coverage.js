#!/usr/bin/env node
/**
 * 编辑页字段覆盖检查
 *
 * 检查 Person.FIELD_METAS 的每个字段是否在 PersonEdit 中出现：
 *   - 表单状态 this.f<Key>
 *   - 提交字段 p.<key>
 *   - 或作为字符串键（如 spouses / 导入模板）
 *
 * 用法：node Application/scripts/check-person-edit-coverage.js
 */
const fs = require('fs');
const path = require('path');

const ETS = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const BASE = path.join(__dirname, '..', 'common', 'base', 'src', 'main', 'ets');
const person = fs.readFileSync(path.join(BASE, 'model', 'Person.ets'), 'utf8');
const edit = fs.readFileSync(path.join(ETS, 'pages', 'PersonEdit.ets'), 'utf8');

const metaBlock = person.match(/FIELD_METAS: FieldMeta\[\] = \[([^\]]*?)\]/);
const keys = [...new Set([...metaBlock[1].matchAll(/key:\s*'([A-Za-z]+)'/g)].map((m) => m[1]))];

/** 由其它字段派生、不单独编辑的字段 */
const DERIVED = new Set(['spouseId']);

const missing = [];
for (const key of keys) {
  if (DERIVED.has(key)) continue;
  const cap = key.charAt(0).toUpperCase() + key.slice(1);
  const found = edit.includes('this.f' + cap) || edit.includes('p.' + key) || edit.includes("'" + key + "'");
  if (!found) missing.push(key);
}

console.log('FIELD_METAS 字段:', keys.length);
if (missing.length === 0) {
  console.log('PASS: 编辑页覆盖全部字段。');
  process.exit(0);
}
console.log('FAIL: 以下字段未在编辑页出现:');
for (const k of missing) console.log('  - ' + k);
process.exit(1);