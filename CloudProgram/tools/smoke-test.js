'use strict';
/**
 * 本地端到端冒烟测试：用内存版 CloudDB 假 SDK 跑通真实云函数 handler。
 * 目的：在不上真机的前提下，验证参数解析、鉴权、rev 分配、写表、读表、审核合入。
 */
const fs = require('fs');
const path = require('path');
const Module = require('module');

const ROOT = path.resolve(__dirname, '..');  // CloudProgram/
const FN_DIR = path.join(ROOT, 'cloudfunctions');

// ---- 1. 读取云端表定义，得到每个类型的主键字段 ----
const PK = {};
for (const f of fs.readdirSync(path.join(ROOT, 'clouddb/objecttype'))) {
  const j = JSON.parse(fs.readFileSync(path.join(ROOT, 'clouddb/objecttype', f), 'utf8'));
  const pk = j.fields.find(x => x.belongPrimaryKey);
  if (pk) PK[j.objectTypeName] = pk.fieldName;
}

// ---- 2. 内存存储 ----
const store = {};
function table(name) {
  if (!store[name]) store[name] = new Map();
  return store[name];
}

// ---- 3. 假 SDK ----
function makeQuery(name) {
  const conds = [];
  let limitN = 200, offsetN = 0;
  const orders = [];
  const q = {
    equalTo(f, v) { conds.push(['=', f, v]); return q; },
    notEqualTo(f, v) { conds.push(['!=', f, v]); return q; },
    greaterThan(f, v) { conds.push(['>', f, v]); return q; },
    lessThan(f, v) { conds.push(['<', f, v]); return q; },
    greaterThanOrEqualTo(f, v) { conds.push(['>=', f, v]); return q; },
    lessThanOrEqualTo(f, v) { conds.push(['<=', f, v]); return q; },
    in(f, arr) { conds.push(['in', f, arr]); return q; },
    isNull(f) { conds.push(['null', f]); return q; },
    and() { return q; },
    or() { return q; },
    orderByAsc(f) { orders.push([f, 1]); return q; },
    orderByDesc(f) { orders.push([f, -1]); return q; },
    limit(n, o) { limitN = n; offsetN = o || 0; return q; },
    async get() {
      let rows = [...table(name).values()];
      rows = rows.filter(r => conds.every(c => {
        const v = r[c[1]];
        switch (c[0]) {
          case '=': return String(v) === String(c[2]);
          case '!=': return String(v) !== String(c[2]);
          case '>': return Number(v) > Number(c[2]);
          case '<': return Number(v) < Number(c[2]);
          case '>=': return Number(v) >= Number(c[2]);
          case '<=': return Number(v) <= Number(c[2]);
          case 'in': return (c[2] || []).map(String).includes(String(v));
          case 'null': return v === undefined || v === null || v === '';
          default: return true;
        }
      }));
      for (let i = orders.length - 1; i >= 0; i--) {
        const [f, dir] = orders[i];
        rows.sort((a, b) => (a[f] === b[f] ? 0 : ((a[f] < b[f] ? -1 : 1) * dir)));
      }
      return rows.slice(offsetN, offsetN + limitN).map(r => JSON.parse(JSON.stringify(r)));
    },
    async countQuery() {
      return (await q.get()).length;
    }
  };
  return q;
}

const fakeCloud = {
  database(cfg) {
    if (!cfg || !cfg.zoneName) throw new Error('zoneName required');
    return {
      collection(name) {
        return {
          query() { return makeQuery(name); },
          async insert(rows) {
            const list = Array.isArray(rows) ? rows : [rows];
            for (const r of list) table(name).set(String(r[PK[name]]), JSON.parse(JSON.stringify(r)));
            return list.length;
          },
          async upsert(rows) {
            const list = Array.isArray(rows) ? rows : [rows];
            for (const r of list) {
              const k = String(r[PK[name]]);
              const old = table(name).get(k) || {};
              table(name).set(k, Object.assign({}, old, JSON.parse(JSON.stringify(r))));
            }
            return list.length;
          },
          async delete(rows) {
            const list = Array.isArray(rows) ? rows : [rows];
            for (const r of list) table(name).delete(String(r[PK[name]]));
            return list.length;
          }
        };
      }
    };
  }
};

