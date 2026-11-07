'use strict';

/**
 * 字段级 diff（§五.5 patchJson 形如 {"birthDate":{"b":"","a":"1942-05"}}）。
 */

const { PRIVATE_FIELDS, LONG_TEXT_FIELDS } = require('./constants');
const { BizError, CODE } = require('./core');

/** 允许在 patch 里出现的字段（Person 公开字段 + 隐私字段，隐私字段会被写进 FamilyPrivate） */
const PATCHABLE_FIELDS = ['uid', 'generation', 'name', 'alias', 'gender', 'generationChar', 'lifeStatus',
  'childStatus', 'birthDate', 'birthCalendar', 'deathDate', 'deathCalendar', 'birthPlace', 'residence',
  'fatherId', 'motherId', 'spouseId', 'spouses', 'rank', 'adoption', 'education', 'occupation', 'biography',
  'graveInfo', 'graveLng', 'graveLat', 'graveAltitude', 'phone', 'wechat', 'avatar', 'videos', 'photos'];

function isLongText(path) {
  return path.indexOf('biographySegments') >= 0;
}

/**
 * 校验并解析 patch。
 * @returns {object} { path: {b, a} }
 */
function parsePatch(patchJson) {
  let parsed = patchJson;
  if (typeof patchJson === 'string') {
    try {
      parsed = JSON.parse(patchJson);
    } catch (e) {
      throw new BizError(CODE.BAD_REQUEST, 'patchJson 不是合法 JSON');
    }
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new BizError(CODE.BAD_REQUEST, 'patchJson 必须是 {字段: {b, a}} 形式的对象');
  }
  const keys = Object.keys(parsed);
  const out = {};
  for (let i = 0; i < keys.length; i++) {
    const path = keys[i];
    const root = path.split('.')[0];
    if (PATCHABLE_FIELDS.indexOf(root) < 0 && !isLongText(path)) {
      throw new BizError(CODE.BAD_REQUEST, '不支持变更该字段：' + path);
    }
    const item = parsed[path];
    if (item === null || typeof item !== 'object' || !('a' in item)) {
      throw new BizError(CODE.BAD_REQUEST, '字段 ' + path + ' 缺少新值 a');
    }
    out[path] = { b: item.b === undefined ? null : item.b, a: item.a };
  }
  return out;
}

/**
 * 把 patch 应用到一份 person 对象上。
 *  - biography 走分段模型（§九）：整块变更被拒绝，只接受 APPEND_TEXT；
 *  - spouse.* 路径直接写 spouseObject。
 */
function applyPatch(target, patch, opts) {
  const person = JSON.parse(JSON.stringify(target || {}));
  const keys = Object.keys(patch);
  for (let i = 0; i < keys.length; i++) {
    const path = keys[i];
    const value = patch[path].a;
    const root = path.split('.')[0];
    if (root === 'biography' && !isLongText(path)) {
      if (LONG_TEXT_FIELDS.indexOf(root) >= 0 && opts && opts.allowLongText) {
        person[root] = value;
        continue;
      }
      throw new BizError(CODE.BAD_REQUEST,
        '生平简介不支持下整块覆盖变更，请使用追加段落（APPEND_TEXT）');
    }
    setPath(person, path, value);
  }
  return person;
}

function setPath(obj, path, value) {
  const parts = path.split('.');
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const key = parts[i];
    if (cur[key] === undefined || cur[key] === null || typeof cur[key] !== 'object') {
      cur[key] = {};
    }
    cur = cur[key];
  }
  cur[parts[parts.length - 1]] = value;
}

function getPath(obj, path) {
  const parts = path.split('.');
  let cur = obj;
  for (let i = 0; i < parts.length; i++) {
    if (cur === undefined || cur === null || typeof cur !== 'object') {
      return undefined;
    }
    cur = cur[parts[i]];
  }
  return cur;
}

/** 从 patch 中拆出隐私字段与公开字段 */
function splitPatch(patch) {
  const pub = {};
  const priv = {};
  Object.keys(patch).forEach((path) => {
    const root = path.split('.')[0];
    if (PRIVATE_FIELDS.indexOf(root) >= 0) {
      priv[path] = patch[path];
    } else {
      pub[path] = patch[path];
    }
  });
  return { pub, priv };
}

/** 生成人可读的变更摘要 */
function summarize(op, targetName, patch) {
  if (op === 'ADD') {
    return '新增族人：' + (targetName || '');
  }
  if (op === 'DELETE_REQ') {
    return '请求删除族人：' + (targetName || '');
  }
  if (op === 'APPEND_TEXT') {
    return '追加长文段落：' + (targetName || '');
  }
  const keys = Object.keys(patch || {});
  const shown = keys.slice(0, 3).map((k) => k.split('.')[0]).join('、');
  return '修改族人：' + (targetName || '') + (keys.length > 3 ? ' 等 ' + keys.length + ' 个字段' : '（' + shown + '）');
}

const FIELD_LABELS = {
  name: '谱名', alias: '曾用名', gender: '性别', generation: '世代', generationChar: '字派',
  lifeStatus: '在世状态', childStatus: '子女身份', birthDate: '出生日期', deathDate: '逝世日期',
  birthPlace: '出生地', residence: '现居地', fatherId: '父亲ID', motherId: '母亲ID', spouses: '配偶',
  rank: '排行', adoption: '过继/出嗣', education: '学历', occupation: '职业', biography: '生平简介',
  graveInfo: '墓葬信息', graveLng: '墓葬经度', graveLat: '墓葬纬度', graveAltitude: '墓葬海拔',
  phone: '手机号', wechat: '微信号', avatar: '头像', videos: '视频', photos: '相片', uid: '唯一ID'
};

function labelOf(path) {
  const root = path.split('.')[0];
  return FIELD_LABELS[root] || root;
}

module.exports = { PATCHABLE_FIELDS, parsePatch, applyPatch, getPath, setPath, splitPatch, summarize, labelOf };
