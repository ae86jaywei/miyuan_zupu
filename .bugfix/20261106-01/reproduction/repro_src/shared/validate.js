'use strict';

/**
 * 云侧结构校验（§六 末尾 4 条）。
 * 端侧校验只是体验优化，云侧校验才是数据护栏。
 */

const { BizError, CODE, normUid } = require('./core');
const { MAX_PAYLOAD_BYTES } = require('./constants');

/** 1. uid 家族内唯一（大小写归一，对齐 IdGenerator.isUnique 语义） */
function assertUniqueUid(uid) {
  const u = normUid(uid);
  if (u.length === 0) {
    throw new BizError(CODE.BAD_REQUEST, '缺少人物唯一ID');
  }
  if (u.length > 32) {
    throw new BizError(CODE.BAD_REQUEST, '唯一ID 过长（≤32）');
  }
  return u;
}

/**
 * 2. parentId / fatherId 链路不得成环（否则 TreeBuilder 递归渲染崩溃）。
 * @param {string} uid 待写入人物
 * @param {string} fatherId 其父亲
 * @param {object} parentMap { uid: fatherId }
 */
function assertNoCycle(uid, fatherId, parentMap) {
  const self = normUid(uid);
  let cur = normUid(fatherId);
  const visited = new Set([self]);
  let depth = 0;
  while (cur.length > 0) {
    if (visited.has(cur)) {
      throw new BizError(CODE.BAD_REQUEST, '父亲链路成环：' + self + ' → ' + cur);
    }
    visited.add(cur);
    cur = normUid(parentMap[cur] || '');
    depth++;
    if (depth > 64) {
      throw new BizError(CODE.BAD_REQUEST, '父亲链路过深（>64 代），疑似成环');
    }
  }
  return true;
}

/**
 * 3. 世代一致性：generation(child) = generation(father) + 1。
 * 违反时返回警告而不是拒绝（古谱中常见跨代记录），由端侧展示提示。
 */
function generationWarning(uid, generation, fatherId, personMap) {
  const f = normUid(fatherId);
  if (f.length === 0) {
    return '';
  }
  const father = personMap[f];
  if (!father) {
    return '';
  }
  const expected = Number(father.generation || 0) + 1;
  const actual = Number(generation || 0);
  if (expected > 1 && actual > 0 && expected !== actual) {
    return '族人 ' + uid + ' 的世代(' + actual + ') 与其父 ' + f + ' 的世代(' + (expected - 1) + ') 不连续';
  }
  return '';
}

/** 4. payload 序列化后 ≤ 2MB（含安全余量） */
function assertPayloadSize(payload) {
  const size = Buffer.byteLength(typeof payload === 'string' ? payload : JSON.stringify(payload || {}), 'utf8');
  if (size > MAX_PAYLOAD_BYTES) {
    throw new BizError(CODE.BAD_REQUEST, '该人物数据过大（' + Math.round(size / 1024) + 'KB），请精简图片/视频引用');
  }
  return size;
}

/** 黄页字段白名单校验（§五.11 红线：拒绝任何疑似人物数据） */
function assertDirectoryPayload(fields, whitelist, forbiddenKeys, bands) {
  const keys = Object.keys(fields || {});
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (whitelist.indexOf(k) < 0) {
      throw new BizError(CODE.BAD_REQUEST, '黄页不允许写入该字段：' + k + '（只允许谱名/姓氏/地域等索引元数据）');
    }
    if (forbiddenKeys.indexOf(k) >= 0) {
      throw new BizError(CODE.BAD_REQUEST, '黄页字段 ' + k + ' 疑似人物数据，已拒绝');
    }
  }
  const band = fields.memberCountBand;
  if (band !== undefined && band !== null && String(band).length > 0 && bands.indexOf(String(band)) < 0) {
    throw new BizError(CODE.BAD_REQUEST, '人数必须以区间填写：' + bands.join(' / '));
  }
  // 文本长度上限，避免黄页被当成大文本通道
  const limits = { surname: 8, region: 64, title: 64, branchSummary: 200, coverRef: 512, accessHint: 64 };
  Object.keys(limits).forEach((k) => {
    const v = fields[k];
    if (v !== undefined && v !== null && String(v).length > limits[k]) {
      throw new BizError(CODE.BAD_REQUEST, '黄页字段 ' + k + ' 超长（≤' + limits[k] + '）');
    }
  });
  return true;
}

module.exports = { assertUniqueUid, assertNoCycle, generationWarning, assertPayloadSize, assertDirectoryPayload };
