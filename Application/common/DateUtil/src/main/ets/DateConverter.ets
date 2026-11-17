/**
 * 日期换算与解析（公共 HAR 模块）。
 *
 * 将公历日期转换为谱牒常用格式：
 *  - 1912 年前：年号+年号年+干支年+干支月+干支日（如 光绪三十一年乙巳年丁亥月甲子日）
 *  - 1912~1949：民国X年+农历月日（如 民国二十九年三月廿二日）
 *  - 1949 后：中文数字年+农历月日（如 一九四九年八月初十日）
 *
 * 年号与干支均以农历年为准（农历正月初一换年），避免“公历 1 月 1 日”与干支自相矛盾。
 */
import {
  ERA_LIST, EraInfo, eraEndYear, eraYearCount, eraLabel, LunarConst
} from './CalendarData';
import {
  cnNum1to99, cnYearText, lunarDayName, lunarMonthDayOnly, lunarMonthName,
  solarToLunar, LunarDate, GanZhi
} from './LunarUtil';

/** 历史日期解析结果 */
export interface ParsedDate {
  year: number;
  month: number;
  day: number;
  raw: string;
  convertible: boolean;
}

/** 年号匹配结果 */
export interface EraMatch {
  name: string;
  firstYear: number;
  regime: string;
}

