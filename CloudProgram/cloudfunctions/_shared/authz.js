'use strict';

/**
 * Membership 鉴权（§五.2、§五.10、§13.5）。
 *
 * 「可见性 = 有没有一条 ACTIVE 且未过期的 Membership」——这是全系统唯一的门禁，
 * 三条门槛（申请认证 / 分享链接 / 成为族人）最终都只写这一张表。
 */

const { BizError, CODE, nowMs, normUid } = require('./core');
const { T, ROLE, MEMBERSHIP_STATUS } = require('./constants');
const db = require('./db');

const ROLE_RANK = { OWNER: 3, EDITOR: 2, VIEWER: 1 };

function membershipId(familyId, userId) {
  return String(familyId) + '#' + String(userId);
}

/** 读取某人对某家族的 Membership 行（可能为 null） */
async function findMembership(familyId, userId) {
  if (!familyId || !userId) {
    return null;
  }
  return db.getById(T.MEMBERSHIP, 'membershipId', membershipId(familyId, userId));
}

/**
 * 惰性失效（§五.10）：到期即视为失效，并顺手把状态置 EXPIRED。
 * 正确性依赖「读取只走云函数」，已由 §五.9 端侧 [] 权限保证。
 */
async function effectiveMembership(familyId, userId, logger) {
  const row = await findMembership(familyId, userId);
  if (row === null) {
    return null;
  }
  // 自愈：Family.ownerUserId 才是「谱主」的权威来源。
  // 历史 bug（access-review 误覆盖）会把谱主自己的行降级成 VIEWER，导致其再也无权调用
  // 任何 OWNER 级接口（含 family-acl-set），形成死锁。这里读到即修复。
  if (row.role !== ROLE.OWNER) {
    const fam = await db.getById(T.FAMILY, 'familyId', familyId);
    if (fam !== null && fam.ownerUserId === userId) {
      row.role = ROLE.OWNER;
      row.status = MEMBERSHIP_STATUS.ACTIVE;
      row.expireAt = 0;
      row.revokedAt = 0;
      row.updatedAt = nowMs();
      try {
        await db.upsertOne(T.MEMBERSHIP, Object.assign({}, row));
      } catch (e) {
        if (logger) {
          logger.warn('[zupu][authz] self-heal owner failed: ' + (e && e.message));
        }
      }
    }
  }
  if (row.status === MEMBERSHIP_STATUS.REVOKED) {
    return row;
  }
  const expireAt = Number(row.expireAt || 0);
  if (expireAt > 0 && nowMs() > expireAt && row.status !== MEMBERSHIP_STATUS.EXPIRED) {
    row.status = MEMBERSHIP_STATUS.EXPIRED;
    try {
      await db.upsertOne(T.MEMBERSHIP, Object.assign({}, row));
    } catch (e) {
      if (logger) {
        logger.warn('[zupu][authz] mark expired failed: ' + (e && e.message));
      }
    }
  }
  return row;
}

/**
 * 要求调用者是某家族的 ACTIVE 成员，且角色不低于 minRole。
 * @returns {Promise<object>} membership 行
 */
async function requireMember(familyId, userId, minRole, logger) {
  if (!familyId) {
    throw new BizError(CODE.BAD_REQUEST, '缺少 familyId');
  }
  const row = await effectiveMembership(familyId, userId, logger);
  if (row === null) {
    throw new BizError(CODE.FORBIDDEN, '你不是该族谱的成员，请先申请查看或使用邀请码加入', 'not_member');
  }
  if (row.status === MEMBERSHIP_STATUS.EXPIRED) {
    throw new BizError(CODE.FORBIDDEN, '授权已到期，请向谱主重新申请', 'membership_expired');
  }
  if (row.status !== MEMBERSHIP_STATUS.ACTIVE) {
    throw new BizError(CODE.FORBIDDEN, '成员权限未生效（当前状态：' + row.status + '）', 'membership_inactive');
  }
  const min = ROLE_RANK[minRole || ROLE.VIEWER] || 1;
  const mine = ROLE_RANK[row.role] || 0;
  if (mine < min) {
    throw new BizError(CODE.FORBIDDEN, '当前角色（' + row.role + '）无权执行该操作', 'insufficient_role');
  }
  return row;
}

/** 取某人的全部有效成员关系（端侧用于「我的家族」列表） */
async function listMemberships(userId, logger) {
  const rows = await db.query(T.MEMBERSHIP, [['userId', '=', userId]], { limit: 200 });
  const out = [];
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    if (row.status === MEMBERSHIP_STATUS.ACTIVE) {
      const effective = await effectiveMembership(row.familyId, userId, logger);
      out.push(effective || row);
    } else {
      out.push(row);
    }
  }
  return out;
}

/**
 * 分支认领越权校验（§六 change-submit）：targetUid 必须在 branchRootUid 的子树内。
 * branchRootUid 为空 = 全谱授权，直接通过。
 */
function inBranchSubtree(targetUid, branchRootUid, parentMap) {
  const root = normUid(branchRootUid);
  const target = normUid(targetUid);
  if (root.length === 0) {
    return true;
  }
  if (target.length === 0) {
    return false;
  }
  if (target === root) {
    return true;
  }
  let cur = target;
  const visited = new Set();
  let depth = 0;
  while (cur.length > 0 && depth < 64) {
    if (visited.has(cur)) {
      return false;
    }
    visited.add(cur);
    const pid = normUid(parentMap[cur] || '');
    if (pid === root) {
      return true;
    }
    if (pid.length === 0) {
      return false;
    }
    cur = pid;
    depth++;
  }
  return false;
}

module.exports = { membershipId, findMembership, effectiveMembership, requireMember, listMemberships, inBranchSubtree, ROLE_RANK };