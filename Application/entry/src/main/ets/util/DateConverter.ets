/**
 * 日期转换工具（公共 HAR 模块）。
 *
 * 将公历日期转换为谱牒常用格式：
 *  - 1912 年前：年号+干支年+干支月+干支日（如 弘治己酉年丁丑月乙丑日）
 *  - 1912~1949：民国X年+农历月日（如 民国9年三月廿二日）
 *  - 1949 后：中文数字年+农历月日（如 一九四九年八月初十日）
 */
import { cnYearText, lunarMonthDayOnly, GanZhi } from './LunarUtil';

/** 历史纪年换算表：年号 → 起始公历年 */
const ERA_TABLE: Array<[string, number]> = [
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

/** 提取年份（支持"光绪三十一年""民国廿九"等古历法纪年） */
export function parseYear(text: string): number {
  if (!text) return 0;
  const parsed: ParsedDate = parseHistoricalDate(text);
  return parsed.year;
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
    if (d >= 0) { digit = d; continue; }
    const u: number = CN_UNITS.indexOf(ch);
    if (u >= 0) {
      const unit: number = Math.pow(10, u + 1);
      if (u === 4) { section = (section + digit) * 10000; total = total + section; section = 0; }
      else { section = section + (digit === 0 ? 1 : digit) * unit; }
      digit = 0;
    }
  }
  return total + section + digit;
}

export interface ParsedDate {
  year: number;
  month: number;
  day: number;
  raw: string;
  convertible: boolean;
}

/** 解析各种历史写法，返回 { year, month, day, raw, convertible } */
export function parseHistoricalDate(text: string): ParsedDate {
  const result: ParsedDate = { year: 0, month: 0, day: 0, raw: text, convertible: false };
  if (text === undefined || text === null || text.trim().length === 0) return result;
  const t: string = text.trim();
  if (t.indexOf('年') < 0 && t.indexOf('月') < 0 && t.indexOf('日') < 0) {
    const fast: RegExpMatchArray | null = t.match(/^([0-9]{3,4})[-/.]/);
    if (fast !== null) {
      const yv: number = parseInt(fast[1], 10);
      result.year = yv;
      result.convertible = yv >= 1 && yv <= 9999;
      return result;
    }
  }
  for (let i: number = 0; i < ERA_TABLE.length; i++) {
    const era: string = ERA_TABLE[i][0];
    const idx: number = t.indexOf(era);
    if (idx < 0) continue;
    const rest: string = t.substring(idx + era.length);
    const m: RegExpMatchArray | null = rest.match(/^\s*([0-9]+|[零一二三四五六七八九十廿卅百千]+)\s*年?/);
    if (m !== null) {
      let n: number = cnToNumber(m[1]);
      if (n < 0) n = 1;
      if (n === 0 && m[1].indexOf('元') >= 0) n = 1;
      result.year = ERA_TABLE[i][1] + Math.max(n, 1) - 1;
      result.convertible = true;
      const mm: RegExpMatchArray | null = rest.match(/([0-9]+|[一二三四五六七八九十廿卅]+)月/);
      if (mm !== null) {
        const mv: number = cnToNumber(mm[1]);
        if (mv > 0 && mv <= 12) result.month = mv;
      }
      return result;
    }
  }
  const bc: RegExpMatchArray | null = t.match(/公元前\s*([0-9]+)\s*年/);
  if (bc !== null) { result.year = -parseInt(bc[1], 10); return result; }
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
  if (mm2 !== null) { const mv: number = parseInt(mm2[1], 10); if (mv >= 1 && mv <= 12) result.month = mv; }
  const dm: RegExpMatchArray | null = t.match(/([0-9]{1,2})\s*日/);
  if (dm !== null) { const dv: number = parseInt(dm[1], 10); if (dv >= 1 && dv <= 31) result.day = dv; }
  return result;
}

/** 根据公历年份返回年号名（如 1875→"光绪"，1912→"民国"），找不到返回空串 */
export function eraNameForYear(year: number): string {
  for (let i: number = 0; i < ERA_TABLE.length; i++) {
    const start: number = ERA_TABLE[i][1];
    if (year >= start) {
      if (i > 0) {
        const prevStart: number = ERA_TABLE[i - 1][1];
        if (year < prevStart) return ERA_TABLE[i][0];
      } else {
        return ERA_TABLE[i][0];
      }
    }
  }
  return '';
}

/** 中文数字（1~10） */
function cnSmallNum(n: number): string {
  const digits: string = '一二三四五六七八九';
  return n === 10 ? '十' : digits.charAt(n - 1);
}

/** 中文数字（1~99，用于民国纪年） */
function cnNum1to99(n: number): string {
  if (n <= 0) return '';
  if (n <= 10) return n === 10 ? '十' : cnSmallNum(n);
  if (n < 20) return '十' + cnSmallNum(n % 10);
  const tens: string = cnSmallNum(Math.floor(n / 10));
  const ones: number = n % 10;
  return tens + '十' + (ones === 0 ? '' : cnSmallNum(ones));
}

