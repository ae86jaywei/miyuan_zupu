'use strict';

/**
 * 云数据库访问（协作 Zone）。
 *
 * SDK 真实形态（已核对 @hw-agconnect/cloud-server 1.0.5 的 .d.ts）：
 *   const { cloud } = require('@hw-agconnect/cloud-server');
 *   const db  = cloud.database({ zoneName });     // DatabaseConfig = { zoneName, traceId? }
 *   const col = db.collection('Family');          // CloudDBCollection
 *   const q   = col.query().equalTo('f', v).and().greaterThan('rev', 0).orderByAsc('rev').limit(100, 0);
 *   const rows = await q.get();                   // Promise<T[]>
 *   await col.upsert(objOrArray);
 *   await col.delete(objOrArray);                 // 按主键删
 *
 * 早期实现误以为 SDK 导出 `databaseObject(typeName)`，实际没有该 API，
 * 导致线上报「云数据库 SDK 形态不符合预期」（reason=sdk_shape）。
 */

const { BizError, CODE } = require('./core');
const { DEFAULT_ZONE, T } = require('./constants');

const fs = require('fs');
const os = require('os');
const pathMod = require('path');

let cloudRef = null;
let dbRef = null;
let credError = null;

/** 项目凭据文件名（AGC → 项目设置 → 项目凭据 下载的 JSON） */
// AGC「项目设置 → API 客户端」下载的凭据（文件名通常形如 api-client-project.json / agc-apiclient-xxx.json）
const CRED_FILE_NAMES = ['api-client-project.json', 'agconnect-credential.json',
  'agc-apiclient.json', 'agconnect-project-credential.json'];

/** 校验凭据内容：服务端 SDK 只认 type=project_client_id / team_client_id */
function assertCredentialShape(filePath) {
  let raw = '';
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (e) {
    return 'credential_unreadable';
  }
  let obj = null;
  try {
    obj = JSON.parse(raw);
  } catch (e) {
    return 'credential_bad_json';
  }
  if (obj === null || typeof obj !== 'object') {
    return 'credential_bad_json';
  }
  if (obj.type === 'project_client_id' || obj.type === 'team_client_id') {
    return '';
  }
  // 常见误区：下载成了「服务账号密钥」（含 private_key / token_uri）
  if (obj.private_key !== undefined || obj.token_uri !== undefined) {
    return 'credential_is_service_account';
  }
  return 'credential_bad_type';
}

function zoneName() {
  const v = process.env.ZONE_NAME;
  return (v === undefined || v === null || v === '') ? DEFAULT_ZONE : v;
}

/** 在若干可能目录里找随包携带的凭据文件 */
function findBundledCredential() {
  const dirs = [];
  try { dirs.push(__dirname); } catch (e) { /* ignore */ }
  try { dirs.push(pathMod.join(__dirname, '..')); } catch (e) { /* ignore */ }
  try { dirs.push(pathMod.join(__dirname, '..', '..')); } catch (e) { /* ignore */ }
  try { dirs.push(process.cwd()); } catch (e) { /* ignore */ }
  for (let i = 0; i < dirs.length; i++) {
    for (let k = 0; k < CRED_FILE_NAMES.length; k++) {
      const p = pathMod.join(dirs[i], CRED_FILE_NAMES[k]);
      try {
        if (fs.existsSync(p)) {
          return p;
        }
      } catch (e) { /* ignore */ }
    }
  }
  return '';
}

/** 把环境变量 PROJECT_CREDENTIAL（JSON 内容）落成临时文件 */
function credentialFromEnv() {
  const raw = process.env.PROJECT_CREDENTIAL;
  if (raw === undefined || raw === null || typeof raw !== 'string' || raw.trim().length < 2) {
    return '';
  }
  try {
    const obj = JSON.parse(raw);
    if (obj === null || typeof obj !== 'object' || obj.type === undefined) {
      return '';
    }
    const p = pathMod.join(os.tmpdir(), 'zupu-agc-credential.json');
    fs.writeFileSync(p, JSON.stringify(obj), 'utf8');
    return p;
  } catch (e) {
    return '';
  }
}

