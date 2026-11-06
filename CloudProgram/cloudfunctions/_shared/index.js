'use strict';

/**
 * 觅源 · 家族协作云函数共享库。
 *
 * 设计依据：家族协作编辑设计方案.md
 *  - §6.0  可信调用者身份（网关 cloudgw-client 注入 → 令牌校验 → 已校验身份）
 *  - §五.9 协作 Zone 端侧 [] 权限，读写全部经云函数
 *  - §五.10 Membership 惰性失效（expireAt）
 *  - §六    rev 分配 + ChangeLog + 结构校验
 *  - §八    payload 脱敏（活人隐私字段绝不出云）
 *
 * 本目录不是云函数，只作为各函数 node_modules/_zupu_shared 的内容被复制进去，
 * 因此要求 **零第三方依赖**（只用 Node.js 内置模块）。
 */

const constants = require('./constants');
const core = require('./core');
const identity = require('./identity');
const authz = require('./authz');
const rev = require('./rev');
const db = require('./db');
const validate = require('./validate');
const patch = require('./patch');
const privacy = require('./privacy');
const human = require('./human');
const members = require('./members');

/** 补齐端侧可能没带的常量别名 */
const EXTRA = {
  T_PRIVATE: 'FamilyPrivate',
  T_DIRECTORY: 'FamilyDirectory'
};

/**
 * 解析云函数入参。
 * AGC 端侧调用 cloudFunction.call({ name, data }) 时，data 的落点在不同版本可能是
 * event.value / event 顶层 / event.params，这里统一兜底。
 */
function extractParams(event) {
  if (event === null || event === undefined) {
    throw new Error('empty event');
  }
  // 候选来源：event 自身（兜底）→ 各种可能的业务参数落点。
  // 后合并的覆盖先合并的，因此「更具体」的来源优先级更高。
  const candidates = [];
  const pushSource = (v) => {
    if (v === undefined || v === null) {
      return;
    }
    if (typeof v === 'string') {
      const t = v.trim();
      if (t.length > 1 && (t.charAt(0) === '{' || t.charAt(0) === '[')) {
        try {
          const parsed = JSON.parse(t);
          if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
            candidates.push(parsed);
          }
        } catch (e) {
          // 不是 JSON，忽略
        }
      }
      return;
    }
    if (typeof v === 'object' && !Array.isArray(v)) {
      candidates.push(v);
    }
  };

  if (typeof event === 'string') {
    pushSource(event);
  } else if (typeof event === 'object') {
    pushSource(event);                       // 兜底：event 顶层本身就是参数
    pushSource(event.value);                 // AGC 云函数 SDK 常见：{ value: {...} }
    pushSource(event.params);                // { params: {...} }
    pushSource(event.data);                  // { data: {...} } / { data: "{...}" }
    pushSource(event.body);                  // API 网关：{ body: "{...}" }
    pushSource(event.queryStringParameters); // 网关查询串
    if (event.request !== null && event.request !== undefined) {
      pushSource(event.request.body);
      pushSource(event.request);
    }
    if (event.context !== null && event.context !== undefined && typeof event.context === 'object') {
      pushSource(event.context);
    }
  }

  const merged = {};
  for (let i = 0; i < candidates.length; i++) {
    const src = candidates[i];
    const keys = Object.keys(src);
    for (let k = 0; k < keys.length; k++) {
      const val = src[keys[k]];
      // 不把纯对象型元数据（headers/requestContext 等）覆盖进业务参数键
      if (val !== undefined) {
        merged[keys[k]] = val;
      }
    }
  }
  return { params: merged };
}

/**
 * 打印 event 的结构（只打键名与类型，值一律打码），用于确认参数与身份的落点。
 * 由 PROBE_EVENT=1 环境变量开启，见 debug.js。
 */
function describeEvent(event) {
  const out = { type: typeof event };
  if (event === null || event === undefined) {
    return out;
  }
  if (typeof event === 'string') {
    out.length = event.length;
    out.head = event.substring(0, 120);
    return out;
  }
  const keys = Object.keys(event);
  out.keys = keys;
  const shape = {};
  for (let i = 0; i < keys.length; i++) {
    const v = event[keys[i]];
    if (v === null || v === undefined) {
      shape[keys[i]] = 'null';
    } else if (typeof v === 'string') {
      shape[keys[i]] = 'string(' + v.length + ')';
    } else if (Array.isArray(v)) {
      shape[keys[i]] = 'array(' + v.length + ')';
    } else if (typeof v === 'object') {
      shape[keys[i]] = 'object{' + Object.keys(v).join(',').substring(0, 200) + '}';
    } else {
      shape[keys[i]] = typeof v;
    }
  }
  out.shape = shape;
  return out;
}

/** 读取家族主记录，不存在抛 404 */
async function getFamily(familyId) {
  if (!familyId) {
    throw new core.BizError(core.CODE.BAD_REQUEST, '缺少 familyId');
  }
  const family = await db.getById(constants.T.FAMILY, 'familyId', familyId);
  if (family === null) {
    throw new core.BizError(core.CODE.NOT_FOUND, '族谱不存在或已删除');
  }
  return family;
}

/**
 * 统一包装云函数入口：解析入参 → 执行 → 统一错误出口。
 * @param {string} name 函数名（仅用于日志）
 * @param {(params, event, log, context) => Promise<object>} body 业务体，返回 callback 的数据
 */
function createHandler(name, body) {
  return async function (event, context, callback, logger) {
    const log = logger || console;
    // 排障开关：云函数环境变量 PROBE_EVENT=1 时，打印 event 的结构（键名与类型，值全部打码）
    if (process.env.PROBE_EVENT === '1') {
      log.info('[zupu][' + name + '] event=' + JSON.stringify(describeEvent(event)));
    }
    let params;
    try {
      params = extractParams(event).params;
    } catch (e) {
      log.warn('[zupu][' + name + '] bad params: ' + (e && e.message));
      return reply(core.fail(core.CODE.BAD_REQUEST, '入参解析失败'), callback);
    }
    try {
      const data = await body(params, event, log, context);
      return reply(core.ok(data === undefined ? null : data), callback);
    } catch (e) {
      if (e instanceof core.BizError) {
        log.error('[zupu][' + name + '] ' + e.code + ' ' + e.message);
        return reply(core.fail(e.code, e.message, e.reason), callback);
      }
      // [SEC-FIX] CWE-209：内部异常详情只写日志，不回传客户端，避免泄露堆栈/路径/查询细节。
      log.error('[zupu][' + name + '] INTERNAL ' + ((e && e.stack) || (e && e.message) || 'unknown'));
      return reply(core.fail(core.CODE.INTERNAL, '服务暂时不可用，请稍后重试', 'internal'), callback);
    }
  };
}

/**
 * 统一出口：同时支持两种调用约定。
 *  - cloudFunction.call()（端侧 SDK）：取 handler 的 **返回值**；
 *  - 网关 HTTP 直调 / callback 式运行环境：取 callback 参数。
 * 早期实现只调 callback，导致端侧拿到 undefined → JSON.parse('') 失败 → 「返回格式异常」。
 */
function reply(payload, callback) {
  if (typeof callback === 'function') {
    try {
      callback(payload);
    } catch (e) {
      // 某些运行环境的 callback 不可用，忽略即可
    }
  }
  return payload;
}

module.exports = Object.assign({}, constants, core, identity, authz, rev, db, validate, patch, privacy, human,
  members, EXTRA, { extractParams, describeEvent, getFamily, createHandler, queryOne: db.queryOne, query: db.query,
    upsertOne: db.upsertOne, upsertMany: db.upsertMany });
