'use strict';
/**
 * 觅源 · 家族协作云函数：family-create
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('family-create', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const title = S.str(params, 'title');
  const book = (params.book && typeof params.book === 'object') ? params.book : {};
  if (title.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '请填写谱名');
  }
  if (title.length > 64) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '谱名过长（≤64）');
  }
  const familyId = S.uuid();
  const now = S.nowMs();
  const family = {
    familyId: familyId,
    ownerUserId: userId,
    ownerUnionId: S.str(params, 'unionId'),
    title: title,
    bookKey: 0,
    rev: 0,
    aclVersion: 1,
    inviteCode: S.newInviteCode(),
    inviteExpireAt: 0,
    inviteRole: S.ROLE.VIEWER,
    directoryEnabled: false,
    directoryUpdatedAt: 0,
    createdAt: now,
    updatedAt: now
  };
  const membership = {
    membershipId: S.membershipId(familyId, userId),
    familyId: familyId,
    userId: userId,
    role: S.ROLE.OWNER,
    status: S.MEMBERSHIP_STATUS.ACTIVE,
    branchRootUid: '',
    expireAt: 0,
    nickName: S.str(params, 'nickName'),
    source: 'CREATE',
    joinedAt: now,
    revokedAt: 0,
    updatedAt: now
  };
  const bookRow = S.buildBookRow({ familyId: familyId, bookKey: 0, book: Object.assign({ title: title }, book), rev: 0, actor: userId });
  const res = await S.writeBatch([
    { op: 'upsert', type: S.T.FAMILY, objects: [family], label: 'Family' },
    { op: 'upsert', type: S.T.MEMBERSHIP, objects: [membership], label: 'Membership' },
    { op: 'upsert', type: S.T.BOOK, objects: [bookRow], label: 'FamilyBook' }
  ], log);
  if (!res.ok) {
    throw new S.BizError(S.CODE.INTERNAL, '创建家族失败：' + (res.done[res.done.length - 1].error || ''));
  }
  return { familyId: familyId, inviteCode: family.inviteCode, role: membership.role, rev: 0, directoryEnabled: false };

});
