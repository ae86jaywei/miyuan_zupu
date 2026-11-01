'use strict';
/**
 * 觅源 · 家族协作云函数：directory-search
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 黄页搜索（§五.11）。
 * 注意：**不是权限所必需**（黄页端侧可直读），只为服务端侧前缀匹配/聚合/排序而设。
 * 仍需登录，但**不做 Membership 校验**；返回值只能是黄页字段，绝不含人物数据。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('directory-search', async (params, event, log, context) => {

  await S.requireUserId(event, params);
  const keyword = S.str(params, 'keyword').toLowerCase();
  const limit = Math.min(S.num(params, 'limit', 50), 100);
  const offset = S.num(params, 'offset', 0);

  const rows = await S.query(S.T.DIRECTORY, [], { limit: 500, orderBy: [['updatedAt', 'DESC']] });
  const hit = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (keyword.length === 0
      || String(r.title || '').toLowerCase().indexOf(keyword) >= 0
      || String(r.surname || '').toLowerCase().indexOf(keyword) >= 0
      || String(r.region || '').toLowerCase().indexOf(keyword) >= 0) {
      hit.push(r);
    }
  }
  const page = hit.slice(offset, offset + limit).map((r) => ({
    dirId: r.dirId,
    familyId: r.familyId,
    surname: r.surname,
    region: r.region,
    title: r.title,
    branchSummary: r.branchSummary,
    memberCountBand: r.memberCountBand,
    coverRef: r.coverRef,
    accessHint: r.accessHint,
    updatedAt: r.updatedAt
  }));
  return { dirs: page, total: hit.length, nextCursor: offset + page.length };

});
