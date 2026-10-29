'use strict';
/**
 * 觅源 · 家族协作云函数：change-submit
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 编辑者提交待审变更（§六 change-submit）。
 *  - 只写 ChangeRequest(PENDING)，**不改家族 rev**；
 *  - targetUid 必须在该编辑者认领分支（branchRootUid）子树内；
 *  - 频率限制：同一提交者每分钟 ≤10 条。
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('change-submit', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  const membership = await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  const family = await S.getFamily(familyId);
  const op = S.str(params, 'op').toUpperCase();
  const allowed = [S.OP.ADD, S.OP.UPDATE, S.OP.DELETE_REQ, S.OP.APPEND_TEXT];
  if (allowed.indexOf(op) < 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '不支持的变更类型：' + op);
  }
  const targetUid = S.normUid(S.str(params, 'targetUid'));
  if (targetUid.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 targetUid');
  }

  // 频率限制（§八.5）
  const since = S.nowMs() - 60 * 1000;
  const recent = await S.query(S.T.CHANGE_REQUEST, [
    ['familyId', '=', familyId], ['submitterId', '=', userId], ['createdAt', '>', since]
  ], { limit: 20 });
  if (recent.length >= 10) {
    throw new S.BizError(S.CODE.TOO_MANY, '提交过于频繁，请稍后再试', 'rate_limited');
  }

  // 分支认领越权校验
  const parentMap = await S.parentMapOf(familyId);
  if (!S.inBranchSubtree(targetUid, membership.branchRootUid, parentMap)) {
    throw new S.BizError(S.CODE.FORBIDDEN,
      '你只被授权补录认领分支内的族人，' + targetUid + ' 不在该分支内', 'out_of_branch');
  }

  const patchObj = (op === S.OP.DELETE_REQ) ? {} : S.parsePatch(params.patchJson);
  const existing = await S.queryOne(S.T.MEMBER, [['memberId', '=', S.memberIdOf(familyId, targetUid)]]);

  if (op === S.OP.ADD) {
    if (existing !== null && existing.deleted !== true) {
      throw new S.BizError(S.CODE.CONFLICT, '唯一ID 已存在：' + targetUid, 'uid_exists');
    }
    if (!patchObj.name || String(patchObj.name.a || '').trim().length === 0) {
      throw new S.BizError(S.CODE.BAD_REQUEST, '新增族人必须填写谱名');
    }
  } else if (existing === null) {
    throw new S.BizError(S.CODE.NOT_FOUND, '族人不存在：' + targetUid);
  }

  // 成环检测（用提交后的父亲链判断）
  const fatherAfter = patchObj.fatherId !== undefined
    ? S.normUid(patchObj.fatherId.a)
    : S.normUid((existing && existing.parentId) || '');
  const warnings = [];
  if (fatherAfter.length > 0) {
    const checkMap = Object.assign({}, parentMap);
    checkMap[targetUid] = fatherAfter;
    S.assertNoCycle(targetUid, fatherAfter, checkMap);
  }
  const personMap = await S.personMapOf(familyId);
  const genAfter = patchObj.generation !== undefined
    ? Number(patchObj.generation.a || 0)
    : Number((personMap[targetUid] || {}).generation || 0);
  const gw = S.generationWarning(targetUid, genAfter, fatherAfter, personMap);
  if (gw.length > 0) {
    warnings.push(gw);
  }

  const requestId = S.uuid();
  const row = {
    requestId: requestId,
    familyId: familyId,
    bookKey: Number(family.bookKey || 0),
    submitterId: userId,
    submitterName: S.str(params, 'submitterName', membership.nickName || ''),
    targetUid: targetUid,
    op: op,
    patchJson: (op === S.OP.DELETE_REQ) ? '{}' : JSON.stringify(patchObj),
    baseRev: S.num(params, 'baseRev', Number((existing && existing.rev) || 0)),
    evidence: S.str(params, 'evidence'),
    status: S.CHANGE_STATUS.PENDING,
    reviewerId: '',
    reviewNote: '',
    reviewedAt: 0,
    resultRev: 0,
    createdAt: S.nowMs()
  };
  await S.upsertOne(S.T.CHANGE_REQUEST, row);
  return {
    requestId: requestId,
    status: row.status,
    familyRev: Number(family.rev || 0),
    warnings: warnings
  };

});
