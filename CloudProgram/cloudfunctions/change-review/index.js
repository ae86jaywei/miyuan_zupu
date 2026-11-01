'use strict';
/**
 * 觅源 · 家族协作云函数：change-review
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 谱主审核合入（§六 change-review）。
 *  1) baseRev 过期 → 标记 SUPERSEDED，退回提交者重做；
 *  2) APPROVED：读成员 → 字段级合入 → 分配新 rev → 成员 + ChangeLog 一批原子写；
 *  3) DELETE_REQ 写入墓碑（deleted=true），不物理删除。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('change-review', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const requestId = S.str(params, 'requestId');
  if (requestId.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 requestId');
  }
  const req = await S.queryOne(S.T.CHANGE_REQUEST, [['requestId', '=', requestId]]);
  if (req === null) {
    throw new S.BizError(S.CODE.NOT_FOUND, '变更单不存在');
  }
  const familyId = req.familyId;
  await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
  const decision = S.str(params, 'decision').toUpperCase();
  const note = S.str(params, 'note');
  const now = S.nowMs();

  if (decision === 'REJECTED') {
    const rejected = Object.assign({}, req);
    rejected.status = S.CHANGE_STATUS.REJECTED;
    rejected.reviewerId = userId;
    rejected.reviewNote = note;
    rejected.reviewedAt = now;
    await S.upsertOne(S.T.CHANGE_REQUEST, rejected);
    return { ok: true, status: rejected.status, rev: 0 };
  }
  if (decision !== 'APPROVED') {
    throw new S.BizError(S.CODE.BAD_REQUEST, 'decision 只能是 APPROVED / REJECTED');
  }
  if (req.status !== S.CHANGE_STATUS.PENDING) {
    throw new S.BizError(S.CODE.CONFLICT, '该变更单已处理（' + req.status + '）', 'already_reviewed');
  }

  const family = await S.getFamily(familyId);
  const targetUid = S.normUid(req.targetUid);
  const memberRow = await S.queryOne(S.T.MEMBER, [['memberId', '=', S.memberIdOf(familyId, targetUid)]]);
  const baseRev = Number(req.baseRev || 0);
  if (memberRow !== null && Number(memberRow.rev || 0) > baseRev) {
    const superseded = Object.assign({}, req);
    superseded.status = S.CHANGE_STATUS.SUPERSEDED;
    superseded.reviewerId = userId;
    superseded.reviewNote = '基线已过期（提交基线 rev=' + baseRev + '，当前成员 rev=' +
      Number(memberRow.rev || 0) + '），请重新提交';
    superseded.reviewedAt = now;
    await S.upsertOne(S.T.CHANGE_REQUEST, superseded);
    return { ok: false, status: superseded.status, rev: Number(family.rev || 0), message: superseded.reviewNote };
  }

  const patchObj = S.parseJson(req.patchJson, {});
  let personAfter;
  let deleted = false;
  if (req.op === S.OP.DELETE_REQ) {
    personAfter = memberRow !== null ? S.personOf(memberRow) : { uid: targetUid };
    deleted = true;
  } else if (req.op === S.OP.APPEND_TEXT) {
    const base = memberRow !== null ? S.personOf(memberRow) : { uid: targetUid };
    const before = base.biography || '';
    const added = req.patchJson ? String((patchObj.text && patchObj.text.a) || '') : '';
    personAfter = Object.assign({}, base);
    personAfter.biography = before.length > 0 ? (before + '\n\n' + added) : added;
  } else {
    const base = memberRow !== null ? S.personOf(memberRow) : { uid: targetUid };
    personAfter = S.applyPatch(base, patchObj, { allowLongText: true });
  }

  const split = S.splitPerson(personAfter);
  S.assertPayloadSize(JSON.stringify(split.person));
  const allocated = await S.allocate(family, 2, log);
  const newRev = allocated.rev;
  const hasPrivate = !!(split.privateData.phone || split.privateData.wechat || split.privateData.residence);
  const hasGrave = S.hasGraveData(split.grave);
  const memberNew = S.buildMemberRow({
    familyId: familyId,
    bookKey: Number(req.bookKey || 0),
    uid: targetUid,
    person: split.person,
    rev: newRev,
    actor: req.submitterId,
    deleted: deleted,
    hasPrivate: hasPrivate,
    hasGrave: hasGrave
  });
  memberNew.baseRev = newRev;
  const summary = S.summarize(req.op, split.person.name, patchObj);
  const steps = [
    { op: 'upsert', type: S.T.MEMBER, objects: [memberNew], label: 'FamilyMember:' + targetUid }
  ];
  if (hasPrivate && !deleted) {
    steps.push({
      op: 'upsert',
      type: S.T_PRIVATE,
      objects: [S.buildPrivateRow(familyId, targetUid, split.privateData, req.submitterId)],
      label: 'FamilyPrivate'
    });
  }
  steps.push({
    op: 'upsert',
    type: S.T.CHANGE_LOG,
    objects: [S.changeLogRow({
      familyId: familyId,
      rev: newRev,
      actor: req.submitterId,
      action: req.op || 'UPDATE',
      targetMemberId: S.memberIdOf(familyId, targetUid),
      summary: summary,
      payload: { op: req.op, patch: patchObj, approvedBy: userId, requestId: requestId }
    })],
    label: 'ChangeLog'
  });
  const approved = Object.assign({}, req);
  approved.status = S.CHANGE_STATUS.APPROVED;
  approved.reviewerId = userId;
  approved.reviewNote = note;
  approved.reviewedAt = now;
  approved.resultRev = newRev;
  steps.push({ op: 'upsert', type: S.T.CHANGE_REQUEST, objects: [approved], label: 'ChangeRequest' });

  const res = await S.writeBatch(steps, log);
  if (!res.ok) {
    throw new S.BizError(S.CODE.INTERNAL, '合入失败：' + (res.done[res.done.length - 1].error || ''));
  }
  return { ok: true, status: approved.status, rev: newRev, summary: summary };

});
