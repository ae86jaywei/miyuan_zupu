'use strict';
/**
 * 觅源 · 家族协作云函数：family-delete
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 解散云家族（仅谱主）。用于清理误建的空谱或彻底删除一部族谱。
 *
 * 处理策略（修复「删除不干净、删后还能从云端导入、人员被拆成几百支」）：
 *  - 仅 OWNER 可调用，必须带与谱名完全一致的 confirmTitle（防误触）；
 *  - **按对象主键排序分页**逐表删除，每批删除后立即复查，避免分页漂移与「假删」（无删除权限时静默成功）；
 *  - 每张表删到「查询为空」才算清空；**所有子表复核为空之前，绝不删除 Family 主表**，
 *    保证不会出现「主表已删、族人残留」的半成品状态；
 *  - Family 主表最后删除；**Membership 放到主表之后删**，这样即使主表删除后仍有并发写入的残留，
 *    原谱主下次调用仍可凭 Membership 续删收尾；
 *  - 返回 DELETED 前做最终全表复核，任何残留都返回 202（PARTIAL），绝不误报「删除成功」；
 *  - 单次调用受条数/时间预算约束，超出返回 202，由端侧继续调用直至 DELETED。
 */
const S = require('./shared');

/** 关联表清理顺序（先删谱书，再删个人数据） */
/**
 * 关联表清理顺序：**先删 FamilyBook（谱书）**，再删个人数据。
 *
 * FamilyBook 是否存在是端侧「导入本机」的完整性开关（sync-pull 返回 hasBook）。
 * 一旦开始删除就把谱书删掉，任何中途中断都会让后续导入被拒绝，
 * 避免「族人删了一半、谱书还在」时被重新导入成几百个断裂分支。
 */
const CHILD_TYPES = [
  S.T.BOOK, S.T.MEMBER, S.T.PRIVATE, S.T.MEDIA, S.T.GRAVE, S.T.TEXT_SEGMENT,
  S.T.DIRECTORY, S.T.CHANGE_REQUEST, S.T.CHANGE_LOG, S.T.ACCESS_REQUEST
];

/** 单次 delete 提交的对象数（CloudDB 单次写入/删除上限内留足余量） */
const DELETE_CHUNK = 500;
/** 单次调用累计删除上限：超过则返回 202，由端侧续删，避免单次调用超时 */
const CALL_ROWS = 20000;
/** 单次调用的时间预算（函数超时 600s，端侧等待 590s，这里留足余量） */
const CALL_MS = 7 * 60 * 1000;

/** 各对象类型主键（用于稳定分页与删除后复查） */
let PK_META = null;
function pkOf(typeName) {
  if (PK_META === null) {
    try {
      PK_META = require('./shared/schema-meta.json');
    } catch (e) {
      PK_META = {};
    }
  }
  const info = PK_META[typeName];
  if (info === undefined || info === null || typeof info.primaryKey !== 'string') {
    return '';
  }
  return info.primaryKey;
}

/**
 * 清空某张表下属于该家族的全部记录。
 * 每批按主键升序取前 N 条删除；删除后复查，确认记录真的消失（防止权限缺失导致的静默假删）。
 * @returns {Promise<{deleted: number, empty: boolean}>}
 */
