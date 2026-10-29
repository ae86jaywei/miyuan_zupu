'use strict';

/**
 * 家族级 rev 分配（§六 说明 2 / §十一 W6）。
 *
 * 官方未见「条件写 / 字段级原子自增」，因此这里采用方案 §六 说明 2 的三条应对：
 *  1. rev 分配全部收敛到本模块（所有写路径都经过它），减少并发窗口；
 *  2. 若云侧支持 CAS（readRev + 条件更新），通过 env REV_CAS_ENABLED=1 打开；
 *  3. 兜底：宽松单调 —— 允许跳号/重复，仅作「变更游标」使用；
 *     ChangeLog.logId 采用 {familyId}#{rev}#{seq}，避免同 rev 多变更撞主键（§五.6）。
 *
 * 返回 { rev, family, changes }，changes 由调用方填充后统一提交。
 */

const { BizError, CODE, nowMs } = require('./core');
const { T } = require('./constants');
const db = require('./db');

let seqCounter = 0;

/** 生成同 rev 内唯一的序号（进程内单调 + 时间戳后缀，跨实例不撞的概率足够低） */
function nextSeq() {
  seqCounter = (seqCounter + 1) % 1000;
  return String(nowMs()) + String(seqCounter).padStart(3, '0');
}

function changeLogId(familyId, rev) {
  return familyId + '#' + rev + '#' + nextSeq();
}

/**
 * 分配一个新的家族 rev。
 * 读 Family → rev+1 → 写回；写回后回读确认（尽力而为的 CAS）。
 * @param {object} family Family 行
 * @param {number} retries 冲突重试次数
 */
async function allocate(family, retries, logger) {
  const max = retries === undefined ? 2 : retries;
  for (let attempt = 0; attempt <= max; attempt++) {
    const current = await db.getById(T.FAMILY, 'familyId', family.familyId);
    if (current === null) {
      throw new BizError(CODE.NOT_FOUND, '族谱不存在或已删除');
    }
    const nextRev = Number(current.rev || 0) + 1;
    current.rev = nextRev;
    current.updatedAt = nowMs();
    await db.upsertOne(T.FAMILY, Object.assign({}, current));
    if (process.env.REV_CAS_ENABLED !== '1') {
      return { rev: nextRev, family: current };
    }
    const check = await db.getById(T.FAMILY, 'familyId', family.familyId);
    if (check !== null && Number(check.rev || 0) === nextRev) {
      return { rev: nextRev, family: current };
    }
    if (logger) {
      logger.warn('[zupu][rev] CAS conflict, retry ' + attempt);
    }
  }
  // 兜底：宽松单调，返回最后一次读到的 rev（允许重复）
  const last = await db.getById(T.FAMILY, 'familyId', family.familyId);
  return { rev: Number((last && last.rev) || 0), family: last || family };
}

/**
 * 构造一条 ChangeLog 行。
 * @param {object} p { familyId, rev, actor, action, targetMemberId, summary, payload }
 */
function changeLogRow(p) {
  return {
    logId: changeLogId(p.familyId, p.rev),
    familyId: p.familyId,
    rev: p.rev,
    actor: p.actor || '',
    action: p.action || 'UPDATE',
    targetMemberId: p.targetMemberId || '',
    summary: p.summary || '',
    payload: typeof p.payload === 'string' ? p.payload : JSON.stringify(p.payload || {}),
    createdAt: nowMs()
  };
}

module.exports = { allocate, changeLogRow, changeLogId, nextSeq };
