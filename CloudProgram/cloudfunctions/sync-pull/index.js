'use strict';
/**
 * 觅源 · 家族协作云函数：sync-pull
 * 共享库见 CloudProgram/cloudfunctions/_shared（部署前复制到 node_modules/_zupu_shared）
 *
 * 这是家族内数据的**唯一读取通道**（协作 Zone 端侧无读权限，§五.9）。
 *  - sinceRev>0：增量拉取 ChangeLog（rev > sinceRev），同一对象只返回「最新快照 + 最新 rev」；
 *  - sinceRev=0：下发全量快照基线（分页 offset/limit），并带上 headRev 作为后续增量起点。
 */
const S = require('./shared');

module.exports.handler = S.createHandler('sync-pull', async (params, event, log, context) => {
  const userId = await S.requireUserId(event, params);
  const familyId = S.str(params, 'familyId');
  const membership = await S.requireMember(familyId, userId, S.ROLE.VIEWER, log);
  const family = await S.getFamily(familyId);
  const headRev = Number(family.rev || 0);
  const sinceRev = S.num(params, 'sinceRev', 0);
  const limit = Math.min(S.num(params, 'limit', 200), 1000);
  const offset = S.num(params, 'offset', 0);
  const isOwner = membership.role === S.ROLE.OWNER;

  const members = {};
  const graves = {};
  const privates = [];
  const changes = [];

  if (sinceRev <= 0) {
    // 首次同步：全量基线（分页）
    const all = await S.query(S.T.MEMBER, [['familyId', '=', familyId]], { limit: limit, offset: offset });
    all.forEach((m) => {
      members[m.memberId] = m;
    });
    const graveRows = await S.query(S.T.GRAVE, [['familyId', '=', familyId]], { limit: 1000 });
    graveRows.forEach((g) => {
      graves[g.graveId] = g;
    });
  } else {
    const logs = await S.query(S.T.CHANGE_LOG, [['familyId', '=', familyId], ['rev', '>', sinceRev]],
      { limit: limit, orderBy: [['rev', 'ASC']] });
    const latestByTarget = {};
    logs.forEach((l) => {
      const key = l.targetMemberId || '';
      if (key.length === 0) {
        return;
      }
      const prev = latestByTarget[key];
      if (!prev || Number(l.rev) > Number(prev.rev)) {
        latestByTarget[key] = l;
      }
    });
    const ids = Object.keys(latestByTarget);
    for (let i = 0; i < ids.length; i++) {
      const row = await S.queryOne(S.T.MEMBER, [['memberId', '=', ids[i]]]);
      if (row === null) {
        continue;
      }
      members[row.memberId] = row;
      const g = await S.queryOne(S.T.GRAVE, [['graveId', '=', ids[i]]]);
      if (g !== null) {
        graves[g.graveId] = g;
      }
    }
    logs.forEach((l) => {
      changes.push({
        logId: l.logId, rev: l.rev, action: l.action, targetMemberId: l.targetMemberId,
        summary: l.summary, actor: l.actor, createdAt: l.createdAt
      });
    });
  }

  // 隐私字段只回流给 OWNER（§八.6：读权限收窄到 OWNER，VIEWER/EDITOR 默认拿不到明文）
  if (isOwner) {
    const ids = Object.keys(members);
    for (let i = 0; i < ids.length; i++) {
      if (!members[ids[i]].privateRef) {
        continue;
      }
      const p = await S.queryOne(S.T.PRIVATE, [['privateId', '=', members[ids[i]].privateRef]]);
      if (p !== null) {
        privates.push(p);
      }
    }
  }

  const book = await S.queryOne(S.T.BOOK, [['bookId', '=', familyId + '#' + String(family.bookKey || 0)]]);
  const memberList = [];
  Object.keys(members).forEach((k) => memberList.push(members[k]));
  const graveList = [];
  Object.keys(graves).forEach((k) => graveList.push(graves[k]));

  return {
    familyId: familyId,
    title: family.title,
    bookKey: Number(family.bookKey || 0),
    directoryEnabled: family.directoryEnabled === true,
    role: membership.role,
    branchRootUid: membership.branchRootUid || '',
    expireAt: Number(membership.expireAt || 0),
    headRev: headRev,
    sinceRev: sinceRev,
    fullSnapshot: sinceRev <= 0,
    hasMore: (sinceRev <= 0) && (memberList.length >= limit),
    nextOffset: offset + memberList.length,
    changes: changes,
    members: memberList,
    graves: graveList,
    privates: privates,
    book: book
  };
});
