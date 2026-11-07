'use strict';

/**
 * 协作成员记录的组装（§五.3 FamilyMember，协作 Zone 新表）。
 *
 * 与老备份 Zone 的 FamilyMember 不同：
 *  - memberId = {familyId}#{uid}（老格式为 b{bookKey}_{uid}），因此 CloudModels 是「参照改造」而非复用；
 *  - payload 只含公开字段（隐私字段进 FamilyPrivate，墓葬坐标进 FamilyGraveLocation）。
 */

const { nowMs, normUid } = require('./core');
const { T, OP } = require('./constants');
const privacy = require('./privacy');
const revModule = require('./rev');
const db = require('./db');

function memberIdOf(familyId, uid) {
  return familyId + '#' + normUid(uid);
}

/** 组装一条 FamilyMember 行 */
function buildMemberRow(p) {
  const person = p.person || {};
  const uid = normUid(p.uid || person.uid);
  const payload = privacy.toPublicPayload(person);
  return {
    memberId: memberIdOf(p.familyId, uid),
    familyId: p.familyId,
    bookKey: Number(p.bookKey || 0),
    uid: uid,
    name: String(person.name || ''),
    generation: Number(person.generation || 1),
    parentId: String(person.fatherId || ''),
    payload: payload,
    privateRef: p.hasPrivate ? privacy.privateRef(p.familyId, uid) : '',
    graveRef: p.hasGrave ? privacy.graveRef(p.familyId, uid) : '',
    rev: Number(p.rev || 0),
    actor: p.actor || '',
    deleted: p.deleted === true,
    deletedAt: p.deleted === true ? nowMs() : 0,
    deletedBy: p.deleted === true ? (p.actor || '') : '',
    baseRev: Number(p.rev || 0),
    updatedAt: nowMs()
  };
}

/** 组装 FamilyPrivate 行（活人隐私字段，端侧永不可直读） */
function buildPrivateRow(familyId, uid, data, actor) {
  return {
    privateId: privacy.privateRef(familyId, normUid(uid)),
    familyId: familyId,
    uid: normUid(uid),
    phone: String((data || {}).phone || ''),
    wechat: String((data || {}).wechat || ''),
    residence: String((data || {}).residence || ''),
    actor: actor || '',
    updatedAt: nowMs()
  };
}

/** 组装 FamilyBook 行（谱元信息） */
function buildBookRow(p) {
  const book = p.book || {};
  const payload = {
    key: Number(p.bookKey || 0),
    title: String(book.title || ''),
    surname: String(book.surname || ''),
    hallName: String(book.hallName || ''),
    junwang: String(book.junwang || ''),
    ancestorName: String(book.ancestorName || ''),
    generationPoem: String(book.generationPoem || ''),
    preface: String(book.preface || ''),
    familyRules: String(book.familyRules || ''),
    editingNotes: String(book.editingNotes || ''),
    coverColor: String(book.coverColor || ''),
    coverPattern: String(book.coverPattern || ''),
    branchRootUid: String(book.branchRootUid || ''),
    createdAt: Number(book.createdAt || 0),
    updatedAt: Number(book.updatedAt || 0)
  };
  return {
    bookId: p.familyId + '#' + String(p.bookKey || 0),
    familyId: p.familyId,
    bookKey: Number(p.bookKey || 0),
    title: payload.title,
    payload: JSON.stringify(payload),
    rev: Number(p.rev || 0),
    actor: p.actor || '',
    baseRev: Number(p.rev || 0),
    deleted: false,
    updatedAt: nowMs()
  };
}

/** 从云端 FamilyMember 行中取其 payload 对应的 person 对象（已脱敏） */
function personOf(row) {
  let payload = {};
  try {
    payload = JSON.parse(row.payload || '{}');
  } catch (e) {
    payload = { uid: row.uid, name: row.name, generation: row.generation, fatherId: row.parentId };
  }
  if (!payload.uid) {
    payload.uid = row.uid;
  }
  if (!payload.name) {
    payload.name = row.name;
  }
  if (!payload.generation) {
    payload.generation = row.generation;
  }
  return payload;
}

/** 当前家族全部成员的 parentMap（用于成环检测 / 分支子树判定） */
async function parentMapOf(familyId) {
  const rows = await db.query(T.MEMBER, [['familyId', '=', familyId], ['deleted', '=', false]], { limit: 1000 });
  const map = {};
  rows.forEach((r) => {
    map[normUid(r.uid)] = normUid(r.parentId || '');
  });
  return map;
}

async function personMapOf(familyId) {
  const rows = await db.query(T.MEMBER, [['familyId', '=', familyId], ['deleted', '=', false]], { limit: 1000 });
  const map = {};
  rows.forEach((r) => {
    map[normUid(r.uid)] = { uid: r.uid, generation: Number(r.generation || 0), name: r.name };
  });
  return map;
}

module.exports = { memberIdOf, buildMemberRow, buildPrivateRow, buildBookRow, personOf, parentMapOf, personMapOf, OP, revModule };
