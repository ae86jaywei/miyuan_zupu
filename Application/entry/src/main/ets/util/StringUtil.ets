/**
 * 字符串工具。
 */

export function isBlank(s: string): boolean {
  return s === undefined || s === null || s.trim().length === 0;
}

export function safe(s: string): string {
  return s === undefined || s === null ? '' : s;
}

/** 取姓名第一个字，用于头像占位 */
export function familyChar(name: string): string {
  if (isBlank(name)) {
    return '谱';
  }
  return name.trim().substring(0, 1);
}

/** 按宽度截断 */
export function ellipsis(text: string, max: number): string {
  if (isBlank(text)) {
    return '';
  }
  const t: string = text.trim();
  return t.length <= max ? t : t.substring(0, max) + '…';
}

/** 中文数字（用于世序） */
export function toChineseNumber(n: number): string {
  const cn: string[] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十',
    '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十'];
  if (n >= 0 && n <= 20) {
    return cn[n];
  }
  return n.toString();
}

/** 简单转义，导出 CSV / JSON 使用 */
export function csvEscape(value: string): string {
  const v: string = safe(value).replace(/"/g, '""');
  return '"' + v + '"';
}

/** 拆分多值字符串（; 或 ， 或 ,） */
export function splitMulti(value: string): string[] {
  if (isBlank(value)) {
    return [];
  }
  return value.split(/[;；,，]/).map((s: string): string => s.trim()).filter((s: string): boolean => s.length > 0);
}

/**
 * 卡片上显示的短 UID：字母前缀（男 F / 女 M）保持不变，数字部分去前导 0 后补足 3 位。
 * 001–999、1000–9999、10000… 依次不补位：F1 → F001、F04196 → F4196。
 * 仅用于显示，数据中仍保存完整 uid。
 */
export function compactUid(uid: string): string {
  if (isBlank(uid)) {
    return '';
  }
  let cut: number = uid.length;
  while (cut > 0) {
    const c: string = uid.charAt(cut - 1);
    if (c < '0' || c > '9') {
      break;
    }
    cut--;
  }
  const prefix: string = uid.substring(0, cut);
  let digits: string = uid.substring(cut);
  if (digits.length === 0) {
    return uid;
  }
  let s: number = 0;
  while (s < digits.length - 1 && digits.charAt(s) === '0') {
    s++;
  }
  digits = digits.substring(s);
  while (digits.length < 3) {
    digits = '0' + digits;
  }
  return prefix + digits;
}
