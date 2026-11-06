'use strict';
/**
 * 觅源 · 家族协作云函数：member-direct-write
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 shared/）
 */
const S = require('./shared');

module.exports.handler = S.createHandler('member-direct-write', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  const membership = await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  const uid = S.normUid(S.str(params, 'uid'));
  const op = S.str(params, 'op', S.OP.UPDATE).toUpperCase();
  // 谱元信息直写：uid 约定为空串，payload 为 Genealogy.toCloudPayload()
  if (uid.length === 0) {
    const familyRow0 = await S.getFamily(familyId);
    const bookJson = S.parseJson(params.patchJson, {});
    const allocated0 = await S.allocate(familyRow0, 2, log);
    const bookRow = S.buildBookRow({ familyId: familyId, bookKey: familyRow0.bookKey || 0, book: bookJson, rev: allocated0.rev, actor: userId });
    await S.upsertOne(S.T.BOOK, bookRow);
    await S.upsertOne(S.T.CHANGE_LOG, S.changeLogRow({
      familyId: familyId, rev: allocated0.rev, actor: userId, action: 'BOOK_UPDATE',
      targetMemberId: familyId + '#book', summary: '更新族谱元信息：' + String(bookJson.title || ''),
      payload: { title: bookJson.title }
    }));
    return { ok: true, rev: allocated0.rev };
  }
  const parentMap = await S.parentMapOf(familyId);
  if (!S.inBranchSubtree(uid, membership.branchRootUid, parentMap)) {
    throw new S.BizError(S.CODE.FORBIDDEN, '只能直接修改认领分支内的族人', 'out_of_branch');
  }
  const row = await S.queryOne(S.T.MEMBER, [['memberId', '=', S.memberIdOf(familyId, uid)]]);
  const isAdd = op === S.OP.ADD;
  if (row === null && !isAdd) {
    throw new S.BizError(S.CODE.NOT_FOUND, '族人不存在');
  }
  if (row !== null && isAdd && row.deleted !== true) {
    throw new S.BizError(S.CODE.CONFLICT, '唯一ID 已存在：' + uid, 'uid_exists');
  }
  const familyRow = await S.getFamily(familyId);
  const baseRev = row === null ? 0 : S.num(params, 'baseRev', Number(row.rev || 0));
  if (row !== null && Number(row.rev || 0) > baseRev) {
    // 字段级 LWW 的前置：对方已在你之后改过 → 交由端侧呈现「保留对方/保留我的/合并」
    throw new S.BizError(S.CODE.CONFLICT, '这条记录已被他人修改（当前 rev=' + Number(row.rev || 0) + '），请先同步', 'stale');
  }
  const patchObj = S.parsePatch(params.patchJson);
  if (isAdd && row === null && String(patchObj.name ? patchObj.name.a : '').trim().length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '新增族人必须填写谱名');
  }
  const personBefore = row === null ? {} : S.personOf(row);
  const personAfter = op === S.OP.DELETE_REQ ? S.personOf(row) : S.applyPatch(personBefore, patchObj, { allowLongText: true });
  const deleted = op === S.OP.DELETE_REQ;
  const split = S.splitPerson(personAfter);
  S.assertPayloadSize(JSON.stringify(split.person));
  const allocated = await S.allocate(familyRow, 2, log);
  const newRev = allocated.rev;
  const hasPrivate = !!(split.privateData.phone || split.privateData.wechat || split.privateData.residence);
  const hasGrave = S.hasGraveData(split.grave);
  const memberNew = S.buildMemberRow({
    familyId: familyId, bookKey: Number(row === null ? (familyRow.bookKey || 0) : (row.bookKey || 0)), uid: uid,
    person: split.person, rev: newRev, actor: userId, deleted: deleted, hasPrivate: hasPrivate, hasGrave: hasGrave
  });
  memberNew.baseRev = newRev;
  const steps = [
    { op: 'upsert', type: S.T.MEMBER, objects: [memberNew], label: 'FamilyMember' },
    { op: 'upsert', type: S.T.CHANGE_LOG, objects: [S.changeLogRow({
      familyId: familyId, rev: newRev, actor: userId, action: op, targetMemberId: memberNew.memberId,
      summary: S.summarize(op, split.person.name, patchObj), payload: { patch: patchObj, direct: true }
    })], label: 'ChangeLog' }
  ];
  if (hasPrivate && !deleted) {
    steps.push({ op: 'upsert', type: S.T_PRIVATE, objects: [S.buildPrivateRow(familyId, uid, split.privateData, userId)], label: 'FamilyPrivate' });
  }
  const res = await S.writeBatch(steps, log);
  if (!res.ok) {
    throw new S.BizError(S.CODE.INTERNAL, '写入失败：' + (res.done[res.done.length - 1].label));
  }
  return { ok: true, rev: newRev };

});
