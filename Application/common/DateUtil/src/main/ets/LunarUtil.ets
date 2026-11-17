/**
 * 中国农历 / 干支黄历计算（公共 HAR 模块）。
 *
 * 口径说明（与主流万年历一致）：
 *  - 农历月日：935~2100 年内置月相表，可公历 ⇄ 农历双向换算；
 *  - 年干支：以农历正月初一换年（族谱习惯），年号纪年同样按农历年；
 *  - 月干支：五虎遁，正月建寅，闰月沿用同月干支；
 *  - 日干支：以 1949-10-01（甲子日）为锚点；
 *  - 1582-10-15 之前的公历日期按儒略历计算（与历代历书口径一致）。
 */
import { LunarConst, LunarYearInfo, lunarYearInfo, LUNAR_MIN_YEAR, LUNAR_MAX_YEAR } from './CalendarData';

/** 农历日期 */
export interface LunarDate {
  year: number;
  month: number;
  day: number;
  /** 是否为闰月 */
  isLeap: boolean;
}

/** 公历日期 */
export interface SolarDate {
  year: number;
  month: number;
  day: number;
}

/** 农历一个月的信息（用于日期选择器） */
export interface LunarMonthOption {
  /** 月份 1~12 */
  month: number;
  isLeap: boolean;
  /** 显示文案，如 正月 / 闰六月 */
  label: string;
  /** 该月天数 29 或 30 */
  days: number;
}

/** 干支黄历记法结果 */
export interface HuangLi {
  /** 如 丙午年（马） */
  year: string;
  /** 如 戊戌月 */
  month: string;
  /** 如 辛未日 */
  day: string;
  /** 时辰，如 申时（未传时刻则为空） */
  hour: string;
  /** 组合展示，如 丙午年（马） 戊戌月 辛未日 */
  text: string;
  /** 该日所处节气，如 立秋 */
  term: string;
}

/** 儒略日：1582-10-15 起按格里高利历，之前按儒略历 */
export function julianDay(year: number, month: number, day: number): number {
  const a: number = Math.floor((14 - month) / 12);
  const y: number = year + 4800 - a;
  const m: number = month + 12 * a - 3;
  const base: number = day + Math.floor((153 * m + 2) / 5) + 365 * y + Math.floor(y / 4);
  if (year < 1582 || (year === 1582 && (month < 10 || (month === 10 && day < 15)))) {
    return base - 32083;
  }
  return base - Math.floor(y / 100) + Math.floor(y / 400) - 32045;
}

/** 儒略日转公历日期 */
export function jdToDate(jd: number): SolarDate {
  if (jd >= 2299161) {
    const a: number = jd + 32044;
    const b: number = Math.floor((4 * a + 3) / 146097);
    const c: number = a - Math.floor(146097 * b / 4);
    const d: number = Math.floor((4 * c + 3) / 1461);
    const e: number = c - Math.floor(1461 * d / 4);
    const m: number = Math.floor((5 * e + 2) / 153);
    const day: number = e - Math.floor((153 * m + 2) / 5) + 1;
    const month: number = m + 3 - 12 * Math.floor(m / 10);
    const year: number = 100 * b + d - 4800 + Math.floor(m / 10);
    return { year: year, month: month, day: day };
  }
  const c2: number = jd + 32082;
  const d2: number = Math.floor((4 * c2 + 3) / 1461);
  const e2: number = c2 - Math.floor(1461 * d2 / 4);
  const m2: number = Math.floor((5 * e2 + 2) / 153);
  const day2: number = e2 - Math.floor((153 * m2 + 2) / 5) + 1;
  const month2: number = m2 + 3 - 12 * Math.floor(m2 / 10);
  const year2: number = d2 - 4800 + Math.floor(m2 / 10);
  return { year: year2, month: month2, day: day2 };
}

/** 农历 935 年正月初一（935-02-06）的儒略日，作为整条换算链的起点 */
const LUNAR_EPOCH_JD: number = 2062603;

