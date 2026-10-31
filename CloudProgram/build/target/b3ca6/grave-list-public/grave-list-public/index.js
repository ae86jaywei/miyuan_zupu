'use strict';
/**
 * 觅源 · 家族协作云函数：grave-list-public
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 */
const S = require('_zupu_shared');

module.exports.handler = S.createHandler('grave-list-public', async (params, event, log, context) => {

  // 注意：本函数不是权限所必需（公开表端侧可直读），只为「按关键字搜祖墓」提供聚合/排序。
  await S.requireUserId(event, params);
  const keyword = S.str(params, 'keyword');
  const limit = Math.min(S.num(params, 'limit', 100), 200);
  const offset = S.num(params, 'offset', 0);
  const conds = [['visibility', '=', 'PUBLIC']];
  const rows = await S.query(S.T.GRAVE, conds, { limit: 200, orderBy: [['updatedAt', 'DESC']] });
  const filtered = keyword.length === 0 ? rows : rows.filter((r) =>
    String(r.personName || '').indexOf(keyword) >= 0 ||
    String(r.bookTitle || '').indexOf(keyword) >= 0 ||
    String(r.graveName || '').indexOf(keyword) >= 0);
  const page = filtered.slice(offset, offset + limit);
  return { graves: page, total: filtered.length, nextCursor: offset + page.length };

});
