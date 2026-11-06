'use strict';

/**
 * 可信调用者身份（§6.0）。
 *
 * 三种取法，本模块按优先级实现：
 *  ① 网关认证注入：function-config.json 的 authType=cloudgw-client，由网关校验后把身份放进 event。
 *     字段形态官方未给出可依赖的稳定结构 → 先真机打印 event 确认，再把字段名写进环境变量
 *     IDENTITY_FIELD_PATH（如 "headers.x-user-id"），未配置时按下列候选键名探测。
 *  ② 端侧显式传 accessToken：云函数调 AGC 服务端接口校验后取 uid（服务端校验，绝不信端侧自报 uid）。
 *  ③ 端侧自报的 uid：**永远不可信**，此处仅用于日志与「绑定记录」，不参与鉴权。
 */

const https = require('https');
const { BizError, CODE, str } = require('./core');

/** 网关可能使用的身份字段名（按优先级）；确认后请用 env IDENTITY_FIELD_PATH 固定下来 */
const GATEWAY_ID_KEYS = ['x-user-id', 'x-agc-user-id', 'x-auth-uid', 'x-hw-uid', 'userid', 'uid',
  'x-user-union-id', 'unionid'];

function envValue(key, defaultValue) {
  const v = process.env[key];
  return (v === undefined || v === null || v === '') ? defaultValue : v;
}

/** 在 event 中按路径取字段，如 "headers.x-user-id" */
function pickPath(obj, path) {
  const parts = path.split('.');
  let cur = obj;
  for (let i = 0; i < parts.length; i++) {
    if (cur === undefined || cur === null || typeof cur !== 'object') {
      return '';
    }
    cur = cur[parts[i]];
  }
  return (cur === undefined || cur === null) ? '' : String(cur);
}

/** 大小写不敏感地取字典里的某个键 */
function pickInsensitive(obj, key) {
  if (obj === undefined || obj === null || typeof obj !== 'object') {
    return '';
  }
  const keys = Object.keys(obj);
  const lower = key.toLowerCase();
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === lower) {
      const v = obj[keys[i]];
      if (v !== undefined && v !== null && String(v).length > 0) {
        return String(v);
      }
    }
  }
  return '';
}

/** ① 从 event 中读取网关注入的身份；读不到返回空串 */
function fromGateway(event) {
  const fixedPath = envValue('IDENTITY_FIELD_PATH', '');
  if (fixedPath.length > 0) {
    const v = pickPath(event, fixedPath);
    return v.length > 0 ? v : '';
  }
  // [SEC-FIX] CWE-290：未配置固定身份路径时，只允许从网关注入的 headers 读取。
  // 原先会回退探测 event 顶层 / event.user / event.auth，而这些位置可能被
  // HTTP 触发器的请求体参数合并污染，客户端可伪造 x-user-id 冒充他人。
  const headers = event ? event.headers : null;
  for (let k = 0; k < GATEWAY_ID_KEYS.length; k++) {
    const v = pickInsensitive(headers, GATEWAY_ID_KEYS[k]);
    if (v.length > 0) {
      return v;
    }
  }
  return '';
}

/** ② 本地不再解析令牌；一律交由 AGC 服务端校验（verifyTokenRemote） */
function verifyTokenCandidate(token) {
  if (!token || token.length < 16) {
    return '';
  }
  // [SEC-FIX] CWE-347 / CWE-290：原实现允许按 TOKEN_CLAIM_HEADER 直接 base64 解 JWT
  // payload 并取 sub 作为 uid，未校验签名，攻击者可伪造任意用户身份。
  // 因此本地不产生任何可信 uid，统一走服务端校验。
  return '';
}

/** 通过 HTTPS 调用 AGC 服务端「校验用户令牌」接口 */
function verifyTokenRemote(token) {
  const verifyUrl = envValue('AGC_VERIFY_URL', '');
  if (verifyUrl.length === 0) {
    return Promise.resolve('');
  }
  return new Promise((resolve) => {
    try {
      const url = new URL(verifyUrl);
      const body = 'access_token=' + encodeURIComponent(token);
      const req = https.request({
        hostname: url.hostname,
        port: url.port || 443,
        path: url.pathname + (url.search || ''),
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Content-Length': Buffer.byteLength(body)
        },
        timeout: 4000
      }, (res) => {
        let raw = '';
        res.on('data', (chunk) => {
          raw += chunk;
        });
        res.on('end', () => {
          const parsed = require('./core').parseJson(raw, {});
          const uid = parsed && (parsed.uid || (parsed.data && parsed.data.uid)) ? String(parsed.uid || parsed.data.uid) : '';
          resolve(uid);
        });
      });
      req.on('timeout', () => {
        req.destroy();
        resolve('');
      });
      req.on('error', () => {
        resolve('');
      });
      req.write(body);
      req.end();
    } catch (e) {
      resolve('');
    }
  });
}

let tokenCache = { token: '', uid: '', ts: 0 };
const TOKEN_CACHE_MS = 60 * 1000;

/**
 * 解析可信身份。
 * @param {object} event 云函数事件
 * @param {object} params 调用参数
 * @returns {Promise<string>} 可信 uid（空串表示未拿到）
 */
async function resolveUid(event, params) {
  const gatewayUid = fromGateway(event);
  if (gatewayUid.length > 0) {
    return gatewayUid;
  }
  const token = str(params, 'accessToken', '');
  if (token.length === 0) {
    return '';
  }
  if (tokenCache.token === token && (Date.now() - tokenCache.ts) < TOKEN_CACHE_MS && tokenCache.uid.length > 0) {
    return tokenCache.uid;
  }
  let uid = verifyTokenCandidate(token);
  if (uid.length === 0) {
    uid = await verifyTokenRemote(token);
  }
  if (uid.length > 0) {
    tokenCache = { token, uid, ts: Date.now() };
  }
  return uid;
}

/** 要求已登录；取不到可信身份直接抛 401，绝不回退到端侧自报 uid */
async function requireUserId(event, params) {
  const uid = await resolveUid(event, params);
  if (uid.length === 0) {
    throw new BizError(CODE.UNAUTHENTICATED, '未登录或登录已失效，请重新登录华为账号', 'unauthenticated');
  }
  return uid;
}

/** 打印一次 event 结构（P0-1 验证用），敏感值打码 */
function describeEventForLog(event) {
  const mask = (v) => {
    const s = String(v);
    return s.length > 8 ? s.substring(0, 4) + '****' + s.substring(s.length - 2) : '****';
  };
  const keys = (event && typeof event === 'object') ? Object.keys(event) : [];
  const headerKeys = (event && event.headers && typeof event.headers === 'object') ? Object.keys(event.headers) : [];
  return { eventKeys: keys, headerKeys: headerKeys, sample: mask(JSON.stringify(event || {}).substring(0, 64)) };
}

module.exports = { resolveUid, requireUserId, fromGateway, describeEventForLog };