/** 公历转农历；超出 935~2100 返回 null */
export function solarToLunar(year: number, month: number, day: number): LunarDate | null {
  if (year < LUNAR_MIN_YEAR || year > 2100) return null;
  let diff: number = julianDay(year, month, day) - LUNAR_EPOCH_JD;
  if (diff < 0) return null;
  let ly: number = LUNAR_MIN_YEAR;
  while (ly <= LUNAR_MAX_YEAR) {
    const info: LunarYearInfo | null = lunarYearInfo(ly);
    if (info === null) return null;
    if (diff < info.totalDays) {
      const leap: number = info.leapMonth;
      for (let m: number = 1; m <= 12; m++) {
        const md: number = info.monthDays[m - 1];
        if (diff < md) {
          return { year: ly, month: m, day: diff + 1, isLeap: false };
        }
        diff -= md;
        if (leap > 0 && m === leap) {
          if (diff < info.leapDays) {
            return { year: ly, month: leap, day: diff + 1, isLeap: true };
          }
          diff -= info.leapDays;
        }
      }
      return null;
    }
    diff -= info.totalDays;
    ly++;
  }
  return null;
}

/** 农历转公历；超出范围或日期非法返回 null */
export function lunarToSolar(year: number, month: number, day: number, isLeap: boolean): SolarDate | null {
  if (year < LUNAR_MIN_YEAR || year > LUNAR_MAX_YEAR) return null;
  if (month < 1 || month > 12) return null;
  const months: LunarMonthOption[] = lunarMonthsOfYear(year);
  let matched: LunarMonthOption | null = null;
  for (let i: number = 0; i < months.length; i++) {
    if (months[i].month === month && months[i].isLeap === isLeap) {
      matched = months[i];
      break;
    }
  }
  if (matched === null) return null;
  if (day < 1 || day > matched.days) return null;
  // 先累加起始年之前所有农历年的天数，再累加本年目标月之前的月天数
  let diff: number = 0;
  for (let y: number = LUNAR_MIN_YEAR; y < year; y++) {
    const yi: LunarYearInfo | null = lunarYearInfo(y);
    if (yi === null) return null;
    diff += yi.totalDays;
  }
  for (let i: number = 0; i < months.length; i++) {
    if (months[i].month === month && months[i].isLeap === isLeap) break;
    diff += months[i].days;
  }
  diff += day - 1;
  return jdToDate(LUNAR_EPOCH_JD + diff);
}

/** 某农历年的月份列表（含闰月，闰月紧随同号月之后） */
export function lunarMonthsOfYear(year: number): LunarMonthOption[] {
  const list: LunarMonthOption[] = [];
  const info: LunarYearInfo | null = lunarYearInfo(year);
  if (info === null) return list;
  for (let m: number = 1; m <= 12; m++) {
    list.push({ month: m, isLeap: false, label: LunarConst.MONTH_NAMES[m - 1], days: info.monthDays[m - 1] });
    if (info.leapMonth === m) {
      list.push({ month: m, isLeap: true, label: '闰' + LunarConst.MONTH_NAMES[m - 1], days: info.leapDays });
    }
  }
  return list;
}

/** 某农历月天数；参数非法时返回 29 */
export function lunarMonthDays(year: number, month: number, isLeap: boolean): number {
  const info: LunarYearInfo | null = lunarYearInfo(year);
  if (info === null || month < 1 || month > 12) return 29;
  if (isLeap) return info.leapMonth === month ? info.leapDays : 29;
  return info.monthDays[month - 1];
}

/** 农历月名 */
export function lunarMonthName(month: number, isLeap: boolean): string {
  if (month < 1 || month > 12) return '';
  return (isLeap ? '闰' : '') + LunarConst.MONTH_NAMES[month - 1];
}

/** 农历日名 */
export function lunarDayName(day: number): string {
  if (day < 1 || day > 30) return '';
  return LunarConst.DAY_NAMES[day - 1];
}

/** 中文数字（0~9） */
const CN_DIGITS: string = '零一二三四五六七八九';

/** 年份逐位中文写法：1900 → 一九零零 */
export function cnYearText(year: number): string {
  const s: string = year.toString();
  let out: string = '';
  for (let i: number = 0; i < s.length; i++) {
    const n: number = s.charCodeAt(i) - 48;
    out += CN_DIGITS.charAt(n >= 0 && n <= 9 ? n : 0);
  }
  return out;
}

