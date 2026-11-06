'use strict';
/**
 * 觅源 · 家族协作云函数：family-join
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('./shared');

module.exports.handler = S.createHandler('family-join', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const code = S.str(params, 'inviteCode').toUpperCase();
  if (code.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '请输入加入码');
  }
  const family = await S.queryOne(S.T.FAMILY, [['inviteCode', '=', code]]);
  if (family === null) {
    throw new S.BizError(S.CODE.NOT_FOUND, '加入码无效或已失效');
  }
  const now = S.nowMs();
  const inviteExpireAt = S.num(family.inviteExpireAt, 0);
  if (inviteExpireAt > 0 && now > inviteExpireAt) {
    throw new S.BizError(S.CODE.FORBIDDEN, '加入码已过期，请联系谱主重新获取', 'invite_expired');
  }
  const existing = await S.effectiveMembership(family.familyId, userId, log);
  // [SEC-FIX] CWE-863：被移出（REVOKED）的成员不得凭同一邀请码自动恢复，需谱主显式恢复。
  if (existing !== null && existing.status === S.MEMBERSHIP_STATUS.REVOKED) {
    throw new S.BizError(S.CODE.FORBIDDEN, '你已被移出该族谱，请联系谱主恢复', 'membership_revoked');
  }
  if (existing !== null && existing.status === S.MEMBERSHIP_STATUS.ACTIVE) {
    return { familyId: family.familyId, title: family.title, role: existing.role, already: true };
  }
  const inviteRole = family.inviteRole === S.ROLE.EDITOR ? S.ROLE.EDITOR : S.ROLE.VIEWER;
  const row = {
    membershipId: S.membershipId(family.familyId, userId),
    familyId: family.familyId,
    userId: userId,
    role: inviteRole,
    status: S.MEMBERSHIP_STATUS.ACTIVE,
    // [SEC-FIX] CWE-639：加入时不允许自选分支，默认全谱；分支授权由谱主单独分配。
    branchRootUid: '',
    expireAt: 0,
    nickName: S.str(params, 'nickName'),
    source: 'INVITE',
    joinedAt: now,
    revokedAt: 0,
    updatedAt: now
  };
  await S.upsertOne(S.T.MEMBERSHIP, row);
  return { familyId: family.familyId, title: family.title, role: inviteRole, already: false };

});