/**
 * 取 SDK 的 cloud 实例（幂等）。
 *
 * 凭据来源优先级（与 @hw-agconnect/cloud-server 的 CredentialParser 对齐）：
 *  1. 平台已注入 AGC_CONFIG（凭据文件路径）→ 直接用导出实例；
 *  2. 随包携带的项目凭据文件（agconnect-credential.json）→ createInstance(path)；
 *  3. 环境变量 PROJECT_CREDENTIAL（凭据 JSON 内容）→ 落临时文件后 createInstance；
 *  4. 兜底：默认实例（若平台已初始化则可用）。
 */
function ensureCloud() {
  if (cloudRef !== null) {
    return cloudRef;
  }
  let sdk = null;
  try {
    sdk = require('@hw-agconnect/cloud-server');
  } catch (e) {
    throw new BizError(CODE.INTERNAL,
      '云数据库 SDK 未安装：请在云函数依赖中安装 @hw-agconnect/cloud-server（见《AGC手动操作步骤方案》）', 'sdk_missing');
  }
  const base = (sdk && sdk.cloud) ? sdk.cloud : ((sdk && sdk.default && sdk.default.cloud) ? sdk.default.cloud : null);
  if (base === null || base === undefined || typeof base.database !== 'function') {
    throw new BizError(CODE.INTERNAL,
      '云数据库 SDK 形态不符合预期（缺少 cloud.database）。请核对 @hw-agconnect/cloud-server 版本', 'sdk_shape');
  }
  const envPath = process.env.AGC_CONFIG;
  if (envPath !== undefined && envPath !== null && envPath.length > 0) {
    cloudRef = base;
    return cloudRef;
  }
  const credPath = findBundledCredential() || credentialFromEnv();
  if (credPath.length > 0) {
    const shape = assertCredentialShape(credPath);
    if (shape.length > 0) {
      credError = new Error(shape);
      return base;
    }
    if (typeof base.createInstance === 'function') {
      const region = (sdk && sdk.Region && sdk.Region.REGION_CN) ? sdk.Region.REGION_CN : undefined;
      try {
        const inst = base.createInstance(credPath, 'zupu', region);
        if (inst !== null && inst !== undefined && typeof inst.database === 'function') {
          cloudRef = inst;
          return cloudRef;
        }
      } catch (e) {
        credError = e;
      }
    }
  }
  cloudRef = base;
  return cloudRef;
}

/** 取 CloudDB（幂等） */
function database() {
  if (dbRef !== null) {
    return dbRef;
  }
  const cloud = ensureCloud();
  try {
    dbRef = cloud.database({ zoneName: zoneName() });
  } catch (e) {
    throw toBizError(e);
  }
  if (dbRef === null || dbRef === undefined || typeof dbRef.collection !== 'function') {
    throw new BizError(CODE.INTERNAL, '云数据库实例初始化失败（cloud.database 未返回 CloudDB）', 'sdk_shape');
  }
  return dbRef;
}

/** 取对象类型（集合）引用 */
function obj(typeName) {
  const db = database();
  try {
    return db.collection(typeName);
  } catch (e) {
    throw toBizError(e);
  }
}

/** 各对象类型的主键（由 clouddb/objecttype 生成，见 schema-meta.json） */
let schemaMeta = null;
function meta() {
  if (schemaMeta === null) {
    try {
      schemaMeta = require('./schema-meta.json');
    } catch (e) {
      schemaMeta = {};
    }
  }
  return schemaMeta;
}

/**
 * 把普通行对象包装成 CloudDBZoneGenericObject。
 *
 * SDK 的写入路径（executeInsert / executeUpsert / delete）要求记录是
 * 「实现了 getFieldTypeMap/getClassName/getPrimaryKeyList 的对象」或
 * CloudDBZoneGenericObject 实例；否则 convertTClass 会用 `new clazz()` 失败，
 * 或因为拿不到主键抛 3037003（input data does not contain the primary key field）。
 *
 * 读取路径（query）传字符串类型名时 SDK 会自动用 GenericObject，因此只有写入需要包装。
 */
function toGeneric(typeName, row) {
  const sdk = require('@hw-agconnect/cloud-server');
  const G = sdk && sdk.CloudDBZoneGenericObject;
  if (G === undefined || G === null || typeof G.build !== 'function') {
    return row;
  }
  const info = meta()[typeName] || {};
  const pk = info.primaryKey || '';
  const go = G.build(typeName);
  const keys = Object.keys(row || {});
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    go.addFieldValue(k, row[k], k === pk);
  }
  return go;
}

