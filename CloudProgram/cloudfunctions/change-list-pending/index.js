'use strict';
/**
 * 觅源 · 家族协作云函数：change-list-pending
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 查看待审变更（§六 change-list-pending）。
 *  - OWNER 看全部；EDITOR 只看到自己认领分支内的提交。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('change-list-pending', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  const membership = await S.requireMember(familyId, userId, S.ROLE.EDITOR, log);
  const status = S.str(params, 'status', S.CHANGE_STATUS.PENDING);
  const conds = [['familyId', '=', familyId]];
  if (status !== 'ALL') {
    conds.push(['status', '=', status]);
  }
  const rows = await S.query(S.T.CHANGE_REQUEST, conds, { limit: 200, orderBy: [['createdAt', 'ASC']] });
  const isOwner = membership.role === S.ROLE.OWNER;
  const parentMap = await S.parentMapOf(familyId);
  const visible = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (!isOwner && !S.inBranchSubtree(r.targetUid, membership.branchRootUid, parentMap)) {
      continue;
    }
    const target = await S.queryOne(S.T.MEMBER, [['memberId', '=', S.memberIdOf(familyId, r.targetUid)]]);
    const out = Object.assign({}, r);
    out.targetName = target !== null ? String(target.name || '') : '';
    visible.push(out);
  }
  const family = await S.getFamily(familyId);
  return { requests: visible, role: membership.role, headRev: Number(family.rev || 0) };

});