/**
 * 公历日期转换文本生成。
 * 根据日期区间自动选择格式：
 *  - 1912 年前：年号+干支年+干支月+干支日（如 弘治己酉年丁丑月乙丑日）
 *  - 1912~1949：民国X年+农历月日（如 民国9年三月廿二日）
 *  - 1949 后：中文数字年+农历月日（如 一九四九年八月初十日）
 *  失败返回空串。
 */
export function formatDateConversion(year: number, month: number, day: number): string {
  if (year <= 0 || month <= 0 || day <= 0) return '';
  if (year < 1912) {
    // 年号+干支年+干支月+干支日
    const eraName: string = eraNameForYear(year);
    const gzYear: string = GanZhi.yearGanZhi(year, true, month, day);
    // 提取干支（去掉"年（马）"后缀）
    const gzMatch: RegExpMatchArray | null = gzYear.match(/^([甲乙丙丁戊己庚辛壬癸][子丑寅卯辰巳午未申酉戌亥])/);
    const gz: string = gzMatch ? gzMatch[1] : '';
    // 干支月
    const mi: number = ((SolarTermsMonthIndex(year, month, day) - 315) % 360 + 360) % 360;
    const monthIdx: number = Math.floor(mi / 30) % 12;
    const monthZhi: string = '寅卯辰巳午未申酉戌亥子丑'.charAt(monthIdx);
    const yearGanIdx: number = ((year - 4) % 10 + 10) % 10;
    const firstGanIdx: number = (yearGanIdx % 5) * 2 + 2;
    const ganIdx: number = (firstGanIdx + monthIdx) % 10;
    const ganMonth: string = '甲乙丙丁戊己庚辛壬癸'.charAt(ganIdx);
    const gzMonth: string = ganMonth + monthZhi + '月';
    // 干支日
    const gzDay: string = GanZhi.dayGanZhi(year, month, day);
    if (eraName) {
      // 年号+干支年+干支月+干支日，年号后无"年"，"年"紧跟干支年
      // 如：正德己酉年丁丑月乙丑日（非 正德年己酉年）
      return eraName + gz + '年' + gzMonth + gzDay;
    }
    return gz + gzMonth + gzDay;
  } else if (year < 1949) {
    // 民国X年+农历月日
    const lunar: string | null = lunarMonthDayOnly(year, month, day);
    const eraNum: number = year - 1911;
    return '民国' + cnSmallNum(eraNum) + '年' + (lunar ? lunar : '');
  } else {
    // 中文数字年+农历月日
    const lunar: string | null = lunarMonthDayOnly(year, month, day);
    return cnYearText(year) + '年' + (lunar ? lunar : '');
  }
}

/** 节气月索引（内联实现，避免循环依赖） */
function SolarTermsMonthIndex(year: number, month: number, day: number): number {
  const jd: number = julianDay(year, month, day) - 0.5;
  const lng: number = sunLongitude(jd);
  const shifted: number = ((lng - 315) % 360 + 360) % 360;
  return Math.floor(shifted / 30) % 12;
}

/** 太阳视黄经（内联实现） */
function sunLongitude(jd: number): number {
  const T: number = (jd - 2451545.0) / 36525.0;
  const L0: number = 280.46646 + 36000.76983 * T + 0.0003032 * T * T;
  const M: number = (357.52911 + 35999.05029 * T - 0.0001537 * T * T) * Math.PI / 180;
  const C: number = (1.914602 - 0.004817 * T - 0.000014 * T * T) * Math.sin(M) +
    (0.019993 - 0.000101 * T) * Math.sin(2 * M) + 0.000289 * Math.sin(3 * M);
  const trueLong: number = L0 + C;
  const omega: number = (125.04 - 1934.136 * T) * Math.PI / 180;
  const lambda: number = trueLong - 0.00569 - 0.00478 * Math.sin(omega);
  return ((lambda % 360) + 360) % 360;
}

/** 儒略日（内联实现） */
function julianDay(year: number, month: number, day: number): number {
  const a: number = Math.floor((14 - month) / 12);
  const y: number = year + 4800 - a;
  const m: number = month + 12 * a - 3;
  return day + Math.floor((153 * m + 2) / 5) + 365 * y + Math.floor(y / 4) - Math.floor(y / 100) +
    Math.floor(y / 400) - 32045;
}

/** 计算周岁；若已故且未填卒年，则按"不知卒"处理返回 -1 */
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

/** 生卒文本，如"1860—1932""1980—  " */
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

/** 组装为可展示的日期文本 */
export function composeDate(year: number, month: number, day: number, calendar: string): string {
  if (year <= 0) return '';
  if (calendar === '农历') {
    const mons: string[] = ['正月', '二月', '三月', '四月', '五月', '六月', '七月', '八月', '九月', '十月', '冬月', '腊月'];
    const days: string[] = ['初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
      '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
      '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十'];
    const m: string = month >= 1 && month <= 12 ? mons[month - 1] : month.toString() + '月';
    const dText: string = day >= 1 && day <= 30 ? days[day - 1] : (day === 31 ? '卅一日' : day.toString());
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

/** 导出 ERA_TABLE 供外部使用 */
export { ERA_TABLE };