/** 中文数字（1~10） */
export function cnSmallNum(n: number): string {
  const digits: string = '一二三四五六七八九';
  if (n <= 0) return '';
  return n === 10 ? '十' : digits.charAt(n - 1);
}

/** 中文数字（1~99，用于年号 / 民国纪年） */
export function cnNum1to99(n: number): string {
  if (n <= 0) return '';
  if (n <= 10) return n === 10 ? '十' : cnSmallNum(n);
  if (n < 20) return '十' + cnSmallNum(n % 10);
  const tens: string = cnSmallNum(Math.floor(n / 10));
  const ones: number = n % 10;
  return tens + '十' + (ones === 0 ? '' : cnSmallNum(ones));
}

/**
 * 节气计算（天文近似）。
 * 采用太阳视黄经的截断级数（精度约 ±0.01°，即 ±15 分钟），
 * 足以精确判定节气名称与月建分界，且不依赖逐年查表。
 */
export class SolarTerms {
  /** 太阳视黄经（度，0~360） */
  static sunLongitude(jd: number): number {
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

  /** 某年某节气的儒略日（termIndex 0~23，对应立春、雨水…大寒） */
  static termJulianDay(year: number, termIndex: number): number {
    const targetLong: number = (315 + termIndex * 15) % 360;
    const approxMonth: number = ((1 + Math.floor(termIndex / 2)) % 12) + 1;
    let jd: number = julianDay(year, approxMonth, 5);
    for (let i: number = 0; i < 12; i++) {
      const diff: number = SolarTerms.angleDiff(targetLong, SolarTerms.sunLongitude(jd));
      jd = jd + diff / 360.0 * 365.2422;
      if (Math.abs(diff) < 0.0005) break;
    }
    return jd;
  }

  /** 角度差（-180~180） */
  static angleDiff(a: number, b: number): number {
    const d: number = ((a - b) % 360 + 540) % 360 - 180;
    return d;
  }

  /** 指定日期处于哪个“节气月”（0 = 寅月，1 = 卯月 … 11 = 丑月） */
  static monthIndex(year: number, month: number, day: number): number {
    const jd: number = julianDay(year, month, day) - 0.5;
    const lng: number = SolarTerms.sunLongitude(jd);
    const shifted: number = ((lng - 315) % 360 + 360) % 360;
    return Math.floor(shifted / 30) % 12;
  }

  /** 所在节气名称 */
  static termName(year: number, month: number, day: number): string {
    const jd: number = julianDay(year, month, day) - 0.5;
    const lng: number = SolarTerms.sunLongitude(jd);
    const idx: number = Math.floor((((lng - 315) % 360 + 360) % 360) / 15) % 24;
    return LunarConst.SOLAR_TERMS[idx];
  }

  /** 当前是否已过立春 */
  static afterLiChun(year: number, month: number, day: number): boolean {
    const jd: number = julianDay(year, month, day) - 0.5;
    const liChun: number = SolarTerms.termJulianDay(year, 0);
    return jd >= liChun;
  }
}

/** 干支计算工具 */
export class GanZhi {
  /** 农历年对应的六十甲子序号 */
  static yearIndex(lunarYear: number): number {
    return ((lunarYear - 4) % 60 + 60) % 60;
  }

  /** 农历年的年干序号（0=甲） */
  static yearGanIndex(lunarYear: number): number {
    return ((lunarYear - 4) % 10 + 10) % 10;
  }

  /** 按农历年返回年干支，如“丙午年（马）” */
  static yearGanZhiByLunarYear(lunarYear: number): string {
    const idx: number = GanZhi.yearIndex(lunarYear);
    return LunarConst.GAN[idx % 10] + LunarConst.ZHI[idx % 12] + '年（' + LunarConst.ANIMALS[idx % 12] + '）';
  }

  /**
   * 年干支（兼容旧调用）。
   * 有农历数据时按农历正月初一换年；超出范围时退化为立春换年。
   */
  static yearGanZhi(year: number, useLiChun: boolean, month: number, day: number): string {
    const lunar: LunarDate | null = solarToLunar(year, month, day);
    let ly: number = year;
    if (lunar !== null) {
      ly = lunar.year;
    } else if (useLiChun && !SolarTerms.afterLiChun(year, month, day)) {
      ly = year - 1;
    }
    return GanZhi.yearGanZhiByLunarYear(ly);
  }

