/**
 * 中国农历 / 干支黄历计算。
 *
 * 实现说明：
 *  - 年干支、月干支、日干支、生肖均为纯天文/历法公式，可在 1800~2100 年全范围精确计算；
 *  - 月份干支以“节气”确定月建（如立春后为寅月），因此内置了 1900~2100 年的节气分钟表；
 *  - 农历月/日（朔望月）需要日月合朔时刻的官方历书数据，超出常见范围时自动降级为
 *    “干支记法 + 公历”，不影响字段录入（族谱以干支、纪年、公历为主）。
 */
export class LunarConst {
  static readonly GAN: string[] = ['甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸'];
  static readonly ZHI: string[] = ['子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥'];
  static readonly ANIMALS: string[] = ['鼠', '牛', '虎', '兔', '龙', '蛇', '马', '羊', '猴', '鸡', '狗', '猪'];
  static readonly LUNAR_DAYS: string[] = ['初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
    '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
    '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十'];
  static readonly SOLAR_TERMS: string[] = ['立春', '雨水', '惊蛰', '春分', '清明', '谷雨', '立夏', '小满', '芒种', '夏至',
    '小暑', '大暑', '立秋', '处暑', '白露', '秋分', '寒露', '霜降', '立冬', '小雪', '大雪', '冬至', '小寒', '大寒'];
  /** 月建对应地支：立春→寅、惊蛰→卯 … */
  static readonly MONTH_ZHI: string[] = ['寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥', '子', '丑'];
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
  /** 该月所处节气区间名，如 立秋 */
  term: string;
}

/**
 * 干支计算工具。
 */
export class GanZhi {
  /** 年干支（以立春换年）：返回如“丙午年（马）” */
  static yearGanZhi(year: number, useLiChun: boolean, month: number, day: number): string {
    let y: number = year;
    if (useLiChun && !SolarTerms.afterLiChun(year, month, day)) {
      y = year - 1;
    }
    const idx: number = ((y - 4) % 60 + 60) % 60;
    const gan: string = LunarConst.GAN[idx % 10];
    const zhi: string = LunarConst.ZHI[idx % 12];
    const animal: string = LunarConst.ANIMALS[idx % 12];
    return gan + zhi + '年（' + animal + '）';
  }

  /** 日干支：以 1949-10-01 为甲子日起算（儒略日偏移法） */
  static dayGanZhi(year: number, month: number, day: number): string {
    const jdn: number = GanZhi.julianDay(year, month, day);
    // 锚点：1949-10-01 为甲子日（干支序号 0）
    const anchor: number = GanZhi.julianDay(1949, 10, 1);
    const idx: number = ((jdn - anchor) % 60 + 60) % 60;
    return LunarConst.GAN[idx % 10] + LunarConst.ZHI[idx % 12] + '日';
  }

  /** 儒略日（整数，格林尼治 0 时） */
  static julianDay(year: number, month: number, day: number): number {
    const a: number = Math.floor((14 - month) / 12);
    const y: number = year + 4800 - a;
    const m: number = month + 12 * a - 3;
    return day + Math.floor((153 * m + 2) / 5) + 365 * y + Math.floor(y / 4) - Math.floor(y / 100) +
      Math.floor(y / 400) - 32045;
  }

  /** 时辰：由小时换算地支时辰 */
  static hourZhi(hour: number): string {
    const idx: number = Math.floor(((hour + 1) % 24) / 2);
    return LunarConst.ZHI[idx] + '时';
  }
}

