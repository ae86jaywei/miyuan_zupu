import { Person } from '../model/Person';
import { BirthdayItem } from '../model/TimerSession';
import { parseDate } from '../util/DateUtil';

/**
 * 智能提示服务：今日/本月寿辰、资料缺失提醒、世系异常检测等。
 */
export class InsightService {

  /** 本月（含今日）寿辰列表，按日期排序 */
  static birthdaysOfMonth(people: Person[], month: number, todayDay: number): BirthdayItem[] {
    const list: BirthdayItem[] = [];
    people.forEach((p: Person): void => {
      if (p.lifeStatus !== '在世') {
        return;
      }
      const t: number = parseDate(p.birthDate);
      if (t === 0) {
        return;
      }
      const d: Date = new Date(t);
      if (d.getMonth() + 1 !== month) {
        return;
      }
      const item: BirthdayItem = new BirthdayItem();
      item.uid = p.uid;
      item.name = p.name;
      item.month = month;
      item.day = d.getDate();
      const now: Date = new Date();
      item.turningAge = now.getFullYear() - d.getFullYear();
      item.isToday = d.getDate() === todayDay;
      list.push(item);
    });
    list.sort((a: BirthdayItem, b: BirthdayItem): number => a.day - b.day);
    return list;
  }

  /** 资料缺失清单 */
  static missingInfo(people: Person[]): Array<string[]> {
    const rows: Array<string[]> = [];
    people.forEach((p: Person): void => {
      const missing: string[] = [];
      if (p.birthDate.length === 0) {
        missing.push('出生日期');
      }
      if (p.generationChar.length === 0) {
        missing.push('字派');
      }
      if (p.birthPlace.length === 0) {
        missing.push('出生地');
      }
      if (p.fatherId.length === 0 && p.generation > 1) {
        missing.push('父亲');
      }
      if (p.occupation.length === 0) {
        missing.push('职业');
      }
      if (missing.length >= 3) {
        rows.push([p.uid, p.name, missing.join('、')]);
      }
    });
    return rows.slice(0, 20);
  }

  /** 世系异常：父母未录入、世代与父母不连续 */
  static lineageWarnings(people: Person[]): Array<string[]> {
    const map: Map<string, Person> = new Map<string, Person>();
    people.forEach((p: Person): void => {
      map.set(p.uid.toUpperCase(), p);
    });
    const rows: Array<string[]> = [];
    people.forEach((p: Person): void => {
      const fId: string = p.fatherId.trim().toUpperCase();
      const mId: string = p.motherId.trim().toUpperCase();
      if (fId.length > 0 && map.get(fId) === undefined) {
        rows.push([p.name, p.uid, '父亲ID ' + p.fatherId + ' 未录入']);
      }
      if (mId.length > 0 && map.get(mId) === undefined) {
        rows.push([p.name, p.uid, '母亲ID ' + p.motherId + ' 未录入']);
      }
      const f: Person | undefined = map.get(fId);
      if (f !== undefined && f.generation + 1 !== p.generation) {
        rows.push([p.name, p.uid, '世代与父亲不连续（父第' + f.generation.toString() + '世，本第' + p.generation.toString() + '世）']);
      }
    });
    return rows;
  }
}