// ---- 4. 注入假 SDK ----
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === '@hw-agconnect/cloud-server') return 'FAKE_AGC';
  return origResolve.call(this, request, ...rest);
};
require.cache['FAKE_AGC'] = { id: 'FAKE_AGC', filename: 'FAKE_AGC', loaded: true, exports: { cloud: fakeCloud } };

// ---- 5. 载入函数 ----
function loadFn(name) {
  const modPath = path.join(FN_DIR, name, 'index.js');
  const localRequire = Module.createRequire(modPath);
  // 让函数能 require('_zupu_shared')
  const sharedPath = path.join(FN_DIR, name, 'node_modules', '_zupu_shared', 'index.js');
  return { handlerPath: modPath, sharedPath };
}

// 把 _zupu_shared 也接到假 SDK 上：直接改为从 _shared 目录加载（同一模块实例）
const sharedDir = path.join(FN_DIR, '_shared');
const origResolve2 = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === '_zupu_shared') return path.join(sharedDir, 'index.js');
  return origResolve2.call(this, request, ...rest);
};

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log((ok ? '  OK   ' : '  FAIL ') + name + (detail ? '  -> ' + String(detail).slice(0, 110) : ''));
}

function mkEvent(data, uid) {
  // 模拟「网关注入身份 + body 为 JSON 串」的真实形态
  return { headers: { 'x-user-id': uid }, body: JSON.stringify(data) };
}