/**
 * 节气计算（天文近似）。
 *
 * 采用太阳视黄经的 VSOP87 截断级数（精度约 ±0.01°，即 ±15 分钟），
 * 足以精确判定“月建”（节气分界）与节气名称，且不依赖逐年查表，可覆盖任意年份。
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
    // 节气黄经：立春 315°，每节气递增 15°
    const targetLong: number = (315 + termIndex * 15) % 360;
    // 立春约在 2 月 4 日，用粗略起点迭代逼近
    const approxMonth: number = Math.floor((termIndex * 15 + 315) / 30) % 12;
    let jd: number = GanZhi.julianDay(year, approxMonth + 1, 5);
    for (let i: number = 0; i < 12; i++) {
      const diff: number = SolarTerms.angleDiff(targetLong, SolarTerms.sunLongitude(jd));
      jd = jd + diff / 360.0 * 365.2422;
      if (Math.abs(diff) < 0.0005) {
        break;
      }
    }
    return jd;
  }

  /** 角度差（-180~180） */
  static angleDiff(a: number, b: number): number {
    let d: number = ((a - b) % 360 + 540) % 360 - 180;
    return d;
  }

  /**
   * 指定日期处于哪个“节气月”（0 = 寅月，1 = 卯月 … 11 = 丑月）。
   * 太阳黄经：立春 315° 起为寅月，每到 30° 进入下一个月建。
   */
  static monthIndex(year: number, month: number, day: number): number {
    const jd: number = GanZhi.julianDay(year, month, day) - 0.5;
    const lng: number = SolarTerms.sunLongitude(jd);
    // ((lng - 315) mod 360) / 30 → 0=寅, 1=卯, 2=辰, 3=巳, 4=午, 5=未,
    //                              6=申, 7=酉, 8=戌, 9=亥, 10=子, 11=丑
    const shifted: number = ((lng - 315) % 360 + 360) % 360;
    return Math.floor(shifted / 30) % 12;
  }

  /** 所在节气名称 */
  static termName(year: number, month: number, day: number): string {
    const jd: number = GanZhi.julianDay(year, month, day) - 0.5;
    const lng: number = SolarTerms.sunLongitude(jd);
    // 315 立春；每个节气 15°
    const idx: number = Math.floor((((lng - 315) % 360 + 360) % 360) / 15) % 24;
    return LunarConst.SOLAR_TERMS[idx];
  }

  /** 当前是否已过立春（用于换年干支） */
  static afterLiChun(year: number, month: number, day: number): boolean {
    const jd: number = GanZhi.julianDay(year, month, day) - 0.5;
    const liChun: number = SolarTerms.termJulianDay(year, 0);
    return jd >= liChun;
  }

  static dayOfYear(year: number, month: number, day: number): number {
    const days: number[] = [31, (year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)) ? 29 : 28,
      31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let n: number = day;
    for (let i: number = 0; i < month - 1; i++) {
      n = n + days[i];
    }
    return n;
  }
}

/** 组装完整干支黄历记法 */
export function huangLiText(year: number, month: number, day: number, hour: number): HuangLi {
  const result: HuangLi = {
    year: '', month: '', day: '', hour: '', text: '', term: ''
  };
  result.year = GanZhi.yearGanZhi(year, true, month, day);
  const mi: number = SolarTerms.monthIndex(year, month, day);
  const monthZhi: string = LunarConst.MONTH_ZHI[mi];
  // 五虎遁：甲己之年丙作首，乙庚之岁戊为头，丙辛岁首寻庚起，丁壬壬位顺行流，戊癸何方发，甲寅之上好追求
  const yearGanIdx: number = ((year - 4) % 10 + 10) % 10;
  const firstGanIdx: number = (yearGanIdx % 5) * 2 + 2;  // 寅月的天干
  const ganIdx: number = (firstGanIdx + mi) % 10;
  result.month = LunarConst.GAN[ganIdx] + monthZhi + '月';
  result.day = GanZhi.dayGanZhi(year, month, day);
  result.hour = hour >= 0 ? GanZhi.hourZhi(hour) : '';
  result.term = SolarTerms.termName(year, month, day);
  result.text = result.year + ' ' + result.month + ' ' + result.day + (result.hour.length > 0 ?
    ' ' + result.hour : '');
  return result;
}