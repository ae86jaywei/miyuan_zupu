/**
 * 修谱协作辅助数据结构（本次版本用于“今日寿辰提醒”等轻量能力）。
 */
export class BirthdayItem {
  uid: string = '';
  name: string = '';
  month: number = 0;
  day: number = 0;
  /** 今年将满的周岁（-1 表示未知） */
  turningAge: number = -1;
  /** 是否在今天 */
  isToday: boolean = false;
}
