'use strict';
/**
 * 觅源 · 家族协作云函数：family-private-get
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('family-private-get', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  // §八.6：活人隐私字段的读权限收窄到 OWNER（必要时可在此加分支管理员）
  await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
  const uid = S.normUid(S.str(params, 'uid'));
  const rows = uid.length > 0
    ? await S.query(S.T.PRIVATE, [['familyId', '=', familyId], ['uid', '=', uid]], { limit: 1 })
    : await S.query(S.T.PRIVATE, [['familyId', '=', familyId]], { limit: 500 });
  return { privates: rows };

});
