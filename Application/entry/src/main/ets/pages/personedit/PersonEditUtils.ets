import { julianDay, lunarMonthDays } from 'common_dateutil';

/** 坐标解析结果 */
export class CoordParseResult {
  ok: boolean = false;
  lat: number = NaN;
  lng: number = NaN;
  alt: number = NaN;
  hint: string = '';
}

/** 墓葬坐标文本解析：支持「经度/纬度」标注、地图分享链接与纯小数对 */
export class GraveCoordParser {
  static parse(text: string): CoordParseResult {
    const out: CoordParseResult = new CoordParseResult();
    const t: string = text.trim();
    if (t.length === 0) {
      return out;
    }
    let lat: number = NaN;
    let lng: number = NaN;
    let alt: number = NaN;

    const altMatch: RegExpMatchArray | null =
      t.match(/(?:海拔|海拔高度|altitude|elevation|alt)\D*(-?\d+(?:\.\d+)?)/i);
    if (altMatch !== null) {
      alt = Number(altMatch[1]);
    }

    const latMatch: RegExpMatchArray | null = t.match(/(?:纬度|latitude|lat)\D*(-?\d+(?:\.\d+)?)/i);
    const lngMatch: RegExpMatchArray | null =
      t.match(/(?:经度|longitude|lng|lon|long)\D*(-?\d+(?:\.\d+)?)/i);
    if (latMatch !== null && lngMatch !== null) {
      lat = Number(latMatch[1]);
      lng = Number(lngMatch[1]);
    } else {
      let x: number = NaN;
      let y: number = NaN;
      const pair: RegExpMatchArray | null = t.match(
        /[?&](?:position|location|ll|q|center|destination|dest|point|latlng|coordinate|coordinates)=(-?\d+(?:\.\d+)?)[,;:]\s*(-?\d+(?:\.\d+)?)/i);
      if (pair !== null) {
        x = Number(pair[1]);
        y = Number(pair[2]);
      } else {
        const nums: RegExpMatchArray | null = t.match(/-?\d+\.\d{3,}/g);
        if (nums !== null && nums.length >= 2) {
          x = Number(nums[0]);
          y = Number(nums[1]);
        }
      }
      if (!isNaN(x) && !isNaN(y)) {
        // 国内地图多为“经度,纬度”；苹果/谷歌多为“纬度,经度”，按量级判断
        if (Math.abs(x) <= 90 && Math.abs(y) > 90) {
          lat = x;
          lng = y;
        } else {
          lng = x;
          lat = y;
        }
      }
    }

    if (isNaN(lat) || isNaN(lng) || (lat === 0 && lng === 0) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      out.hint = '未识别到经纬度，可粘贴含坐标的分享链接或“经度,纬度”';
      return out;
    }
    out.ok = true;
    out.lat = lat;
    out.lng = lng;
    out.alt = alt;
    let hint: string = '已解析：经度 ' + lng.toFixed(6) + '，纬度 ' + lat.toFixed(6);
    if (!isNaN(alt) && alt !== 0) {
      hint += '，海拔 ' + alt.toFixed(1) + ' 米';
    } else {
      hint += '（链接不含海拔，可手工填写）';
    }
    out.hint = hint;
    return out;
  }
}

/** 人物照片/视频字段（以“;”分隔）的纯字符串操作 */
export class PersonMediaUtil {
  static listOf(value: string): string[] {
    if (value.length === 0) {
      return [];
    }
    return value.split(';').filter((s: string): boolean => s.length > 0);
  }

  static isVideoUri(uri: string): boolean {
    const lower: string = uri.toLowerCase();
    return lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.m4v') ||
      lower.endsWith('.3gp') || lower.endsWith('.avi') || lower.endsWith('.mkv') || lower.endsWith('.webm');
  }

  static append(current: string, uris: string[]): string {
    if (uris.length === 0) {
      return current;
    }
    const joined: string = uris.join(';');
    return current.length > 0 ? current + ';' + joined : joined;
  }

  static removeAt(value: string, index: number): string {
    const list: string[] = PersonMediaUtil.listOf(value);
    if (index < 0 || index >= list.length) {
      return value;
    }
    list.splice(index, 1);
    return list.join(';');
  }
}

/** 阿拉伯数字转中文（1~99） */
export class NumTextUtil {
  static toCn(n: number): string {
    const digits: string = '零一二三四五六七八九';
    if (n <= 10) {
      return n === 10 ? '十' : digits.charAt(n);
    }
    if (n < 20) {
      return '十' + digits.charAt(n % 10);
    }
    const tens: string = digits.charAt(Math.floor(n / 10));
    const ones: number = n % 10;
    return tens + '十' + (ones === 0 ? '' : digits.charAt(ones));
  }
}

/** 日期月长计算（公历用儒略日差值，农历走 lunarMonthDays） */
export class DateMath {
  static daysInMonth(year: number, month: number, isLeap: boolean, lunarMode: boolean): number {
    if (lunarMode) {
      return lunarMonthDays(year, month, isLeap);
    }
    if (year <= 0) {
      return 30;
    }
    // 1582 年 10 月 5~14 日不存在（儒略历改格里高利历），仍按 31 天给出日号
    if (year === 1582 && month === 10) {
      return 31;
    }
    const nextYear: number = month === 12 ? year + 1 : year;
    const nextMonth: number = month === 12 ? 1 : month + 1;
    return julianDay(nextYear, nextMonth, 1) - julianDay(year, month, 1);
  }
}