/** 解析 1980-05-20 / 1980/5/20 / 1980年5月20日，返回时间戳；解析失败返回 0 */
export function parseDate(text: string): number {
  if (!text) return 0;
  const normalized: string = text.trim().replace(/年/g, '-').replace(/月/g, '-').replace(/日/g, '').replace(/\//g, '-');
  const m: RegExpMatchArray | null = normalized.match(/(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (m === null) {
    const y: RegExpMatchArray | null = normalized.match(/(\d{4})/);
    if (y !== null) return new Date(parseInt(y[1], 10), 0, 1).getTime();
    return 0;
  }
  const year: number = parseInt(m[1], 10);
  const month: number = parseInt(m[2], 10);
  const day: number = parseInt(m[3], 10);
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return 0;
  return new Date(year, month - 1, day).getTime();
}

/** 提取年份（支持“光绪三十一年”“民国廿九”等古历法纪年） */
export function parseYear(text: string): number {
  if (!text) return 0;
  return parseHistoricalDate(text).year;
}

/** 中文数字转阿拉伯数字（支持 廿/卅、十九、二十五、三千八百等） */
const CN_DIGITS: string = '零一二三四五六七八九';
const CN_UNITS: string = '十百千万';

export function cnToNumber(text: string): number {
  if (text.length === 0) return -1;
  if (/^[0-9]+$/.test(text)) return parseInt(text, 10);
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
    }
  }
  return total + section + digit;
}

/**
 * 从“农历X月X日”片段解析农历月日，写入 result（不改年份）。
 * 只匹配“农历”之后的子串，避免把年号年数（如“康熙二十三年”）里的“二十”当成日名。
 */
function applyLunarMonthDay(text: string, result: ParsedDate): void {
  const lunarAt: number = text.indexOf('农历');
  if (lunarAt < 0) return;
  const lunarPart: string = text.substring(lunarAt);
  const lm: RegExpMatchArray | null = lunarPart.match(/(闰)?(正|冬|腊|十一|十二|二|三|四|五|六|七|八|九|十)月/);
  if (lm !== null) {
    const key: string = lm[2];
    if (key === '正') {
      result.month = 1;
    } else if (key === '冬' || key === '十一') {
      result.month = 11;
    } else if (key === '腊' || key === '十二') {
      result.month = 12;
    } else {
      result.month = LunarConst.MONTH_NAMES.indexOf(key + '月') + 1;
    }
  }
  for (let d: number = 30; d >= 1; d--) {
    if (lunarPart.indexOf(lunarDayName(d)) >= 0) {
      result.day = d;
      break;
    }
  }
}

/** 解析各种历史写法，返回 { year, month, day, raw, convertible } */
export function parseHistoricalDate(text: string): ParsedDate {
  const result: ParsedDate = { year: 0, month: 0, day: 0, raw: text, convertible: false };
  if (text === undefined || text === null || text.trim().length === 0) return result;
  const t: string = text.trim();
  // 纯公历写法：1980-05-20 / 1980.5.20
  if (t.indexOf('年') < 0 && t.indexOf('月') < 0 && t.indexOf('日') < 0) {
    const fast: RegExpMatchArray | null = t.match(/^([0-9]{3,4})[-/.]/);
    if (fast !== null) {
      const yv: number = parseInt(fast[1], 10);
      result.year = yv;
      result.convertible = yv >= 1 && yv <= 9999;
      return result;
    }
  }
  // 年号纪年（含“元”年）
  for (let i: number = 0; i < ERA_LIST.length; i++) {
    const e: EraInfo = ERA_LIST[i];
    // “后至元”优先匹配 1335 年的年号，避免被 1264 年的“至元”抢占
    if (e.name === '至元' && e.firstYear === 1264 && t.indexOf('后至元') >= 0) continue;
    const idx: number = t.indexOf(e.name);
    if (idx < 0) continue;
    const rest: string = t.substring(idx + e.name.length);
    const m: RegExpMatchArray | null = rest.match(/^\s*([0-9]+|[元零一二三四五六七八九十廿卅百千]+)\s*年?/);
    if (m === null) continue;
    let n: number = m[1] === '元' ? 1 : cnToNumber(m[1]);
    if (n <= 0) n = 1;
    result.year = e.firstYear + n - 1;
    result.convertible = true;
    // 完整文本（年号+干支+农历+公历）里的农历月日优先，避免误取公历段的“1月”
    if (t.indexOf('农历') >= 0) {
      applyLunarMonthDay(t, result);
      return result;
    }
    const mm: RegExpMatchArray | null = rest.match(/([0-9]+|[元一二三四五六七八九十廿卅]+)月/);
    if (mm !== null) {
      const mv: number = mm[1] === '元' ? 1 : cnToNumber(mm[1]);
      if (mv > 0 && mv <= 12) result.month = mv;
    }
    return result;
  }
  const bc: RegExpMatchArray | null = t.match(/公元前\s*([0-9]+)\s*年/);
  if (bc !== null) {
    result.year = -parseInt(bc[1], 10);
    return result;
  }
  const cnYm: RegExpMatchArray | null = t.match(/([零一二三四五六七八九]{3,4})\s*年/);
  if (cnYm !== null) {
    let yv: number = 0;
    for (let i: number = 0; i < cnYm[1].length; i++) yv = yv * 10 + CN_DIGITS.indexOf(cnYm[1].charAt(i));
    result.year = yv;
    result.convertible = yv >= 1 && yv <= 9999;
  }
  const ym: RegExpMatchArray | null = t.match(/([0-9]{3,4})\s*年?/);
  if (ym !== null && result.year <= 0) result.year = parseInt(ym[1], 10);
  const mm2: RegExpMatchArray | null = t.match(/([0-9]{1,2})\s*月/);
  if (mm2 !== null) {
    const mv: number = parseInt(mm2[1], 10);
    if (mv >= 1 && mv <= 12) result.month = mv;
  }
  const dm: RegExpMatchArray | null = t.match(/([0-9]{1,2})\s*日/);
  if (dm !== null) {
    const dv: number = parseInt(dm[1], 10);
    if (dv >= 1 && dv <= 31) result.day = dv;
  }
  // 农历月日：如“农历二零二四年正月初一”“闰六月十五”
  applyLunarMonthDay(t, result);
  return result;
}

/** 根据农历年返回年号（主链），找不到返回 null */
export function eraOfLunarYear(lunarYear: number): EraMatch | null {
  let best: EraInfo | null = null;
  for (let i: number = 0; i < ERA_LIST.length; i++) {
    const e: EraInfo = ERA_LIST[i];
    if (!e.mainline) continue;
    if (lunarYear < e.displayFrom || lunarYear > eraEndYear(i)) continue;
    if (best === null || e.displayFrom > best.displayFrom) best = e;
  }
  if (best === null) return null;
  return { name: best.name, firstYear: best.firstYear, regime: best.regime };
}

/** 兼容旧接口：按公历年返回年号名 */
export function eraNameForYear(year: number): string {
  const era: EraMatch | null = eraOfLunarYear(year);
  return era !== null ? era.name : '';
}

/** 某公历日期对应的年号纪年信息 */
export interface EraYearInfo {
  name: string;
  regime: string;
  number: number;
}

/**
 * 某公历日期对应的年号纪年信息；无年号返回 null。
 * 民国采用公历纪年：1912-01-01 起，1949-09-30 止；1949-10-01 起不再使用民国。
 * 其余年号仍按农历年（农历正月初一换年）。
 */
export function eraInfoOfSolarDate(year: number, month: number, day: number): EraYearInfo | null {
  if (year <= 0 || month <= 0 || day <= 0) return null;
  if (year >= 1912) {
    if (year > 1949) return null;
    if (year === 1949 && (month > 9 || (month === 9 && day > 30))) return null;
    return { name: '民国', regime: '中华民国', number: year - 1911 };
  }
  const lunar: LunarDate | null = solarToLunar(year, month, day);
  const ly: number = lunar !== null ? lunar.year : year;
  const era: EraMatch | null = eraOfLunarYear(ly);
  if (era === null || ly < era.firstYear) return null;
  return { name: era.name, regime: era.regime, number: ly - era.firstYear + 1 };
}

/**
 * 某公历日期对应的年号纪年文本，如“弘治六年”“民国三十八年”；无年号返回空串。
 * 民国采用公历纪年，1949-10-01 起不再使用；其余年号按农历年换年。
 */
export function eraYearText(year: number, month: number, day: number): string {
  const info: EraYearInfo | null = eraInfoOfSolarDate(year, month, day);
  if (info === null) return '';
  return info.name + cnNum1to99(info.number) + '年';
}

/** 计算年号纪年数字（如 1876→2，1920→9） */
export function eraYearNumber(year: number, eraName: string): number {
  for (let i: number = 0; i < ERA_LIST.length; i++) {
    if (ERA_LIST[i].name === eraName) return year - ERA_LIST[i].firstYear + 1;
  }
  return 0;
}

/**
 * 公历日期转换文本生成。
 *  - 1912 年前：年号+年号年+干支年+干支月+干支日
 *  - 1912~1949.9：民国X年+农历月日
 *  - 1949.10.1 后：中文数字年+农历月日
 *
 * 1912 年前的朝代年号按**农历年**换年；民国按公历纪年，1949-10-01 起不再使用。
 *  失败返回空串。
 */
export function formatDateConversion(year: number, month: number, day: number): string {
  if (year <= 0 || month <= 0 || day <= 0) return '';
  const lunar: LunarDate | null = solarToLunar(year, month, day);
  const ly: number = lunar !== null ? lunar.year : year;
  if (year < 1912) {
    const gzYear: string = GanZhi.yearGanZhiByLunarYear(ly);
    const gz: string = gzYear.substring(0, 2);
    const gzMonth: string = lunar !== null ? GanZhi.monthGanZhiByLunar(ly, lunar.month) :
      GanZhi.monthGanZhiBySolarTerm(year, month, day);
    const gzDay: string = GanZhi.dayGanZhi(year, month, day);
    const era: EraMatch | null = eraOfLunarYear(ly);
    if (era !== null) {
      const n: number = ly - era.firstYear + 1;
      return era.name + cnNum1to99(n) + '年' + gz + '年' + gzMonth + gzDay;
    }
    return gz + '年' + gzMonth + gzDay;
  }
  const lunarText: string | null = lunarMonthDayOnly(year, month, day);
  const eraText: string = eraYearText(year, month, day);
  if (eraText.length > 0) {
    return eraText + (lunarText !== null ? lunarText : '');
  }
  return cnYearText(ly) + '年' + (lunarText !== null ? lunarText : '');
}

/** 计算周岁；若已故且未填卒年，则按“不知卒”处理返回 -1 */
export function ageOf(birth: string, death: string, lifeStatus: string): number {
  const b: number = parseDate(birth);
  if (b === 0) return -1;
  const end: number = death ? parseDate(death) : (lifeStatus === '已故' ? 0 : Date.now());
  if (end === 0 || end < b) return -1;
  const bd: Date = new Date(b);
  const ed: Date = new Date(end);
  let age: number = ed.getFullYear() - bd.getFullYear();
  const monthDiff: number = ed.getMonth() - bd.getMonth();
  if (monthDiff < 0 || (monthDiff === 0 && ed.getDate() < bd.getDate())) age = age - 1;
  return age < 0 ? 0 : age;
}

/** 生卒文本，如“1860—1932”“1980—  ” */
export function lifeSpan(birth: string, death: string, lifeStatus: string): string {
  const by: number = parseYear(birth);
  const dy: number = parseYear(death);
  if (by === 0 && dy === 0) return '';
  const bText: string = by === 0 ? '?' : by.toString();
  const dText: string = dy === 0 ? (lifeStatus === '已故' ? '?' : '') : dy.toString();
  return bText + '\u2014' + dText;
}

/** 带历法标注的日期显示 */
export function displayDate(date: string, calendar: string): string {
  if (!date) return '';
  if (calendar === '农历') return date.indexOf('农历') >= 0 ? date : '农历 ' + date;
  return date;
}

/** 组装为可展示的日期文本；农历可指定闰月 */
export function composeDate(year: number, month: number, day: number, calendar: string, isLeap: boolean = false): string {
  if (year <= 0) return '';
  if (calendar === '农历') {
    const m: string = month >= 1 && month <= 12 ? lunarMonthName(month, isLeap) : month.toString() + '月';
    const dText: string = day >= 1 && day <= 30 ? lunarDayName(day) : (day === 31 ? '卅一日' : day.toString());
    return '农历' + cnYearText(year) + '年' + m + dText;
  }
  const mm: string = (month < 10 ? '0' : '') + month.toString();
  const dd: string = (day < 10 ? '0' : '') + day.toString();
  return year.toString() + '-' + mm + '-' + dd;
}

/** 返回当前公历日期字符串 YYYY-MM-DD */
export function todayString(): string {
  const d: Date = new Date();
  return composeDate(d.getFullYear(), d.getMonth() + 1, d.getDate(), '公历');
}
