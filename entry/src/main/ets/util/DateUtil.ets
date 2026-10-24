/**
 * 日期与年龄工具。
 */

/** 解析 1980-05-20 / 1980/5/20 / 1980年5月20日，返回时间戳；解析失败返回 0 */
export function parseDate(text: string): number {
  if (!text) {
    return 0;
  }
  const normalized: string = text.trim().replace(/年/g, '-').replace(/月/g, '-').replace(/日/g, '').replace(/\//g, '-');
  const m: RegExpMatchArray | null = normalized.match(/(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (m === null) {
    const y: RegExpMatchArray | null = normalized.match(/(\d{4})/);
    if (y !== null) {
      return new Date(parseInt(y[1], 10), 0, 1).getTime();
    }
    return 0;
  }
  const year: number = parseInt(m[1], 10);
  const month: number = parseInt(m[2], 10);
  const day: number = parseInt(m[3], 10);
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) {
    return 0;
  }
  return new Date(year, month - 1, day).getTime();
}

/** 提取年份（支持“光绪三十一年”“民国廿九”等古历法纪年） */
export function parseYear(text: string): number {
  if (!text) {
    return 0;
  }
  const parsed: ParsedDate = parseHistoricalDate(text);
  return parsed.year;
}

/** 返回当前公历日期字符串 YYYY-MM-DD */
export function todayString(): string {
  const d: Date = new Date();
  return formatYmd(d);
}

export function formatYmd(d: Date): string {
  const y: string = d.getFullYear().toString();
  const m: string = (d.getMonth() + 1 < 10 ? '0' : '') + (d.getMonth() + 1).toString();
  const day: string = (d.getDate() < 10 ? '0' : '') + d.getDate().toString();
  return y + '-' + m + '-' + day;
}

/** 计算周岁；若已故且未填卒年，则按“不知卒”处理返回 -1 */
export function ageOf(birth: string, death: string, lifeStatus: string): number {
  const b: number = parseDate(birth);
  if (b === 0) {
    return -1;
  }
  const end: number = death ? parseDate(death) : (lifeStatus === '已故' ? 0 : Date.now());
  if (end === 0 || end < b) {
    return -1;
  }
  const bd: Date = new Date(b);
  const ed: Date = new Date(end);
  let age: number = ed.getFullYear() - bd.getFullYear();
  const monthDiff: number = ed.getMonth() - bd.getMonth();
  if (monthDiff < 0 || (monthDiff === 0 && ed.getDate() < bd.getDate())) {
    age = age - 1;
  }
  return age < 0 ? 0 : age;
}

/** 生卒文本，如“1860—1932”“1980—  ” */
export function lifeSpan(birth: string, death: string, lifeStatus: string): string {
  const by: number = parseYear(birth);
  const dy: number = parseYear(death);
  if (by === 0 && dy === 0) {
    return '';
  }
  const bText: string = by === 0 ? '?' : by.toString();
  const dText: string = dy === 0 ? (lifeStatus === '已故' ? '?' : '') : dy.toString();
  return bText + '—' + dText;
}

/** 带历法标注的日期显示 */
export function displayDate(date: string, calendar: string): string {
  if (!date) {
    return '';
  }
  if (calendar === '农历') {
    return date.indexOf('农历') >= 0 ? date : '农历 ' + date;
  }
  return date;
}
/** 历史纪年换算表：年号 → 起始公历年（覆盖常见明清及民国民间用法） */
export const ERA_TABLE: Array<[string, number]> = [
  ['民国', 1912], ['光绪', 1875], ['同治', 1862], ['咸丰', 1851], ['道光', 1821],
  ['嘉庆', 1796], ['乾隆', 1736], ['雍正', 1723], ['康熙', 1662], ['顺治', 1644],
  ['崇祯', 1628], ['天启', 1621], ['万历', 1573], ['隆庆', 1567], ['嘉靖', 1522],
  ['正德', 1506], ['弘治', 1488], ['成化', 1465], ['天顺', 1457], ['景泰', 1450],
  ['正统', 1436], ['宣德', 1426], ['永乐', 1403], ['洪熙', 1425], ['建文', 1399], ['洪武', 1368],
  ['至正', 1341], ['大德', 1297], ['至元', 1264], ['咸淳', 1265], ['淳祐', 1241], ['庆元', 1195],
  ['绍兴', 1131], ['靖康', 1126], ['宣和', 1119], ['崇宁', 1102], ['元祐', 1086], ['熙宁', 1068],
  ['庆历', 1041], ['天圣', 1023], ['景德', 1004], ['咸平', 998], ['雍熙', 984], ['开宝', 968],
  ['乾德', 963], ['建隆', 960], ['显德', 954], ['天福', 936]
];

/**
 * 解析各种历史写法，返回 { year, month, day, eraText }。
 * 支持：
 *  - 公历 1980-05-20 / 1980年5月20日
 *  - 农历 …农历四月六（仅保留原文，year/month 尽力解析）
 *  - 纪年 光绪三十一年 / 民国二十九年 / 民国廿九
 *  - 公元前 …
 */
export interface ParsedDate {
  year: number;
  month: number;
  day: number;
  /** 原始纪年描述（如“光绪三十一年农历五月廿五”），用于展示 */
  raw: string;
  /** 是否可转成 Date（year 在 1~9999 之间） */
  convertible: boolean;
}

const CN_DIGITS: string = '零一二三四五六七八九';
const CN_UNITS: string = '十百千万';

/** 中文数字转阿拉伯数字（支持 廿/卅、十九、二十五、三千八百等） */
export function cnToNumber(text: string): number {
  if (text.length === 0) {
    return -1;
  }
  if (/^[0-9]+$/.test(text)) {
    return parseInt(text, 10);
  }
  const t: string = text.replace(/廿/g, '二十').replace(/卅/g, '三十').replace(/两/g, '二');
  let total: number = 0;
  let section: number = 0;
  let digit: number = 0;
  for (let i: number = 0; i < t.length; i++) {
    const ch: string = t.charAt(i);
    const d: number = CN_DIGITS.indexOf(ch);
    if (d >= 0) {
      digit = d;
      continue;
    }
    const u: number = CN_UNITS.indexOf(ch);
    if (u >= 0) {
      const unit: number = Math.pow(10, u + 1);
      if (u === 4) {
        section = (section + digit) * 10000;
        total = total + section;
        section = 0;
      } else {
        section = section + (digit === 0 ? 1 : digit) * unit;
      }
      digit = 0;
      continue;
    }
    return -1;
  }
  return total + section + digit;
}

/** 解析历史日期文本 */
export function parseHistoricalDate(text: string): ParsedDate {
  const result: ParsedDate = { year: 0, month: 0, day: 0, raw: text, convertible: false };
  if (text === undefined || text === null || text.trim().length === 0) {
    return result;
  }
  const t: string = text.trim();
  // 纪年（年号 / 民国）
  for (let i: number = 0; i < ERA_TABLE.length; i++) {
    const era: string = ERA_TABLE[i][0];
    const idx: number = t.indexOf(era);
    if (idx < 0) {
      continue;
    }
    const rest: string = t.substring(idx + era.length);
    const m: RegExpMatchArray | null = rest.match(/^\s*([0-9]+|[零一二三四五六七八九十廿卅百千]+)\s*年?/);
    if (m !== null) {
      let n: number = cnToNumber(m[1]);
      // 民国元年 = 民国1年
      if (n < 0) {
        n = 1;
      }
      if (n === 0 && m[1].indexOf('元') >= 0) {
        n = 1;
      }
      result.year = ERA_TABLE[i][1] + Math.max(n, 1) - 1;
      result.convertible = true;
      // 月份
      const mm: RegExpMatchArray | null = rest.match(/([0-9]+|[一二三四五六七八九十廿卅]+)月/);
      if (mm !== null) {
        const mv: number = cnToNumber(mm[1]);
        if (mv > 0 && mv <= 12) {
          result.month = mv;
        }
      }
      return result;
    }
  }
  // 公元前
  const bc: RegExpMatchArray | null = t.match(/公元前\s*([0-9]+)\s*年/);
  if (bc !== null) {
    result.year = -parseInt(bc[1], 10);
    return result;
  }
  // 年份：取第一个 3~4 位数字
  const ym: RegExpMatchArray | null = t.match(/([0-9]{3,4})\s*年?/);
  if (ym !== null) {
    result.year = parseInt(ym[1], 10);
    result.convertible = result.year >= 1 && result.year <= 9999;
  }
  const mm2: RegExpMatchArray | null = t.match(/([0-9]{1,2})\s*月/);
  if (mm2 !== null) {
    const mv: number = parseInt(mm2[1], 10);
    if (mv >= 1 && mv <= 12) {
      result.month = mv;
    }
  }
  const dm: RegExpMatchArray | null = t.match(/([0-9]{1,2})\s*日/);
  if (dm !== null) {
    const dv: number = parseInt(dm[1], 10);
    if (dv >= 1 && dv <= 31) {
      result.day = dv;
    }
  }
  return result;
}

/** 组装为可展示的日期文本 */
export function composeDate(year: number, month: number, day: number, calendar: string): string {
  if (year <= 0) {
    return '';
  }
  if (calendar === '农历') {
    const mons: string[] = ['正月', '二月', '三月', '四月', '五月', '六月', '七月', '八月', '九月', '十月', '冬月', '腊月'];
    const days: string[] = ['初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
      '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
      '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十'];
    const m: string = month >= 1 && month <= 12 ? mons[month - 1] : month.toString() + '月';
    const dText: string = day >= 1 && day <= 30 ? days[day - 1] : day.toString();
    return '农历' + year.toString() + '年' + m + dText;
  }
  const mm: string = (month < 10 ? '0' : '') + month.toString();
  const dd: string = (day < 10 ? '0' : '') + day.toString();
  return year.toString() + '-' + mm + '-' + dd;
}