/**
 * 把 SDK 返回的记录归一化成普通对象。
 *
 * query() 传字符串类型名时，SDK 内部用 CloudDBZoneGenericObject，
 * 返回的行是「通用对象」而非普通对象：row.status 取不到，需 row.getObject()。
 */
function toPlain(row) {
  if (row === null || row === undefined) {
    return row;
  }
  if (typeof row.getObject === "function") {
    try {
      const o = row.getObject();
      if (o !== null && typeof o === "object") {
        return o;
      }
    } catch (e) {
      // 落到下面按字段表还原
    }
  }
  if (typeof row.getFieldMap === "function" && typeof row.getFieldValue === "function") {
    try {
      const out = {};
      const map = row.getFieldMap();
      map.forEach((v, k) => {
        out[k] = v;
      });
      return out;
    } catch (e) {
      return row;
    }
  }
  return row;
}

/**
 * 清洗待写入对象：去掉从云端读回时带入的内部字段。
 * CloudDB 读出的行可能含 naturalbase_version / naturalbase_creator 等系统列，
 * 原样 upsert 回去会被服务端判为「未知字段」而失败。
 */
const INTERNAL_KEY = /^(naturalbase|__|\$)/i;

function sanitizeForWrite(row) {
  const out = {};
  const keys = Object.keys(row || {});
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (INTERNAL_KEY.test(k)) {
      continue;
    }
    const v = row[k];
    if (v === undefined) {
      continue;
    }
    out[k] = v;
  }
  return out;
}

/** 把平台的错误对象转成业务错误，附带可操作的提示 */
function toBizError(e) {
  if (e instanceof BizError) {
    return e;
  }
  const msg = (e && (e.message || e.errMsg || e.msg)) ? String(e.message || e.errMsg || e.msg) : '云数据库访问失败';
  if (msg.indexOf('2001015') >= 0) {
    return new BizError(CODE.FORBIDDEN, '云函数以管理员身份写入被拒绝（2001015 permission denied）：请确认对象类型的「管理员」已勾选 query/Upsert/Delete', 'permission_denied');
  }
  if (msg.indexOf('1008230002') >= 0) {
    return new BizError(CODE.INTERNAL, 'schema.json 与云侧对象类型不一致（1008230002），请重新导出 schema', 'schema_mismatch');
  }
  if (msg.indexOf('AGC_CONFIG') >= 0 || msg.indexOf('create instance with path') >= 0 ||
    msg.indexOf('CREDENTIAL') >= 0 || msg.indexOf('credential') >= 0) {
    let hint = '';
    if (credError) {
      const reason = String(credError.message || credError);
      if (reason === 'credential_is_service_account') {
        hint = '（当前凭据是「服务账号密钥」，服务端 SDK 不支持；请改用 AGC「项目设置 → API 客户端」下载的凭据）';
      } else if (reason === 'credential_bad_type') {
        hint = '（凭据缺少 type=project_client_id，请确认下载的是 API 客户端凭据）';
      } else if (reason === 'credential_bad_json') {
        hint = '（凭据文件不是合法 JSON）';
      } else {
        hint = '（初始化失败：' + reason + '）';
      }
    }
    return new BizError(CODE.INTERNAL,
      '云数据库未初始化：缺少项目凭据。请把 AGC「项目设置 → 项目凭据」下载的 JSON 存为 ' +
      'CloudProgram/agconnect-credential.json，运行 tools/sync-credential.ps1 后重新打包部署' + hint, 'no_credential');
  }
  return new BizError(CODE.INTERNAL, msg, 'db_error');
}

/**
 * 查询。
 * @param {string} typeName 对象类型
 * @param {Array<Array>} conds [['familyId','=',v], ['status','in',[...]]]
 * @param {object} [opts] { orderBy: [['rev','ASC']], limit: n, offset: n }
 */