async function purgeType(typeName, familyId, budget, deadline, log) {
  const pk = pkOf(typeName);
  const orderBy = pk.length > 0 ? [[pk, 'ASC']] : [];
  let deleted = 0;
  let probed = false;
  while (deleted < budget && Date.now() < deadline) {
    const take = Math.min(DELETE_CHUNK, budget - deleted);
    const rows = await S.query(typeName, [['familyId', '=', familyId]], {
      limit: take, orderBy: orderBy
    });
    if (rows.length === 0) {
      return { deleted: deleted, empty: true };
    }
    const removedPk = {};
    if (!probed && pk.length > 0) {
      for (let i = 0; i < rows.length; i++) {
        removedPk[String(rows[i][pk] === undefined ? '' : rows[i][pk])] = true;
      }
    }
    await S.deleteByType(typeName, rows);
    deleted += rows.length;
    // 首批删除后抽查：若仍能读到刚删的主键，说明删除没有真正生效（如管理员 Delete 权限未勾选），
    // 必须立刻失败而不是继续空转、把「没删掉」当成「删完了」。
    if (!probed && pk.length > 0) {
      probed = true;
      const rest = await S.query(typeName, [['familyId', '=', familyId]], {
        limit: 1, orderBy: orderBy
      });
      if (rest.length > 0 && removedPk[String(rest[0][pk] === undefined ? '' : rest[0][pk])] === true) {
        throw new S.BizError(S.CODE.INTERNAL,
          '删除未生效：' + typeName + ' 记录删除后仍可读取，请确认该对象类型的「管理员 Delete」权限已勾选',
          'delete_not_effective');
      }
    }
    if (rows.length < take) {
      // 本页不足一页，理论上已是最后一批，再查一次确认是否清空
      const rest = await S.query(typeName, [['familyId', '=', familyId]], { limit: 1 });
      if (rest.length === 0) {
        return { deleted: deleted, empty: true };
      }
    }
  }
  const left = await S.query(typeName, [['familyId', '=', familyId]], { limit: 1 });
  return { deleted: deleted, empty: left.length === 0 };
}

/** 查一遍所有子表，返回仍有记录的表名 */
async function residualTypes(familyId) {
  const out = [];
  for (let i = 0; i < CHILD_TYPES.length; i++) {
    const typeName = CHILD_TYPES[i];
    const left = await S.query(typeName, [['familyId', '=', familyId]], { limit: 1 });
    if (left.length > 0) {
      out.push(typeName);
    }
  }
  return out;
}

/**
 * 清理成员关系，但把调用者自己的 OWNER 行留到最后几分钟再删。
 * 该行是「主表已删除、子表仍有残留」时唯一能继续鉴权的凭据，
 * 若随大流一起删掉，残留在下次调用时会被 404 挡住、永远清不掉。
 * @returns {Promise<{deleted: number, empty: boolean}>} empty=false 表示还剩 keeper 或其他残留
 */
