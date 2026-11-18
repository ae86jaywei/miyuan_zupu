import { T, uiFontFamily } from '../service/ScriptService';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { PageNavBar } from '../components/PageNavBar';
import {
  cnNum1to99, eraInfoOfSolarDate, EraYearInfo, formatDateConversion,
  huangLiText, HuangLi, jdToDate, julianDay, LunarConst, lunarDateText,
  lunarDayName, lunarMonthName, LunarDate, LUNAR_MAX_YEAR,
  LUNAR_MIN_YEAR, solarToLunar, SolarDate, SolarTerms
} from 'common_dateutil';

/** 周几简写（0 = 周日） */
const WEEK_NAMES: string[] = ['日', '一', '二', '三', '四', '五', '六'];
/** 周几全称（0 = 周日） */
const WEEK_FULL: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
/** 月历最小公历年（农历表自 935 年起，公历 936 年全年可换算） */
const CAL_MIN_YEAR: number = LUNAR_MIN_YEAR + 1;
/** 月历最大公历年 */
const CAL_MAX_YEAR: number = LUNAR_MAX_YEAR;
/** 月份数字 1~12 */
const MONTH_NUMBERS: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

/** 月历单元格 */
interface DayCell {
  /** 公历日；空白格为 0 */
  day: number;
  /** 空白格 */
  blank: boolean;
  /** 格内小字：节气 > 农历月名（初一）> 农历日名 */
  small: string;
  /** 是否周末 */
  weekend: boolean;
  /** 是否今天 */
  today: boolean;
}

/**
 * 万年历：公历月视图 + 单日历法详情。
 *
 * 所有换算均来自公共 HAR 模块 common_dateutil：
 *  - 农历月日：内置 935~2100 月相表（与天文历算逐日校验）；
 *  - 年号：936 年后晋天福起，按农历年换年；
 *  - 干支：年按农历正月初一换年、月按五虎遁、日以 1949-10-01 甲子为锚点；
 *  - 1582-10-15 前的公历按儒略历计算，月视图会自动跳过 1582 年 10 月 5~14 日。
 */
@Entry
@Component
struct CalendarPage {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  @State viewYear: number = 2024;
  @State viewMonth: number = 1;
  @State selectedDay: number = 1;
  @State weeks: DayCell[][] = [];

  @State detailSolar: string = '';
  @State detailLunar: string = '';
  @State detailEra: string = '';
  @State detailGanZhi: string = '';
  @State detailTerm: string = '';
  @State detailConvert: string = '';
  /** 年月选择浮层是否展开 */
  @State showPicker: boolean = false;

