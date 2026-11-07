'use strict';

/**
 * 复现用 Cloud DB 替身：只实现 family-bootstrap 鉴权/写入链路所需的最小读取与写入语义。
 * 生产实现见 CloudProgram/cloudfunctions/_shared/db.js。
 */

const FAMILY = {
  familyId: 'fam-repro-001',
  ownerUserId: 'hw-repro-user',
  bookKey: 0,
  title: '复现族谱',
  aclVersion: 1
};

const MEMBERSHIP = {
  membershipId: 'fam-repro-001#hw-repro-user',
  familyId: 'fam-repro-001',
  userId: 'hw-repro-user',
  role: 'OWNER',
  status: 'ACTIVE',
  expireAt: 0,
  revokedAt: 0,
  updatedAt: Date.now()
};

const writes = [];

async function getById(type, keyField, id) {
  if (type === 'Family' && keyField === 'familyId' && id === FAMILY.familyId) {
    return Object.assign({}, FAMILY);
  }
  if (type === 'Membership' && keyField === 'membershipId' && id === MEMBERSHIP.membershipId) {
    return Object.assign({}, MEMBERSHIP);
  }
  return null;
}

async function query(type, filters, options) {
  if (type === 'Membership') {
    return [Object.assign({}, MEMBERSHIP)];
  }
  return [];
}

async function upsertOne(type, row) {
  writes.push({ type: type, count: 1 });
  return 1;
}

async function upsertMany(type, rows) {
  writes.push({ type: type, count: rows ? rows.length : 0 });
  return rows ? rows.length : 0;
}

function getWriteStats() {
  const stats = {};
  for (let i = 0; i < writes.length; i++) {
    const w = writes[i];
    stats[w.type] = (stats[w.type] || 0) + w.count;
  }
  return stats;
}

module.exports = { getById, query, upsertOne, upsertMany, getWriteStats };