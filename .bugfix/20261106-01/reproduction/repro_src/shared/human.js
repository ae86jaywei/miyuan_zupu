'use strict';

/** 供 ChangeLog.summary / 审批流水使用的人可读文案 */
const { labelOf } = require('./patch');

function diffText(before, after) {
  const keys = Object.keys(after || {});
  const parts = [];
  keys.forEach((k) => {
    const label = labelOf(k);
    const b = before ? before[k] : undefined;
    const a = after[k];
    if (JSON.stringify(b) === JSON.stringify(a)) {
      return;
    }
    const bs = b === undefined || b === null ? '（空）' : String(b);
    const as = a === undefined || a === null ? '（空）' : String(a);
    parts.push(label + '：' + truncate(bs) + ' → ' + truncate(as));
  });
  return parts.join('；');
}

function truncate(s) {
  const v = String(s);
  return v.length > 24 ? v.substring(0, 24) + '…' : v;
}

function dateText(ms) {
  const d = new Date(Number(ms || 0));
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

module.exports = { diffText, truncate, dateText };
