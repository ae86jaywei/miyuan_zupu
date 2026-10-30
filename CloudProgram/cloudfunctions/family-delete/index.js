'use strict';
/**
 * 觅源 · 家族协作云函数：family-delete
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 解散云家族（仅谱主）。用于清理误建的空谱或彻底删除一部族谱。
 *
 * 安全约束：
 *  - 仅 OWNER 可调用；
 *  - 必须带 confirmTitle 且与谱名完全一致（防误触）；
 *  - 按对象类型逐表清空后删除 Family 行（协作 Zone 无跨表事务，采用先子表后主表顺序）。
 */
const S = require('_zupu_shared');

/** 需要清理的对象类型（顺序：先子表，后主表） */
const CHILD_TYPES = [
  S.T.MEMBER, S.T.BOOK, S.T.CHANGE_REQUEST, S.T.CHANGE_LOG, S.T.MEDIA,
  S.T.GRAVE, S.T.ACCESS_REQUEST, S.T.DIRECTORY, S.T.TEXT_SEGMENT,
  S.T_PRIVATE, S.T.MEMBERSHIP
];

/** 分页清空某类型下属于该家族的全部记录 */
async function purgeType(typeName, familyId, log) {
  let removed = 0;
  let guard = 0;
  while (guard < 200) {
    guard++;
    const rows = await S.query(typeName, [['familyId', '=', familyId]], { limit: 200 });
    if (rows.length === 0) {
      break;
    }
    await S.deleteByType(typeName, rows);
    removed += rows.length;
    if (rows.length < 200) {
      break;
    }
  }
  if (removed > 0 && log) {
    log.info('[zupu][family-delete] purged ' + typeName + ': ' + removed);
  }
  return removed;
}

module.exports.handler = S.createHandler('family-delete', async (params, event, log, context) => {

  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  if (familyId.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 familyId');
  }
  await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
  const family = await S.getFamily(familyId);

  const confirmTitle = S.str(params, 'confirmTitle');
  if (confirmTitle !== family.title) {
    throw new S.BizError(S.CODE.BAD_REQUEST,
      '请先确认删除：需提交与谱名完全一致的 confirmTitle（当前谱名：' + family.title + '）', 'confirm_mismatch');
  }

  const result = {};
  for (let i = 0; i < CHILD_TYPES.length; i++) {
    const t = CHILD_TYPES[i];
    try {
      result[t] = await purgeType(t, familyId, log);
    } catch (e) {
      // 某张表不存在或为空时不应阻断整体删除
      log.warn('[zupu][family-delete] skip ' + t + ': ' + (e && e.message));
      result[t] = 0;
    }
  }

  // 最后删主表
  try {
    await S.deleteByType(S.T.FAMILY, [family]);
  } catch (e) {
    throw new S.BizError(S.CODE.INTERNAL, '删除 Family 记录失败：' + (e && e.message), 'family_delete_failed');
  }

  return { ok: true, familyId: familyId, title: family.title, purged: result };
});
