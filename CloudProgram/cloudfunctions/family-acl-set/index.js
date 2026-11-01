'use strict';
/**
 * 觅源 · 家族协作云函数：family-acl-set
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 谱主调整成员角色 / 分支 / 期限 / 状态，或轮换加入码（§六 family-acl-set）。
 * ACL 变化 = Membership 改动 + Family.aclVersion + 1。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('family-acl-set', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
  const action = S.str(params, 'action', 'UPDATE').toUpperCase();
  const family = await S.getFamily(familyId);
  const now = S.nowMs();

  // 轮换加入码：旧码立即失效（§八.3 邀请码治理）
  if (action === 'ROTATE_INVITE') {
    family.inviteCode = S.newInviteCode();
    family.inviteExpireAt = S.num(params, 'inviteExpireAt', 0);
    family.inviteRole = S.str(params, 'inviteRole', family.inviteRole || S.ROLE.VIEWER);
    family.updatedAt = now;
    await S.upsertOne(S.T.FAMILY, Object.assign({}, family));
    return { inviteCode: family.inviteCode, inviteRole: family.inviteRole };
  }

  const targetUserId = S.str(params, 'targetUserId');
  if (targetUserId.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 targetUserId');
  }
  if (targetUserId === family.ownerUserId) {
    const newRole = S.str(params, 'role', S.ROLE.OWNER);
    const newStatus = S.str(params, 'status', S.MEMBERSHIP_STATUS.ACTIVE);
    if (newRole !== S.ROLE.OWNER || newStatus === S.MEMBERSHIP_STATUS.REVOKED) {
      throw new S.BizError(S.CODE.FORBIDDEN, '不能降级或撤销谱主本人', 'owner_protected');
    }
  }
  const row = await S.findMembership(familyId, targetUserId);
  if (row === null) {
    throw new S.BizError(S.CODE.NOT_FOUND, '该成员不存在');
  }
  const next = Object.assign({}, row);
  next.role = S.str(params, 'role', next.role);
  next.branchRootUid = S.str(params, 'branchRootUid', next.branchRootUid || '');
  next.expireAt = S.num(params, 'expireAt', Number(next.expireAt || 0));
  const status = S.str(params, 'status', '');
  if (status.length > 0) {
    next.status = status;
    if (status === S.MEMBERSHIP_STATUS.REVOKED) {
      next.revokedAt = now;
    }
  }
  next.updatedAt = now;

  family.aclVersion = Number(family.aclVersion || 1) + 1;
  family.updatedAt = now;
  const res = await S.writeBatch([
    { op: 'upsert', type: S.T.MEMBERSHIP, objects: [next], label: 'Membership' },
    { op: 'upsert', type: S.T.FAMILY, objects: [Object.assign({}, family)], label: 'Family' }
  ], log);
  if (!res.ok) {
    throw new S.BizError(S.CODE.INTERNAL, '写入失败：' + (res.done[res.done.length - 1].label || ''));
  }
  return { ok: true, aclVersion: family.aclVersion, role: next.role, status: next.status };

});
