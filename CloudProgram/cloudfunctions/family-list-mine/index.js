'use strict';
/**
 * 觅源 · 家族协作云函数：family-list-mine
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('./shared');

module.exports.handler = S.createHandler('family-list-mine', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const memberships = await S.listMemberships(userId, log);
  const out = [];
  for (let i = 0; i < memberships.length; i++) {
    const m = memberships[i];
    const f = await S.queryOne(S.T.FAMILY, [['familyId', '=', m.familyId]]);
    if (f === null) {
      continue;
    }
    out.push({
      familyId: f.familyId,
      title: f.title,
      bookKey: Number(f.bookKey || 0),
      rev: Number(f.rev || 0),
      aclVersion: Number(f.aclVersion || 1),
      directoryEnabled: f.directoryEnabled === true,
      inviteCode: m.role === S.ROLE.OWNER ? f.inviteCode : '',
      role: m.role,
      membershipStatus: m.status,
      branchRootUid: m.branchRootUid || '',
      expireAt: Number(m.expireAt || 0),
      createdAt: Number(f.createdAt || 0)
    });
  }
  return { families: out };

});
