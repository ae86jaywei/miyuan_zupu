'use strict';
/**
 * 觅源 · 家族协作云函数：access-review
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 谱主审批访问申请（§五.10 / §13.5）。
 * ⚠️ 硬约束：审批通过的唯一动作 = 写一条 Membership，**不得另建授权体系**。
 *   - 三条门槛（①申请认证 ②分享链接 ③成为族人）最终都只落这张表；
 *   - expireAt 默认：门槛① now+180 天，门槛③ 0（永久）。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('access-review', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const requestId = S.str(params, 'requestId');
  if (requestId.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 requestId');
  }
  const req = await S.queryOne(S.T.ACCESS_REQUEST, [['requestId', '=', requestId]]);
  if (req === null) {
    throw new S.BizError(S.CODE.NOT_FOUND, '申请单不存在');
  }
  const familyId = req.familyId;
  await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
  if (req.status !== S.ACCESS_STATUS.PENDING) {
    throw new S.BizError(S.CODE.CONFLICT, '该申请已处理（' + req.status + '）', 'already_reviewed');
  }
  const family = await S.getFamily(familyId);
  const decision = S.str(params, 'decision').toUpperCase();
  const note = S.str(params, 'note');
  const now = S.nowMs();

  if (decision === 'REJECTED') {
    const rejected = Object.assign({}, req);
    rejected.status = S.ACCESS_STATUS.REJECTED;
    rejected.reviewerId = userId;
    rejected.reviewNote = note;
    rejected.reviewedAt = now;
    rejected.rev = Number(family.rev || 0);
    await S.upsertOne(S.T.ACCESS_REQUEST, rejected);
    return { ok: true, status: rejected.status, membershipId: '' };
  }
  if (decision !== 'APPROVED') {
    throw new S.BizError(S.CODE.BAD_REQUEST, 'decision 只能是 APPROVED / REJECTED');
  }

  // 互锁 1：不能审批自己提交的申请（避免谱主把自己降级）
  if (req.applicantId === userId) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '不能审批自己提交的申请', 'self_review');
  }
  // 互锁 2：谱主本人永远保持 OWNER，审批只能标记申请单，绝不改写其 Membership
  if (req.applicantId === family.ownerUserId) {
    const passed = Object.assign({}, req);
    passed.status = S.ACCESS_STATUS.APPROVED;
    passed.reviewerId = userId;
    passed.reviewNote = note;
    passed.reviewedAt = now;
    passed.grantedRole = S.ROLE.OWNER;
    passed.rev = Number(family.rev || 0);
    await S.upsertOne(S.T.ACCESS_REQUEST, passed);
    return { ok: true, status: passed.status, membershipId: '', note: '谱主权限不受影响' };
  }

  const isJoin = req.kind === S.ACCESS_KIND.JOIN_CLAIM;
  // [SEC-FIX] CWE-269：审批只能授予 VIEWER / EDITOR，禁止通过 grantedRole 参数授予 OWNER。
  const fallbackRole = isJoin ? S.ROLE.EDITOR : S.ROLE.VIEWER;
  const requestedRole = S.str(params, 'grantedRole', req.grantedRole || fallbackRole);
  const role = (requestedRole === S.ROLE.VIEWER || requestedRole === S.ROLE.EDITOR)
    ? requestedRole : fallbackRole;
  // [SEC-FIX] CWE-613：非加入类授权不允许永久有效，且期限上限 3650 天，防止客户端放大授权期。
  const MAX_EXPIRE_MS = 3650 * 24 * 3600 * 1000;
  let expireAt = S.num(params, 'expireAt', -1);
  if (isJoin && expireAt === 0) {
    expireAt = 0;
  } else if (expireAt <= 0) {
    expireAt = now + S.VIEW_APPLY_DEFAULT_DAYS * 24 * 3600 * 1000;
  } else if (expireAt > now + MAX_EXPIRE_MS) {
    expireAt = now + MAX_EXPIRE_MS;
  }

  const existing = await S.findMembership(familyId, req.applicantId);
  const row = existing !== null ? Object.assign({}, existing) : {
    membershipId: S.membershipId(familyId, req.applicantId),
    familyId: familyId,
    userId: req.applicantId,
    role: role,
    status: S.MEMBERSHIP_STATUS.ACTIVE,
    branchRootUid: '',
    expireAt: expireAt,
    nickName: req.applicantName || '',
    source: 'ACCESS',
    joinedAt: now,
    revokedAt: 0,
    updatedAt: now
  };
  // 互锁 3：绝不覆盖既有 OWNER
  const keepOwner = (existing !== null && existing.role === S.ROLE.OWNER);
  row.role = keepOwner ? S.ROLE.OWNER : role;
  row.status = S.MEMBERSHIP_STATUS.ACTIVE;
  row.expireAt = expireAt;
  row.branchRootUid = S.str(params, 'branchRootUid', req.branchClaimUid || row.branchRootUid || '');
  row.revokedAt = 0;
  row.updatedAt = now;

  const approved = Object.assign({}, req);
  approved.status = S.ACCESS_STATUS.APPROVED;
  approved.reviewerId = userId;
  approved.reviewNote = note;
  approved.reviewedAt = now;
  approved.grantedRole = role;
  approved.expireAt = expireAt;
  approved.rev = Number(family.rev || 0);

  family.aclVersion = Number(family.aclVersion || 1) + 1;
  family.updatedAt = now;

  const res = await S.writeBatch([
    { op: 'upsert', type: S.T.MEMBERSHIP, objects: [row], label: 'Membership' },
    { op: 'upsert', type: S.T.ACCESS_REQUEST, objects: [approved], label: 'AccessRequest' },
    { op: 'upsert', type: S.T.FAMILY, objects: [Object.assign({}, family)], label: 'Family' }
  ], log);
  if (!res.ok) {
    throw new S.BizError(S.CODE.INTERNAL, '审批写入失败：' + res.done[res.done.length - 1].label);
  }
  return {
    ok: true,
    status: approved.status,
    membershipId: row.membershipId,
    role: role,
    expireAt: expireAt
  };

});
