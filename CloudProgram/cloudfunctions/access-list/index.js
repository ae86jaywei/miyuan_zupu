'use strict';
/**
 * 觅源 · 家族协作云函数：access-list
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 访问申请列表（§十三）。
 *  - mode=mine ：我提交过的全部申请（任意登录用户）；
 *  - mode=inbox：谱主待审列表（仅 OWNER）。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('access-list', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  const mode = S.str(params, 'mode', 'inbox');

  if (mode === 'mine') {
    const rows = await S.query(S.T.ACCESS_REQUEST, [['applicantId', '=', userId]],
      { limit: 100, orderBy: [['createdAt', 'DESC']] });
    const out = [];
    for (let i = 0; i < rows.length; i++) {
      const item = Object.assign({}, rows[i]);
      const family = await S.queryOne(S.T.FAMILY, [['familyId', '=', item.familyId]]);
      item.familyTitle = family !== null ? String(family.title || '') : '';
      out.push(item);
    }
    return { requests: out };
  }

  await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
  const status = S.str(params, 'status', S.ACCESS_STATUS.PENDING);
  const conds = [['familyId', '=', familyId]];
  if (status !== 'ALL') {
    conds.push(['status', '=', status]);
  }
  const rows = await S.query(S.T.ACCESS_REQUEST, conds, { limit: 200, orderBy: [['createdAt', 'ASC']] });
  return { requests: rows };

});