  private todayYear: number = 2024;
  private todayMonth: number = 1;
  private todayDay: number = 1;
  /** 年份滚轮数据（936~2100） */
  private yearRange: string[] = [];

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const now: Date = new Date();
    this.todayYear = now.getFullYear();
    this.todayMonth = now.getMonth() + 1;
    this.todayDay = now.getDate();
    if (this.todayYear >= CAL_MIN_YEAR && this.todayYear <= CAL_MAX_YEAR) {
      this.viewYear = this.todayYear;
      this.viewMonth = this.todayMonth;
      this.selectedDay = this.todayDay;
    } else {
      this.viewYear = CAL_MAX_YEAR;
      this.viewMonth = 1;
      this.selectedDay = 1;
    }
    this.yearRange = this.buildYearRange();
    this.refresh();
  }

  private refresh(): void {
    this.weeks = this.buildWeeks();
    this.refreshDetail();
  }

  /** 年份滚轮数据：936~2100 */
  private buildYearRange(): string[] {
    const list: string[] = [];
    for (let y: number = CAL_MIN_YEAR; y <= CAL_MAX_YEAR; y++) {
      list.push(y.toString());
    }
    return list;
  }

  /**
   * 指定日期是否为真正的节气日：是则返回节气名，否则返回空串。
   * 用 termJulianDay 求各节气精确儒略日，落在当日 [正午-0.5, 正午+0.5) 区间即为节气当日。
   * 与 SolarTerms.termName 的“所在节气段”口径不同——只有节气当日才返回非空。
   */
  private termNameAt(year: number, month: number, day: number): string {
    const dateJd: number = julianDay(year, month, day);
    for (let i: number = 0; i < 24; i++) {
      const termJd: number = SolarTerms.termJulianDay(year, i);
      if (termJd >= dateJd - 0.5 && termJd < dateJd + 0.5) {
        return LunarConst.SOLAR_TERMS[i];
      }
    }
    return '';
  }

  /** 造一个空白格（对齐当月 1 号前的空位与月末补位） */
  private blankCell(): DayCell {
    const c: DayCell = { day: 0, blank: true, small: '', weekend: false, today: false };
    return c;
  }

  /** 造一个真实日期格 */
  private makeCell(day: number, weekday: number): DayCell {
    const lunar: LunarDate | null = solarToLunar(this.viewYear, this.viewMonth, day);
    const term: string = this.termNameAt(this.viewYear, this.viewMonth, day);
    let small: string = '';
    if (term.length > 0) {
      small = term;
    } else if (lunar !== null) {
      small = lunar.day === 1 ? lunarMonthName(lunar.month, lunar.isLeap) : lunarDayName(lunar.day);
    }
    const c: DayCell = {
      day: day,
      blank: false,
      small: small,
      weekend: weekday === 0 || weekday === 6,
      today: this.viewYear === this.todayYear && this.viewMonth === this.todayMonth && day === this.todayDay
    };
    return c;
  }

  /**
   * 生成当前月的周行。
   * 用儒略日逐个推进而不是简单 1..31 循环，1582-10-04 之后会自动跳到 1582-10-15。
   */
  private buildWeeks(): DayCell[][] {
    const rows: DayCell[][] = [];
    let row: DayCell[] = [];
    const startJd: number = julianDay(this.viewYear, this.viewMonth, 1);
    const endJd: number = this.viewMonth === 12
      ? julianDay(this.viewYear + 1, 1, 1)
      : julianDay(this.viewYear, this.viewMonth + 1, 1);
    const lead: number = ((startJd + 1) % 7 + 7) % 7;
    for (let i: number = 0; i < lead; i++) {
      row.push(this.blankCell());
    }
    for (let jd: number = startJd; jd < endJd; jd++) {
      const sd: SolarDate = jdToDate(jd);
      row.push(this.makeCell(sd.day, ((jd + 1) % 7 + 7) % 7));
      if (row.length === 7) {
        rows.push(row);
        row = [];
      }
    }
    if (row.length > 0) {
      while (row.length < 7) {
        row.push(this.blankCell());
      }
      rows.push(row);
    }
    if (rows.length === 0) {
      rows.push([this.blankCell(), this.blankCell(), this.blankCell(), this.blankCell(),
        this.blankCell(), this.blankCell(), this.blankCell()]);
    }
    return rows;
  }

  /** 刷新底部单日详情 */
  private refreshDetail(): void {
    const y: number = this.viewYear;
    const m: number = this.viewMonth;
    const d: number = this.selectedDay;
    const jd: number = julianDay(y, m, d);
    const weekday: number = ((jd + 1) % 7 + 7) % 7;
    this.detailSolar = y.toString() + '年' + m.toString() + '月' + d.toString() + '日 ' + WEEK_FULL[weekday];

    const lunar: LunarDate | null = solarToLunar(y, m, d);
    if (lunar === null) {
      this.detailLunar = '超出内置农历数据范围（' + CAL_MIN_YEAR.toString() + '~' + CAL_MAX_YEAR.toString() + '）';
      this.detailEra = '—';
    } else {
      this.detailLunar = '农历' + lunarDateText(lunar.year, lunar.month, lunar.day, lunar.isLeap);
      const era: EraYearInfo | null = eraInfoOfSolarDate(y, m, d);
      this.detailEra = era === null ? '—' :
        era.name + cnNum1to99(era.number) + '年（' + era.regime + '）';
    }

    const hl: HuangLi = huangLiText(y, m, d, -1);
    this.detailGanZhi = hl.year + ' ' + hl.month + ' ' + hl.day;
    const termName: string = this.termNameAt(y, m, d);
    this.detailTerm = termName.length > 0 ? termName : '—';
    const convert: string = formatDateConversion(y, m, d);
    this.detailConvert = convert.length > 0 ? convert : '—';
  }

  /** 切换到相邻月份（delta = ±1） */
  private goMonth(delta: number): void {
    let y: number = this.viewYear;
    let m: number = this.viewMonth + delta;
    if (m < 1) {
      m = 12;
      y = y - 1;
    } else if (m > 12) {
      m = 1;
      y = y + 1;
    }
    if (y < CAL_MIN_YEAR || y > CAL_MAX_YEAR) {
      return;
    }
    this.viewYear = y;
    this.viewMonth = m;
    this.selectedDay = (y === this.todayYear && m === this.todayMonth) ? this.todayDay : 1;
    this.refresh();
  }

  /** 回到今天 */
  private goToday(): void {
    if (this.todayYear < CAL_MIN_YEAR || this.todayYear > CAL_MAX_YEAR) {
      return;
    }
    this.viewYear = this.todayYear;
    this.viewMonth = this.todayMonth;
    this.selectedDay = this.todayDay;
    this.refresh();
  }

  private selectDay(cell: DayCell): void {
    if (cell.blank) {
      return;
    }
    this.selectedDay = cell.day;
    this.refreshDetail();
  }

  /** 从年月选择器选定月份：切换到该月并关闭浮层 */
  private selectMonth(m: number): void {
    this.viewMonth = m;
    this.selectedDay = (this.viewYear === this.todayYear && this.viewMonth === this.todayMonth) ?
      this.todayDay : 1;
    this.showPicker = false;
    this.refresh();
  }

  private canPrev(): boolean {
    return this.viewYear > CAL_MIN_YEAR || this.viewMonth > 1;
  }

  private canNext(): boolean {
    return this.viewYear < CAL_MAX_YEAR || this.viewMonth < 12;
  }

  @Builder
  MonthCell(cell: DayCell) {
    Column() {
      if (!cell.blank) {
        Text(cell.day.toString()).fontFamily(uiFontFamily())
          .fontSize(15)
          .fontWeight(this.selectedDay === cell.day ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.selectedDay === cell.day ? Theme.primary :
            (cell.today ? Theme.gold : (cell.weekend ? Theme.inkSecondary : Theme.ink)))
        Text(T(cell.small)).fontFamily(uiFontFamily())
          .fontSize(9.5)
          .fontColor(this.selectedDay === cell.day ? Theme.primary : Theme.inkTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.S)
    .backgroundColor(this.selectedDay === cell.day && !cell.blank ? Theme.highlightBg : Color.Transparent)
    .border({
      width: cell.today && this.selectedDay !== cell.day ? 0.5 : 0,
      color: Theme.gold
    })
    .onClick((): void => {
      this.selectDay(cell);
    })
  }

  /**
   * 年月选择浮层：年份滚轮 + 月份网格。点击月份即选定并关闭；滚动年份实时联动下方月历。
   * 由 build() 中的 Stack 承载，悬浮于顶部；点击浮层外部（半透明遮罩）关闭。
   */
  @Builder
  YearMonthPicker() {
    Column() {
      Row() {
        Text(T('选择年月')).fontFamily(uiFontFamily())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text('✕').fontFamily(uiFontFamily())
          .fontSize(16)
          .fontColor(Theme.inkTertiary)
          .onClick((): void => {
            this.showPicker = false;
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: Spacing.L, right: Spacing.L })
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      TextPicker({ range: this.yearRange, selected: this.viewYear - CAL_MIN_YEAR })
        .width('100%')
        .height(120)
        .onChange((value: string | string[], index: number | number[]): void => {
          const idx: number = Array.isArray(index) ? (index as number[])[0] : (index as number);
          this.viewYear = CAL_MIN_YEAR + idx;
          this.selectedDay = (this.viewYear === this.todayYear && this.viewMonth === this.todayMonth) ?
            this.todayDay : 1;
          this.refresh();
        })

      Grid() {
        ForEach(MONTH_NUMBERS, (m: number) => {
          GridItem() {
            Text(T(m.toString() + '月')).fontFamily(uiFontFamily())
              .fontSize(14)
              .fontWeight(this.viewMonth === m ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.viewMonth === m ? Theme.primary : Theme.ink)
              .width('100%')
              .height(40)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.viewMonth === m ? Theme.highlightBg : Color.Transparent)
              .borderRadius(Radius.S)
              .onClick((): void => {
                this.selectMonth(m);
              })
          }
        }, (m: number) => 'm_' + m.toString())
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .rowsTemplate('1fr 1fr 1fr')
      .width('100%')
      .height(132)
      .padding({ left: Spacing.S, right: Spacing.S, top: Spacing.XS, bottom: Spacing.S })
    }
    .width('100%')
    .backgroundColor(Theme.card)
    .borderRadius({ topLeft: Radius.L, topRight: Radius.L })
    .border({ width: { bottom: 0.5 }, color: Theme.line })
    .onClick((): void => {
      // 拦截浮层内部点击，避免误关
    })
  }

  build() {
    Stack() {
    Column() {
      PageNavBar({
        title: T('万年历'),
        subtitle: '公历 · 农历 · 干支 · 年号',
        actionText: '今天',
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        },
        onAction: (): void => {
          this.goToday();
        }
      })

      Scroll() {
        Column() {
          Row() {
            Text('‹').fontFamily(uiFontFamily())
              .fontSize(24)
              .fontColor(this.canPrev() ? Theme.primary : Theme.inkTertiary)
              .width(44)
              .height(44)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.goMonth(-1);
              })
            Column() {
              Row() {
                Text(this.viewYear.toString() + ' 年 ' + this.viewMonth.toString() + ' 月').fontFamily(uiFontFamily())
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.ink)
                Text(' ▼').fontFamily(uiFontFamily())
                  .fontSize(11)
                  .fontColor(Theme.inkTertiary)
                  .margin({ left: 2 })
              }
              .alignItems(VerticalAlign.Center)
              .onClick((): void => {
                this.showPicker = !this.showPicker;
              })
              Text(T(this.monthSummary())).fontFamily(uiFontFamily())
                .fontSize(10.5)
                .fontColor(Theme.inkTertiary)
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)
            Text('›').fontFamily(uiFontFamily())
              .fontSize(24)
              .fontColor(this.canNext() ? Theme.primary : Theme.inkTertiary)
              .width(44)
              .height(44)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.goMonth(1);
              })
          }
          .width('100%')
          .padding({ top: Spacing.S, bottom: Spacing.S })
          .backgroundColor(Theme.card)
          .borderRadius(Radius.L)
          .border({ width: 0.5, color: Theme.line })

          Row() {
            ForEach(WEEK_NAMES, (w: string, index: number) => {
              Text(T(w)).fontFamily(uiFontFamily())
                .fontSize(11)
                .fontColor(index === 0 || index === 6 ? Theme.gold : Theme.inkTertiary)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
            }, (w: string) => 'wk_' + w)
          }
          .width('100%')
          .padding({ top: Spacing.M, bottom: Spacing.XS })

          Column() {
            ForEach(this.weeks, (row: DayCell[], rowIndex: number) => {
              Row() {
                ForEach(row, (cell: DayCell, cellIndex: number) => {
                  Column() {
                    this.MonthCell(cell)
                  }
                  .layoutWeight(1)
                }, (cell: DayCell, cellIndex: number) => 'c_' + this.viewYear.toString() + '_' +
                  this.viewMonth.toString() + '_' + rowIndex.toString() + '_' + cellIndex.toString())
              }
              .width('100%')
            }, (row: DayCell[], rowIndex: number) => 'r_' + this.viewYear.toString() + '_' +
              this.viewMonth.toString() + '_' + rowIndex.toString())
          }
          .width('100%')
          .padding({ left: Spacing.XS, right: Spacing.XS, bottom: Spacing.S })
          .backgroundColor(Theme.card)
          .borderRadius(Radius.L)
          .border({ width: 0.5, color: Theme.line })

          Column() {
            Text(T('所选日期')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkTertiary)
              .width('100%')
              .margin({ bottom: 4 })
            Row() {
              Text(T('公历')).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(Theme.inkTertiary)
                .width(52)
              Text(T(this.detailSolar)).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 5, bottom: 5 })
            Divider().color(Theme.line).strokeWidth(0.5)
            Row() {
              Text(T('农历')).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(Theme.inkTertiary)
                .width(52)
              Text(T(this.detailLunar)).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 5, bottom: 5 })
            Divider().color(Theme.line).strokeWidth(0.5)
            Row() {
              Text(T('干支')).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(Theme.inkTertiary)
                .width(52)
              Text(T(this.detailGanZhi)).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 5, bottom: 5 })
            Divider().color(Theme.line).strokeWidth(0.5)
            Row() {
              Text(T('节气')).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(Theme.inkTertiary)
                .width(52)
              Text(T(this.detailTerm)).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 5, bottom: 5 })
            Divider().color(Theme.line).strokeWidth(0.5)
            Row() {
              Text(T('年号')).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(Theme.inkTertiary)
                .width(52)
              Text(T(this.detailEra)).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 5, bottom: 5 })
            Divider().color(Theme.line).strokeWidth(0.5)
            Row() {
              Text(T('旧历记法')).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(Theme.inkTertiary)
                .width(52)
              Text(T(this.detailConvert)).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 5, bottom: 5 })
          }
          .width('100%')
          .padding(Spacing.L)
          .backgroundColor(Theme.card)
          .borderRadius(Radius.L)
          .border({ width: 0.5, color: Theme.line })
          .alignItems(HorizontalAlign.Start)
          .margin({ top: Spacing.M })

          Text(T('说明：年号与干支年按农历正月初一换年；1582 年 10 月 15 日之前的公历按儒略历计算，' +
            '因此 1582 年 10 月会跳过 5~14 日。数据范围 936~2100 年。')).fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .lineHeight(16)
            .width('100%')
            .margin({ top: Spacing.M })

          Column().height(40)
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.M })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')

    if (this.showPicker) {
      Column() {
        this.YearMonthPicker()
        Blank()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.35)')
      .onClick((): void => {
        this.showPicker = false;
      })
    }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }

  /** 月份摘要：农历年干支 + 年号 */
  private monthSummary(): string {
    const lunar: LunarDate | null = solarToLunar(this.viewYear, this.viewMonth, 15);
    if (lunar === null) {
      return '超出内置农历数据范围';
    }
    const hl: HuangLi = huangLiText(this.viewYear, this.viewMonth, 15, -1);
    const era: EraYearInfo | null = eraInfoOfSolarDate(this.viewYear, this.viewMonth, 15);
    const eraText: string = era === null ? '' :
      ' · ' + era.name + cnNum1to99(era.number) + '年';
    return hl.year + eraText;
  }
}
