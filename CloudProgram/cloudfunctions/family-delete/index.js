'use strict';
/**
 * 觅源 · 家族协作云函数：family-delete
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 解散云家族（仅谱主）。用于清理误建的空谱或彻底删除一部族谱。
 *
 * 处理策略：
 *  - 仅 OWNER 可调用，必须带与谱名完全一致的 confirmTitle（防误触）；
 *  - 事务删除：一个 CloudDB 事务内同时删除「多张关联表」的本批记录，任一步失败整体回滚；
 *    SDK 限制单事务对象数 ≤1000，因此事务按 1000 条为一批；
 *  - 单次调用累计最多删除 5000 条（5 个事务），超过则返回 202（PARTIAL），
 *    端侧继续调用直到 200（DELETED），避免数万条数据一次提交触发网关 60 秒超时；
 *  - Family 主表与最后一批数据同事务删除；主表已删但仍有残留时，允许原谱主幂等收尾。
 */
const S = require('./shared');

/** 关联表清理顺序（先个人数据，最后主表与成员关系） */
const CHILD_TYPES = [
  S.T.MEMBER, S.T.PRIVATE, S.T.MEDIA, S.T.GRAVE, S.T.BOOK,
  S.T.TEXT_SEGMENT, S.T.DIRECTORY, S.T.CHANGE_REQUEST, S.T.CHANGE_LOG,
  S.T.ACCESS_REQUEST, S.T.MEMBERSHIP
];

/** 单页读取上限（CloudDB 上限 1000） */
const PAGE = 1000;
/** 单个事务最多删除的对象数（SDK 硬限制 1000） */
const TX_ROWS = 1000;
/** 单次调用累计删除上限：超过则分批续删，避免单次调用超时 */
const CALL_ROWS = 5000;
/** 单事务载荷上限（SDK 另有 20MB 硬限制，这里留足余量，避免长文本表撑爆事务） */
const TX_BYTES = 4 * 1024 * 1024;

module.exports.handler = S.createHandler('family-delete', async (params, event, log) => {
  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  if (familyId.length === 0) {
    throw new S.BizError(S.CODE.BAD_REQUEST, '缺少 familyId');
  }

  const family = await S.queryOne(S.T.FAMILY, [['familyId', '=', familyId]]);
  if (family !== null) {
    await S.requireMember(familyId, userId, S.ROLE.OWNER, log);
    const confirmTitle = S.str(params, 'confirmTitle');
    if (confirmTitle !== family.title) {
      throw new S.BizError(S.CODE.BAD_REQUEST,
        '请先确认删除：需提交与谱名完全一致的 confirmTitle（当前谱名：' + family.title + '）', 'confirm_mismatch');
    }
  } else {
    // 主表已删除（常见于上一轮已删完但响应超时）：只允许原谱主把残留关系清干净，
    // 且不再触碰任何家族业务数据，避免凭 familyId 猜测删除他人数据。
    const mine = await S.queryOne(S.T.MEMBERSHIP, [['familyId', '=', familyId], ['userId', '=', userId]]);
    const role = mine === null ? '' : String(mine.role || '');
    if (role !== S.ROLE.OWNER) {
      throw new S.BizError(S.CODE.NOT_FOUND, '族谱不存在或已删除', 'not_found');
    }
  }

  // 每张表各自记录是否已清空，便于分批续删
  const done = {};
  let deleted = 0;

  while (deleted < CALL_ROWS) {
    const budget = Math.min(TX_ROWS, CALL_ROWS - deleted);
    const steps = [];
    let count = 0;
    let bytes = 0;
    let truncated = false;
    for (let i = 0; i < CHILD_TYPES.length; i++) {
      const typeName = CHILD_TYPES[i];
      if (done[typeName] === true) {
        continue;
      }
      const rows = [];
      while (count < budget) {
        const page = await S.query(typeName, [['familyId', '=', familyId]], { limit: PAGE });
        if (page.length === 0) {
          done[typeName] = true;
          break;
        }
        const room = budget - count;
        const take = page.length <= room ? page : page.slice(0, room);
        const takeBytes = JSON.stringify(take).length;
        if (count > 0 && bytes + takeBytes > TX_BYTES) {
          // 载荷过大（如长文本段），留给下一批事务，避免事务数据超限
          truncated = true;
          break;
        }
        for (let k = 0; k < take.length; k++) {
          rows.push(take[k]);
        }
        count += take.length;
        bytes += takeBytes;
        if (take.length < page.length) {
          // 本批已满，剩余记录留给下一批事务
          truncated = true;
          break;
        }
        if (page.length < PAGE) {
          done[typeName] = true;
          break;
        }
      }
      if (rows.length > 0) {
        steps.push({ type: typeName, rows: rows });
      }
      if (truncated || count >= budget) {
        break;
      }
    }

    let finished = true;
    for (let i = 0; i < CHILD_TYPES.length; i++) {
      if (done[CHILD_TYPES[i]] !== true) {
        finished = false;
        break;
      }
    }
    // 关联表已清空：本批同时删除 Family 主表（同一事务，作为整体提交点）
    if (finished && family !== null) {
      steps.push({ type: S.T.FAMILY, rows: [family] });
    }

    if (steps.length === 0) {
      return { status: 'DELETED', familyId: familyId, deleted: deleted };
    }

    let n = 0;
    try {
      n = await S.deleteInTransaction(steps);
    } catch (e) {
      log.error('[zupu][family-delete] tx failed: ' + (e && e.message));
      throw new S.BizError(S.CODE.INTERNAL, '删除事务失败，已回滚，请重试', 'tx_failed');
    }
    deleted += n;

    if (finished) {
      log.info('[zupu][family-delete] done ' + familyId + ', deleted ' + deleted);
      return { status: 'DELETED', familyId: familyId, deleted: deleted, alreadyGone: family === null };
    }
  }

  // 明确告知端侧「已受理但未完成」，由端侧继续调用直至 DELETED
  throw new S.BizError(S.CODE.PARTIAL,
    '删除进行中（本次已删除 ' + deleted + ' 条），请继续', 'partial');
});
