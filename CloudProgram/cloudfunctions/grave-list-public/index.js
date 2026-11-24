'use strict';
/**
 * 觅源 · 家族协作云函数：grave-list-public
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 祭祖寻墓的**唯一读取入口**：必须已加入该家族（Membership 有效）才能查询本家族墓葬。
 * 对象类型 FamilyGraveLocation 不对端侧开放直读，避免绕过成员校验。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('grave-list-public', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  // 未加入家族 → FORBIDDEN（not_member），端侧据此提示先加入家族
  await S.requireMember(familyId, userId, S.ROLE.VIEWER, log);
  const keyword = S.str(params, 'keyword');
  const limit = Math.min(S.num(params, 'limit', 100), 200);
  const offset = S.num(params, 'offset', 0);
  const conds = [['familyId', '=', familyId], ['visibility', '=', 'PUBLIC']];
  const rows = await S.query(S.T.GRAVE, conds, { limit: 200, orderBy: [['updatedAt', 'DESC']] });
  const filtered = keyword.length === 0 ? rows : rows.filter((r) =>
    String(r.personName || '').indexOf(keyword) >= 0 ||
    String(r.bookTitle || '').indexOf(keyword) >= 0 ||
    String(r.graveName || '').indexOf(keyword) >= 0 ||
    String(r.routeNote || '').indexOf(keyword) >= 0);
  const page = filtered.slice(offset, offset + limit);
  return { graves: page, total: filtered.length, nextCursor: offset + page.length };

});
