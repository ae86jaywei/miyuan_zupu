'use strict';

/**
 * payload 脱敏（§八.1、§八.2 第 1 步）。
 *
 * 规则（必须守住，否则整条隐私设计失效）：
 *  1. 活人隐私字段（phone / wechat / residence）**绝不**进入 FamilyMember.payload，
 *     只存到 FamilyPrivate（端侧永远没有该表的读权限，只有 OWNER 经云函数可取）。
 *  2. 墓葬坐标（graveLng / graveLat / graveAltitude）同样不进 payload，
 *     它们迁到公开对象类型 FamilyGraveLocation（§五.8）。两条路径不混：
 *     **要么迁出去公开，要么剔除，不能又剔除又想公开**。
 */

const { PRIVATE_FIELDS, GRAVE_COORD_FIELDS } = require('./constants');

/** 从 Person 中摘除隐私字段与墓葬坐标，返回 { person, privateData, grave } */
function splitPerson(src) {
  const person = Object.assign({}, src || {});
  const privateData = {};
  const grave = {};
  PRIVATE_FIELDS.forEach((f) => {
    if (person[f] !== undefined) {
      privateData[f] = person[f];
      delete person[f];
    }
  });
  GRAVE_COORD_FIELDS.forEach((f) => {
    if (person[f] !== undefined) {
      grave[f] = person[f];
      delete person[f];
    }
  });
  if (person.graveInfo !== undefined) {
    grave.graveInfo = person.graveInfo;
    delete person.graveInfo;
  }
  return { person, privateData, grave };
}

/** 序列化为 FamilyMember.payload */
function toPublicPayload(person) {
  return JSON.stringify(splitPerson(person).person);
}

/** 隐私包指针：{familyId}#{uid} */
function privateRef(familyId, uid) {
  return familyId + '#' + uid;
}

/** 墓葬指针：{familyId}#{uid} */
function graveRef(familyId, uid) {
  return familyId + '#' + uid;
}

/** 是否含有墓葬坐标（用于决定是否写公开墓葬表） */
function hasGraveData(grave) {
  const lng = Number((grave || {}).graveLng || 0);
  const lat = Number((grave || {}).graveLat || 0);
  return (lng !== 0 || lat !== 0) || String((grave || {}).graveInfo || '').length > 0;
}

/**
 * 从端侧上传的「完整 Person」中提取墓葬字段，组装公开墓葬行。
 * 只有 EDITOR 及以上能触发；visibility=FAMILY_ONLY 时**不写公开表**（真移出，非端侧过滤）。
 */
function buildGraveRow(p) {
  const familyId = p.familyId;
  const uid = p.uid;
  const person = p.person || {};
  const visibility = p.visibility === 'FAMILY_ONLY' ? 'FAMILY_ONLY' : 'PUBLIC';
  const precision = p.precision === 'BLURRED' ? 'BLURRED' : 'EXACT';
  const row = {
    graveId: graveRef(familyId, uid),
    familyId: familyId,
    uid: uid,
    personName: p.personName || person.name || '',
    generation: Number(person.generation || p.generation || 0),
    bookTitle: p.bookTitle || '',
    graveName: p.graveName || person.graveInfo || '',
    lng: Number(person.graveLng || 0),
    lat: Number(person.graveLat || 0),
    altitude: Number(person.graveAltitude || 0),
    facing: p.facing || '',
    bearing: p.bearing || '',
    routeNote: p.routeNote || '',
    photoRefs: typeof p.photoRefs === 'string' ? p.photoRefs : JSON.stringify(p.photoRefs || []),
    visibility: visibility,
    precision: precision,
    rev: Number(p.rev || 0),
    actor: p.actor || '',
    updatedAt: Date.now()
  };
  if (precision === 'BLURRED') {
    row.lng = round4(row.lng);
    row.lat = round4(row.lat);
  }
  return row;
}

/** 约 30m 模糊：保留 4 位小数（≈11m），再按 30m 网格取整 */
function round4(v) {
  return Math.round(v * 10000) / 10000;
}

module.exports = { splitPerson, toPublicPayload, privateRef, graveRef, hasGraveData, buildGraveRow, round4 };
