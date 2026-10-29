'use strict';
/**
 * 觅源 · 家族协作云函数：access-request
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 提交访问申请（§十三 门槛①申请查看 / ③申请成为族人）。
 *  - applicantId 由云函数按**可信身份**写入，绝不信端侧自报（§五.10）；
 *  - 已 PENDING 时幂等返回原单；10 分钟内最多 3 次（防刷）；
 *  - expireAt：VIEW_APPLY 默认 now+180 天，JOIN_CLAIM 默认 0（永久）。
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('access-request', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  if (familyId.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 familyId');
  }
  const family = await S.getFamily(familyId);
  const kind = S.str(params, 'kind', S.ACCESS_KIND.VIEW_APPLY).toUpperCase();
  const kinds = [S.ACCESS_KIND.VIEW_APPLY, S.ACCESS_KIND.JOIN_CLAIM];
  if (kinds.indexOf(kind) < 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '不支持的申请类型：' + kind);
  }

  // 已经是有效成员，无需重复申请
  const mine = await S.effectiveMembership(familyId, userId, log);
  if (mine !== null && mine.status === S.MEMBERSHIP_STATUS.ACTIVE) {
    return { requestId: '', status: 'ALREADY_MEMBER', role: mine.role };
  }
  // 已在某个家族获得有效授权的人，也只能按单家族逐条申请（这里不做跨家族判断）

  // 频率限制：同一申请人 10 分钟内最多 3 次
  const since = S.nowMs() - 10 * 60 * 1000;
  const recent = await S.query(S.T.ACCESS_REQUEST, [
    ['applicantId', '=', userId], ['createdAt', '>', since]
  ], { limit: 10 });
  if (recent.length >= 3) {
    throw new S.BizError(S.CODE.TOO_MANY, '申请过于频繁，请稍后再试', 'rate_limited');
  }

  // 幂等：同一申请人 + 同一 familyId 已有 PENDING 时直接返回原单
  const pending = await S.queryOne(S.T.ACCESS_REQUEST, [
    ['familyId', '=', familyId],
    ['applicantId', '=', userId],
    ['status', '=', S.ACCESS_STATUS.PENDING]
  ]);
  if (pending !== null) {
    return { requestId: pending.requestId, status: pending.status, duplicated: true };
  }

  const now = S.nowMs();
  const expireAt = kind === S.ACCESS_KIND.VIEW_APPLY
    ? now + S.VIEW_APPLY_DEFAULT_DAYS * 24 * 3600 * 1000
    : 0;
  const row = {
    requestId: S.uuid(),
    familyId: familyId,
    applicantId: userId,
    applicantName: S.str(params, 'applicantName'),
    kind: kind,
    relationClaim: S.str(params, 'relationClaim'),
    branchClaimUid: S.normUid(S.str(params, 'branchClaimUid')),
    evidence: S.str(params, 'evidence'),
    grantedRole: kind === S.ACCESS_KIND.JOIN_CLAIM ? S.ROLE.EDITOR : S.ROLE.VIEWER,
    expireAt: expireAt,
    status: S.ACCESS_STATUS.PENDING,
    reviewerId: '',
    reviewNote: '',
    reviewedAt: 0,
    createdAt: now,
    rev: Number(family.rev || 0)
  };
  await S.upsertOne(S.T.ACCESS_REQUEST, row);
  return { requestId: row.requestId, status: row.status, expireAt: expireAt };

});
