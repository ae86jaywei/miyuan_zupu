'use strict';
/**
 * 觅源 · 家族协作云函数：family-acl-list
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 谱主查看成员列表与当前加入码（§六 family-acl-list）。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('family-acl-list', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
  const family = await S.getFamily(familyId);
  const rows = await S.query(S.T.MEMBERSHIP, [['familyId', '=', familyId]], { limit: 500 });
  const out = [];
  for (let i = 0; i < rows.length; i++) {
    // 惰性失效：列表里也把已过期的成员标成 EXPIRED
    const m = await S.effectiveMembership(familyId, rows[i].userId, log);
    out.push(m || rows[i]);
  }
  return {
    memberships: out,
    inviteCode: family.inviteCode,
    inviteRole: family.inviteRole || S.ROLE.VIEWER
  };

});