(async () => {
  const S = require(path.join(sharedDir, 'index.js'));
  const owner = 'u-owner';
  const other = 'u-other';

  // 1) family-create
  const create = require(path.join(FN_DIR, 'family-create', 'index.js')).handler;
  const r1 = await create(mkEvent({ title: '韦氏宗谱', nickName: '谱主' }, owner), {}, () => {}, console);
  check('family-create 返回 200', r1 && r1.code === 200, JSON.stringify(r1 && r1.data));
  const familyId = r1.data.familyId;
  const inviteCode = r1.data.inviteCode;
  check('family-create 生成了 familyId/inviteCode', !!familyId && !!inviteCode, familyId + ' / ' + inviteCode);

  // 2) 断言三张表都写了
  check('Family 已写入', table('Family').size === 1);
  check('Membership 已写入(OWNER)', table('Membership').size === 1 &&
    table('Membership').get(familyId + '#' + owner).role === 'OWNER');
  check('FamilyBook 已写入', table('FamilyBook').size === 1);

  // 3) family-list-mine
  const listMine = require(path.join(FN_DIR, 'family-list-mine', 'index.js')).handler;
  const r2 = await listMine(mkEvent({}, owner), {}, () => {}, console);
  check('family-list-mine 返回 200', r2 && r2.code === 200);
  check('我的家族有 1 条', r2.data && r2.data.families && r2.data.families.length === 1,
    JSON.stringify(r2.data && r2.data.families));

  // 4) 非成员读 sync-pull 应 403
  const syncPull = require(path.join(FN_DIR, 'sync-pull', 'index.js')).handler;
  const r3 = await syncPull(mkEvent({ familyId: familyId }, other), {}, () => {}, console);
  check('非成员 sync-pull 被拒(403)', r3 && r3.code === 403, r3 && r3.message);

  // 5) family-join 用加入码加入
  const join = require(path.join(FN_DIR, 'family-join', 'index.js')).handler;
  const r4 = await join(mkEvent({ inviteCode: inviteCode, nickName: '亲戚' }, other), {}, () => {}, console);
  check('family-join 成功', r4 && r4.code === 200, JSON.stringify(r4 && (r4.data || r4.message)));

  // 6) 成员 sync-pull 全量
  const r5 = await syncPull(mkEvent({ familyId: familyId, sinceRev: 0 }, other), {}, () => {}, console);
  check('成员 sync-pull 成功', r5 && r5.code === 200, JSON.stringify(r5 && (r5.data ? Object.keys(r5.data) : r5.message)));

  // 7) family-bootstrap 发布一族
  const boot = require(path.join(FN_DIR, 'family-bootstrap', 'index.js')).handler;
  const r6 = await boot(mkEvent({
    familyId: familyId, bookKey: 0, book: { title: '韦氏宗谱' },
    persons: [{ uid: 'F001', name: '韦道像', generation: 1, gender: '男' },
             { uid: 'F002', name: '韦德坤', generation: 2, fatherId: 'F001', gender: '男' }]
  }, owner), {}, () => {}, console);
  check('family-bootstrap 成功', r6 && r6.code === 200, JSON.stringify(r6 && (r6.data || r6.message)));
  check('FamilyMember 写入 2 人', table('FamilyMember').size === 2, '实际 ' + table('FamilyMember').size);

  // 8) 再次 sync-pull 应能拿到 2 个成员
  const r7 = await syncPull(mkEvent({ familyId: familyId, sinceRev: 0 }, owner), {}, () => {}, console);
  const memberCount = r7.data && r7.data.members ? Object.keys(r7.data.members).length : 0;
  check('sync-pull 取到 2 个成员', memberCount === 2, '实际 ' + memberCount);

  // 9) 编辑者改一个人（直接写）
  const directWrite = require(path.join(FN_DIR, 'member-direct-write', 'index.js')).handler;
  const patch = JSON.stringify({ name: { b: '韦道像', a: '韦道像公' } });
  const r8 = await directWrite(mkEvent({
    familyId: familyId, op: 'UPDATE', uid: 'F001', patchJson: patch, baseRev: 0
  }, owner), {}, () => {}, console);
  check('member-direct-write 成功', r8 && r8.code === 200, JSON.stringify(r8 && (r8.data || r8.message)));
  const mrow = table('FamilyMember').get(familyId + '#F001');
  check('FamilyMember.payload 已更新', mrow && String(mrow.payload || '').includes('韦道像公'));
  check('ChangeLog 有记录', table('ChangeLog').size > 0, '条数 ' + table('ChangeLog').size);

  // 9.1) 谱主新增一个云端不存在的族人（op=ADD 必须能建档，否则端侧会一直报「族人不存在」）
  const addPatch = JSON.stringify({
    name: { b: null, a: '韦德明' }, generation: { b: null, a: 3 }, fatherId: { b: null, a: 'F002' }
  });
  const r8b = await directWrite(mkEvent({
    familyId: familyId, op: 'ADD', uid: 'F003', patchJson: addPatch, baseRev: 0
  }, owner), {}, () => {}, console);
  check('member-direct-write 新增族人成功', r8b && r8b.code === 200, JSON.stringify(r8b && (r8b.data || r8b.message)));
  const addRow = table('FamilyMember').get(familyId + '#F003');
  check('新增族人已建档', addRow && String(addRow.payload || '').includes('韦德明') && addRow.deleted !== true,
    addRow ? addRow.name : 'none');

  // 10) 谱主改黄页
  const dirUp = require(path.join(FN_DIR, 'directory-upsert', 'index.js')).handler;
  const r9 = await dirUp(mkEvent({
    familyId: familyId, directoryEnabled: true, surname: '韦', region: '广西', title: '韦氏宗谱',
    memberCountBand: '0-50', accessHint: '需谱主审核'
  }, owner), {}, () => {}, console);
  check('directory-upsert 上架成功', r9 && r9.code === 200, JSON.stringify(r9 && (r9.data || r9.message)));
  check('FamilyDirectory 已写入', table('FamilyDirectory').size === 1);

  // 11) 下架 = 物理删除
  const r10 = await dirUp(mkEvent({ familyId: familyId, directoryEnabled: false }, owner), {}, () => {}, console);
  check('directory-upsert 下架成功', r10 && r10.code === 200);
  check('FamilyDirectory 已删除(0 行)', table('FamilyDirectory').size === 0, '实际 ' + table('FamilyDirectory').size);

  // 12) family-private-get 仅 OWNER
  const privGet = require(path.join(FN_DIR, 'family-private-get', 'index.js')).handler;
  const r11 = await privGet(mkEvent({ familyId: familyId }, other), {}, () => {}, console);
  check('非谱主 family-private-get 被拒', r11 && (r11.code === 403 || r11.code === 404),
    r11 && (r11.message || ''));


  // ---- 13) 成员管理：把 other 提升为 EDITOR ----
  const aclSet = require(path.join(FN_DIR, 'family-acl-set', 'index.js')).handler;
  const r12 = await aclSet(mkEvent({ familyId: familyId, action: 'UPDATE', targetUserId: other, role: 'EDITOR', branchRootUid: '', expireAt: 0, status: 'ACTIVE' }, owner), {}, () => {}, console);
  check('family-acl-set 升为编辑者', r12 && r12.code === 200, JSON.stringify(r12 && (r12.data || r12.message)));

  const aclList = require(path.join(FN_DIR, 'family-acl-list', 'index.js')).handler;
  const r13 = await aclList(mkEvent({ familyId: familyId }, owner), {}, () => {}, console);
  const membersLen = r13 && r13.data && r13.data.memberships ? r13.data.memberships.length : -1;
  check('family-acl-list 有 2 名成员', membersLen === 2, '实际 ' + membersLen);

  // ---- 14) 编辑者提交变更（待审核）----
  const submit = require(path.join(FN_DIR, 'change-submit', 'index.js')).handler;
  const r14 = await submit(mkEvent({
    familyId: familyId, op: 'UPDATE', targetUid: 'F002',
    patchJson: JSON.stringify({ alias: { b: '', a: '德坤公' } }),
    baseRev: 0, evidence: '族谱手抄本第 3 页'
  }, other), {}, () => {}, console);
  check('change-submit 成功(编辑者)', r14 && r14.code === 200, JSON.stringify(r14 && (r14.data || r14.message)));
  const reqId = r14 && r14.data ? r14.data.requestId : '';

  // ---- 15) 谱主看到待审 ----
  const listPending = require(path.join(FN_DIR, 'change-list-pending', 'index.js')).handler;
  const r15 = await listPending(mkEvent({ familyId: familyId }, owner), {}, () => {}, console);
  const pendLen = r15 && r15.data && r15.data.requests ? r15.data.requests.length : -1;
  check('change-list-pending 有 1 条', pendLen === 1, '实际 ' + pendLen);

  // ---- 16) 谱主审核通过 ----
  const review = require(path.join(FN_DIR, 'change-review', 'index.js')).handler;
  const r16 = await review(mkEvent({ requestId: reqId, decision: 'APPROVED', note: '通过' }, owner), {}, () => {}, console);
  check('change-review 通过', r16 && r16.code === 200, JSON.stringify(r16 && (r16.data || r16.message)));
  const f2 = table('FamilyMember').get(familyId + '#F002');
  check('变更已合入(alias=德坤公)', f2 && String(f2.payload || '').includes('德坤公'), String(f2 && f2.payload).slice(0, 80));

  // ---- 17) 访问申请 → 审批 → 新成员可见 ----
  const accessReq = require(path.join(FN_DIR, 'access-request', 'index.js')).handler;
  const applicant = 'u-applicant';
  const r17 = await accessReq(mkEvent({
    familyId: familyId, kind: 'VIEW_APPLY', relationClaim: '我是韦氏外迁支', evidence: ''
  }, applicant), {}, () => {}, console);
  check('access-request 提交成功', r17 && r17.code === 200, JSON.stringify(r17 && (r17.data || r17.message)));
  const accId = r17 && r17.data ? (r17.data.requestId || '') : '';

  const accessListH = require(path.join(FN_DIR, 'access-list', 'index.js')).handler;
  const r18 = await accessListH(mkEvent({ familyId: familyId }, owner), {}, () => {}, console);
  const accLen = r18 && r18.data && r18.data.requests ? r18.data.requests.length : -1;
  check('access-list 有 1 条', accLen === 1, '实际 ' + accLen);

  const accessReview = require(path.join(FN_DIR, 'access-review', 'index.js')).handler;
  const r19 = await accessReview(mkEvent({
    requestId: accId, decision: 'APPROVED', note: '同意', grantedRole: 'VIEWER', expireAt: Date.now() + 86400000
  }, owner), {}, () => {}, console);
  check('access-review 通过', r19 && r19.code === 200, JSON.stringify(r19 && (r19.data || r19.message)));

  const r20 = await syncPull(mkEvent({ familyId: familyId, sinceRev: 0 }, applicant), {}, () => {}, console);
  check('申请者已可读取数据', r20 && r20.code === 200, r20 && (r20.message || 'ok'));

  // ---- 18) 授权过期后立即失效 ----
  const mem = table('Membership').get(familyId + '#' + applicant);
  if (mem) { mem.expireAt = Date.now() - 1000; }
  const r21 = await syncPull(mkEvent({ familyId: familyId, sinceRev: 0 }, applicant), {}, () => {}, console);
  check('过期后 sync-pull 被拒(403)', r21 && r21.code === 403, r21 && r21.message);
  const am = table('Membership').get(familyId + '#' + applicant);
  check('Membership 已置 EXPIRED', !!am && am.status === 'EXPIRED', am && am.status);

  // ---- 19) 撤销授权立即生效 ----
  const r22 = await aclSet(mkEvent({ familyId: familyId, action: 'UPDATE', targetUserId: other, status: 'REVOKED', role: 'EDITOR', branchRootUid: '', expireAt: 0 }, owner), {}, () => {}, console);
  check('family-acl-set 撤销成功', r22 && r22.code === 200);
  const r23 = await syncPull(mkEvent({ familyId: familyId, sinceRev: 0 }, other), {}, () => {}, console);
  check('撤销后 sync-pull 被拒(403)', r23 && r23.code === 403, r23 && r23.message);


  // ---- 20) 谱主自愈：被误降级后仍能恢复 OWNER ----
  const memOwn = table('Membership').get(familyId + '#' + owner);
  if (memOwn) { memOwn.role = 'VIEWER'; memOwn.status = 'ACTIVE'; }
  const r24 = await syncPull(mkEvent({ familyId: familyId, sinceRev: 0 }, owner), {}, () => {}, console);
  check('谱主被降级后 sync-pull 仍可读(自愈)', r24 && r24.code === 200, r24 && r24.message);
  check('Membership 已自愈为 OWNER', table('Membership').get(familyId + '#' + owner).role === 'OWNER',
    table('Membership').get(familyId + '#' + owner).role);

  const r25 = await aclSet(mkEvent({
    familyId: familyId, action: 'ROTATE_INVITE', inviteExpireAt: 0, inviteRole: 'VIEWER'
  }, owner), {}, () => {}, console);
  check('自愈后仍可执行 OWNER 级操作', r25 && r25.code === 200, r25 && r25.message);

  // ---- 21) 谱主自己申请 → 返回 ALREADY_MEMBER，不会产生待审单 ----
  const r26 = await accessReq(mkEvent({ familyId: familyId, kind: 'VIEW_APPLY' }, owner), {}, () => {}, console);
  check('谱主申请查看被拒为 ALREADY_MEMBER', r26 && r26.code === 200 &&
    r26.data && r26.data.status === 'ALREADY_MEMBER', JSON.stringify(r26 && r26.data));

  // ---- 22) 万一存在「谱主」的申请单，审批也不得降级 ----
  const fakeReqId = 'fake-owner-req';
  table('AccessRequest').set(fakeReqId, {
    requestId: fakeReqId, familyId: familyId, applicantId: owner, applicantName: '谱主',
    kind: 'VIEW_APPLY', relationClaim: '', branchClaimUid: '', evidence: '',
    grantedRole: 'VIEWER', expireAt: 0, status: 'PENDING', reviewerId: '', reviewNote: '',
    reviewedAt: 0, createdAt: Date.now(), rev: 0
  });
  const r27 = await accessReview(mkEvent({
    requestId: fakeReqId, decision: 'APPROVED', grantedRole: 'VIEWER', expireAt: 0
  }, owner), {}, () => {}, console);
  check('谱主本人的申请单无法被自己审批（已阻断）', r27 && r27.code === 400, r27 && r27.message);
  check('审批后谱主仍是 OWNER', table('Membership').get(familyId + '#' + owner).role === 'OWNER',
    table('Membership').get(familyId + '#' + owner).role);

  // ---- 23) 自审自批被拒绝 ----
  const selfReqId = 'fake-self-req';
  table('AccessRequest').set(selfReqId, {
    requestId: selfReqId, familyId: familyId, applicantId: owner, applicantName: '谱主',
    kind: 'JOIN_CLAIM', relationClaim: '', branchClaimUid: '', evidence: '',
    grantedRole: 'EDITOR', expireAt: 0, status: 'PENDING', reviewerId: '', reviewNote: '',
    reviewedAt: 0, createdAt: Date.now(), rev: 0
  });
  const r28 = await accessReview(mkEvent({
    requestId: selfReqId, decision: 'APPROVED'
  }, owner), {}, () => {}, console);
  check('谱主自审被拒绝', r28 && r28.code === 400, r28 && r28.message);

  // 汇总
  const fail = results.filter(r => !r.ok);
  console.log('');
  console.log('总计 ' + results.length + ' 项，通过 ' + (results.length - fail.length) + '，失败 ' + fail.length);
  if (fail.length) {
    console.log('失败项:');
    fail.forEach(f => console.log('  - ' + f.name + ' :: ' + f.detail));
    process.exitCode = 1;
  }
})().catch(e => { console.log('未捕获异常:', e && e.message, e && e.stack && e.stack.split('\n')[1]); process.exitCode = 2; });