'use strict';
/**
 * 觅源 · 家族协作云函数：media-list
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('media-list', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  await S.requireMember(familyId, userId, S.ROLE.VIEWER, log);
  const rows = await S.query(S.T.MEDIA, [['familyId', '=', familyId], ['deleted', '=', false]], { limit: 1000 });
  return { media: rows };

});
