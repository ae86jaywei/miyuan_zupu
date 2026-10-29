'use strict';

/** 云函数统一返回码（端侧 FamilyService 按 code 分支处理） */
const CODE = {
  OK: 200,
  BAD_REQUEST: 400,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  TOO_MANY: 429,
  INTERNAL: 500
};

/** 业务错误：由 handler 统一捕获后转成 { code, message } */
class BizError extends Error {
  /**
   * @param {number} code HTTP 语义状态码
   * @param {string} message 用户可读的中文提示
   * @param {string} [reason] 机器可读的原因（如 membership_expired）
   */
  constructor(code, message, reason) {
    super(message);
    this.name = 'BizError';
    this.code = code;
    this.reason = reason || '';
  }
}

const ok = (data) => ({ code: CODE.OK, message: 'ok', data: data === undefined ? null : data });
const fail = (code, message, reason) => ({ code, message, reason: reason || '' });

/** 读取字符串参数（去空白） */
function str(params, key, defaultValue) {
  const v = params[key];
  if (v === undefined || v === null) {
    return defaultValue === undefined ? '' : defaultValue;
  }
  return String(v).trim();
}

/** 读取数字参数 */
function num(params, key, defaultValue) {
  const v = params[key];
  if (v === undefined || v === null || v === '') {
    return defaultValue === undefined ? 0 : defaultValue;
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : defaultValue;
}

/** 读取布尔参数 */
function bool(params, key, defaultValue) {
  const v = params[key];
  if (v === undefined || v === null) {
    return defaultValue === undefined ? false : defaultValue;
  }
  return v === true || v === 'true' || v === 1 || v === '1';
}

/** 安全 JSON 解析 */
function parseJson(text, fallback) {
  if (typeof text !== 'string' || text.length === 0) {
    return fallback;
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    return fallback;
  }
}

/** 服务器时间（毫秒） */
function nowMs() {
  return Date.now();
}

/** 生成 UUID（不依赖第三方库） */
function uuid() {
  const buf = require('crypto').randomBytes(16);
  buf[6] = (buf[6] & 0x0f) | 0x40;
  buf[8] = (buf[8] & 0x3f) | 0x80;
  const hex = buf.toString('hex');
  return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16) + '-' +
    hex.substring(16, 20) + '-' + hex.substring(20, 32);
}

/** 生成加入码（服务端生成，8 位、易读字符集） */
function newInviteCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = require('crypto').randomBytes(10);
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += alphabet.charAt(bytes[i] % alphabet.length);
  }
  return out;
}

/** 文本归一化为人员 uid 形式（大写去空白，与端侧一致） */
function normUid(uid) {
  return String(uid === undefined || uid === null ? '' : uid).trim().toUpperCase();
}

/** 两点间距离（米），Haversine */
function distanceMeters(lng1, lat1, lng2, lat2) {
  const R = 6371000;
  const rad = (d) => d * Math.PI / 180;
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}

module.exports = { CODE, BizError, ok, fail, str, num, bool, parseJson, nowMs, uuid, newInviteCode, normUid, distanceMeters };