async function purgeMemberships(familyId, keepUserId, deadline) {
  let deleted = 0;
  const orderBy = [['membershipId', 'ASC']];
  while (Date.now() < deadline) {
    const rows = await S.query(S.T.MEMBERSHIP, [['familyId', '=', familyId]], {
      limit: DELETE_CHUNK, orderBy: orderBy
    });
    if (rows.length === 0) {
      return { deleted: deleted, empty: true };
    }
    const batch = [];
    for (let i = 0; i < rows.length; i++) {
      const owner = String(rows[i].userId === undefined ? '' : rows[i].userId);
      if (owner !== keepUserId) {
        batch.push(rows[i]);
      }
    }
    if (batch.length === 0) {
      // 只剩调用者自己的成员关系，交给主流程最后删除
      return { deleted: deleted, empty: false };
    }
    const sample = String(batch[0].membershipId === undefined ? '' : batch[0].membershipId);
    await S.deleteByType(S.T.MEMBERSHIP, batch);
    deleted += batch.length;
    const probe = await S.query(S.T.MEMBERSHIP, [
      ['familyId', '=', familyId], ['membershipId', '=', sample]
    ], { limit: 1 });
    if (probe.length > 0) {
      throw new S.BizError(S.CODE.INTERNAL,
        '删除未生效：Membership 记录删除后仍可读取，请确认该对象类型的「管理员 Delete」权限已勾选',
        'delete_not_effective');
    }
  }
  return { deleted: deleted, empty: false };
}

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
    // 主表已删除：只允许原谱主继续把残留清干净。
    // 注意 Membership 被安排在 Family 之后删除，正常流程下这里仍能凭 OWNER 关系续删；
    // 若成员关系也已清空，说明该谱早已删净，返回 404 让端侧结束轮询。
    const mine = await S.queryOne(S.T.MEMBERSHIP, [['familyId', '=', familyId], ['userId', '=', userId]]);
    const role = mine === null ? '' : String(mine.role || '');
    if (role !== S.ROLE.OWNER) {
      throw new S.BizError(S.CODE.NOT_FOUND, '族谱不存在或已删除', 'not_found');
    }
  }

  const deadline = Date.now() + CALL_MS;
  const removed = {};
  let deleted = 0;

  // 阶段一：逐表清空（不含主表与成员关系）
  for (let i = 0; i < CHILD_TYPES.length; i++) {
    if (Date.now() >= deadline || deleted >= CALL_ROWS) {
      break;
    }
    const typeName = CHILD_TYPES[i];
    const r = await purgeType(typeName, familyId, CALL_ROWS - deleted, deadline, log);
    if (r.deleted > 0) {
      removed[typeName] = r.deleted;
      deleted += r.deleted;
    }
  }

  // 阶段二：复核所有子表；有任何残留都不允许删主表，返回 202 让端侧继续
  const residual = await residualTypes(familyId);
  if (residual.length > 0) {
    log.info('[zupu][family-delete] partial ' + familyId + ', deleted ' + deleted +
      ', residual=' + residual.join(','));
    throw new S.BizError(S.CODE.PARTIAL,
      '删除进行中（本次已删除 ' + deleted + ' 条，仍有残留：' + residual.join('、') + '），请继续', 'partial');
  }

  // 阶段三：子表确认全空后才删主表（主表是「是否还能导入」的唯一开关）
  if (family !== null) {
    await S.deleteByType(S.T.FAMILY, [family]);
    const still = await S.queryOne(S.T.FAMILY, [['familyId', '=', familyId]]);
    if (still !== null) {
      throw new S.BizError(S.CODE.INTERNAL,
        '主表删除失败：Family 记录仍存在，请确认 Family 对象的「管理员 Delete」权限已勾选', 'delete_not_effective');
    }
  }

  // 阶段四：主表删除后再复核一次，兜住删除期间并发写入的数据
  const afterMain = await residualTypes(familyId);
  if (afterMain.length > 0) {
    log.warn('[zupu][family-delete] ' + familyId + ' main deleted but residual=' + afterMain.join(','));
    throw new S.BizError(S.CODE.PARTIAL,
      '主表已删除，但仍有 ' + afterMain.join('、') + ' 残留记录，请继续调用以清理', 'partial');
  }

  // 阶段五：最后删除成员关系。调用者自己的 OWNER 行留到确认其他成员都删完再删：
  // 正常情况下这一步能一次删净；若中途超时，下一轮仍可凭它继续收尾。
  const mem = await purgeMemberships(familyId, userId, deadline);
  deleted += mem.deleted;
  const others = await S.query(S.T.MEMBERSHIP, [['familyId', '=', familyId]], { limit: DELETE_CHUNK });
  let otherLeft = 0;
  for (let i = 0; i < others.length; i++) {
    const owner = String(others[i].userId === undefined ? '' : others[i].userId);
    if (owner !== userId) {
      otherLeft++;
    }
  }
  if (otherLeft > 0) {
    throw new S.BizError(S.CODE.PARTIAL,
      '仅剩成员关系未清空（本次已删除 ' + deleted + ' 条），请继续', 'partial');
  }
  const keeper = await S.queryOne(S.T.MEMBERSHIP, [['familyId', '=', familyId], ['userId', '=', userId]]);
  if (keeper !== null) {
    await S.deleteByType(S.T.MEMBERSHIP, [keeper]);
    deleted++;
  }
  const memFinal = await S.query(S.T.MEMBERSHIP, [['familyId', '=', familyId]], { limit: 1 });
  if (memFinal.length > 0) {
    throw new S.BizError(S.CODE.PARTIAL,
      '成员关系仍有残留（本次已删除 ' + deleted + ' 条），请继续', 'partial');
  }

  log.info('[zupu][family-delete] done ' + familyId + ', deleted ' + deleted);
  return {
    status: 'DELETED',
    familyId: familyId,
    deleted: deleted,
    alreadyGone: family === null,
    removed: removed
  };
});