async function query(typeName, conds, opts) {
  const o = opts || {};
  const col = obj(typeName);
  let q = col.query();
  const list = conds || [];
  for (let i = 0; i < list.length; i++) {
    const field = list[i][0];
    const op = list[i][1];
    const value = list[i][2];
    if (i > 0) {
      q = q.and();
    }
    if (op === 'in') {
      const arr = Array.isArray(value) ? value : [value];
      if (arr.length === 0) {
        // in 空数组无意义，直接返回空
        return [];
      }
      q = q.in(field, arr);
    } else if (op === '>') {
      q = q.greaterThan(field, value);
    } else if (op === '<') {
      q = q.lessThan(field, value);
    } else if (op === '>=') {
      q = q.greaterThanOrEqualTo(field, value);
    } else if (op === '<=') {
      q = q.lessThanOrEqualTo(field, value);
    } else {
      q = q.equalTo(field, value);
    }
  }
  const orderBy = o.orderBy || [];
  for (let i = 0; i < orderBy.length; i++) {
    const f = orderBy[i][0];
    const desc = String(orderBy[i][1] || 'ASC').toUpperCase() === 'DESC';
    q = desc ? q.orderByDesc(f) : q.orderByAsc(f);
  }
  const limit = (o.limit && o.limit > 0) ? Math.min(o.limit, 1000) : 200;
  const offset = (o.offset && o.offset > 0) ? o.offset : 0;
  q = offset > 0 ? q.limit(limit, offset) : q.limit(limit);
  try {
    const rows = await q.get();
    if (!Array.isArray(rows)) {
      return [];
    }
    const out = [];
    for (let i = 0; i < rows.length; i++) {
      out.push(toPlain(rows[i]));
    }
    return out;
  } catch (e) {
    throw toBizError(e);
  }
}

/** 查询单条（找不到返回 null） */
async function queryOne(typeName, conds) {
  const rows = await query(typeName, conds, { limit: 1 });
  return rows.length > 0 ? rows[0] : null;
}

/** 按主键取一条 */
async function getById(typeName, idField, id) {
  return queryOne(typeName, [[idField, '=', id]]);
}

/** 写入（upsert）一批对象，返回写入条数 */
async function upsertMany(typeName, objects) {
  if (!objects || objects.length === 0) {
    return 0;
  }
  const col = obj(typeName);
  const rows = [];
  for (let i = 0; i < objects.length; i++) {
    rows.push(toGeneric(typeName, sanitizeForWrite(objects[i])));
  }
  try {
    await col.upsert(rows);
    return rows.length;
  } catch (e) {
    throw toBizError(e);
  }
}

/** 写入单个对象 */
async function upsertOne(typeName, object) {
  return upsertMany(typeName, [object]);
}

/** 按主键删除 */
async function deleteByType(typeName, objects) {
  if (!objects || objects.length === 0) {
    return 0;
  }
  const col = obj(typeName);
  const rows = [];
  for (let i = 0; i < objects.length; i++) {
    rows.push(toGeneric(typeName, sanitizeForWrite(objects[i])));
  }
  try {
    await col.delete(rows);
    return rows.length;
  } catch (e) {
    throw toBizError(e);
  }
}

/** 统计某家族某表的行数（用于黄页人数区间）：优先 countQuery，失败退回分页查询 */
async function count(typeName, conds, pkField) {
  const col = obj(typeName);
  const field = pkField || 'familyId';
  try {
    let q = col.query();
    const list = conds || [];
    for (let i = 0; i < list.length; i++) {
      if (i > 0) {
        q = q.and();
      }
      if (list[i][1] === 'in') {
        q = q.in(list[i][0], Array.isArray(list[i][2]) ? list[i][2] : [list[i][2]]);
      } else {
        q = q.equalTo(list[i][0], list[i][2]);
      }
    }
    const n = await q.countQuery(field);
    if (typeof n === 'number' && isFinite(n)) {
      return n;
    }
  } catch (e) {
    // 忽略，走兜底
  }
  const rows = await query(typeName, conds, { limit: 1000 });
  return rows.length;
}

/**
 * 「顺序写 + 失败即标记」：云侧无跨表事务，调用方按返回的 done 决定补偿。
 */
async function writeBatch(steps, logger) {
  const done = [];
  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    try {
      if (step.op === 'upsert') {
        await upsertMany(step.type, step.objects);
      } else if (step.op === 'delete') {
        await deleteByType(step.type, step.objects);
      }
      done.push({ ok: true, label: step.label || step.type });
    } catch (e) {
      if (logger) {
        logger.error('[zupu][writeBatch] step failed: ' + (step.label || step.type) + ' ' + (e && e.message));
      }
      done.push({ ok: false, label: step.label || step.type, error: (e && e.message) || 'error' });
      return { ok: false, done: done };
    }
  }
  return { ok: true, done: done };
}

module.exports = { ensureCloud, database, obj, sanitizeForWrite, toGeneric, toPlain, query, queryOne, getById,
  upsertMany, upsertOne, deleteByType, count, writeBatch, T, zoneName };