  /** 月干支（五虎遁，正月建寅；闰月沿用同月） */
  static monthGanZhiByLunar(lunarYear: number, lunarMonth: number): string {
    const yearGan: number = GanZhi.yearGanIndex(lunarYear);
    const firstGan: number = (yearGan % 5) * 2 + 2;
    const monthIdx: number = ((lunarMonth - 1) % 12 + 12) % 12;
    const gan: string = LunarConst.GAN[(firstGan + monthIdx) % 10];
    const zhi: string = LunarConst.ZHI[(2 + monthIdx) % 12];
    return gan + zhi + '月';
  }

  /** 月干支（按节气月建，供无农历数据时使用） */
  static monthGanZhiBySolarTerm(year: number, month: number, day: number): string {
    const mi: number = SolarTerms.monthIndex(year, month, day);
    let y: number = year;
    if (!SolarTerms.afterLiChun(year, month, day)) y = year - 1;
    const firstGan: number = (GanZhi.yearGanIndex(y) % 5) * 2 + 2;
    const gan: string = LunarConst.GAN[(firstGan + mi) % 10];
    const zhi: string = LunarConst.MONTH_ZHI[mi];
    return gan + zhi + '月';
  }

  /** 日干支：以 1949-10-01 为甲子日起算 */
  static dayGanZhi(year: number, month: number, day: number): string {
    const jdn: number = julianDay(year, month, day);
    const anchor: number = julianDay(1949, 10, 1);
    const idx: number = ((jdn - anchor) % 60 + 60) % 60;
    return LunarConst.GAN[idx % 10] + LunarConst.ZHI[idx % 12] + '日';
  }

  /** 时辰：由小时换算地支时辰 */
  static hourZhi(hour: number): string {
    const idx: number = Math.floor(((hour + 1) % 24) / 2);
    return LunarConst.ZHI[idx] + '时';
  }
}

/** 组装完整干支黄历记法（入参为公历） */
export function huangLiText(year: number, month: number, day: number, hour: number): HuangLi {
  const lunar: LunarDate | null = solarToLunar(year, month, day);
  const ly: number = lunar !== null ? lunar.year : year;
  const result: HuangLi = { year: '', month: '', day: '', hour: '', text: '', term: '' };
  result.year = GanZhi.yearGanZhiByLunarYear(ly);
  result.month = lunar !== null ? GanZhi.monthGanZhiByLunar(ly, lunar.month) :
    GanZhi.monthGanZhiBySolarTerm(year, month, day);
  result.day = GanZhi.dayGanZhi(year, month, day);
  result.hour = hour >= 0 ? GanZhi.hourZhi(hour) : '';
  result.term = SolarTerms.termName(year, month, day);
  result.text = result.year + ' ' + result.month + ' ' + result.day +
    (result.hour.length > 0 ? ' ' + result.hour : '');
  return result;
}

/**
 * 公历日期转农历文本（含年份）。
 * 格式：农历二〇二四年正月初一；失败返回 null。
 */
export function lunarMonthDayText(year: number, month: number, day: number): string | null {
  const lunar: LunarDate | null = solarToLunar(year, month, day);
  if (lunar === null) return null;
  return '农历' + cnYearText(lunar.year) + '年' + lunarMonthName(lunar.month, lunar.isLeap) +
    lunarDayName(lunar.day);
}

/**
 * 公历日期转农历月日（不含年份）。
 * 格式：三月廿二日、闰六月初一；失败返回 null。
 */
export function lunarMonthDayOnly(year: number, month: number, day: number): string | null {
  const lunar: LunarDate | null = solarToLunar(year, month, day);
  if (lunar === null) return null;
  return lunarMonthName(lunar.month, lunar.isLeap) + lunarDayName(lunar.day);
}

/** 农历日期转标准文本，如 二〇二四年正月初一 */
export function lunarDateText(year: number, month: number, day: number, isLeap: boolean): string {
  return cnYearText(year) + '年' + lunarMonthName(month, isLeap) + lunarDayName(day);
}
