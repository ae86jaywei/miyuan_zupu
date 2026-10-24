/**
 * 主题配色。
 *
 * 浅色：宣纸米色底 + 朱砂红 + 鎏金，契合族谱传统质感。
 * 深色：墨色底 + 朱砂 + 鎏金，保证所有文字与背景对比度充足。
 *
 * 用法：组件通过 @StorageProp('darkMode') 订阅深浅色，在 build 中调用
 *       Theme.use(isDark) 之后再读取配色；切换系统深浅色时自动刷新。
 */
export class Theme {
  /** 当前是否深色模式（由 Theme.use 设置） */
  private static dark: boolean = false;

  /** 切换配色模式（在每个页面 build 开头调用） */
  static use(isDark: boolean): void {
    Theme.dark = isDark;
  }

  static isDark(): boolean {
    return Theme.dark;
  }

  // ---------------------------------------------------------------- 品牌色
  static get primary(): string {
    return Theme.dark ? '#D0573C' : '#8C2F1E';
  }

  static get primaryLight(): string {
    return Theme.dark ? '#E07356' : '#B0482F';
  }

  static get gold(): string {
    return Theme.dark ? '#E0B95A' : '#C9A227';
  }

  static get goldLight(): string {
    return Theme.dark ? '#F0D28E' : '#E4C97B';
  }

  // ---------------------------------------------------------------- 文字
  static get ink(): string {
    return Theme.dark ? '#F2ECE2' : '#2B2118';
  }

  static get inkSecondary(): string {
    return Theme.dark ? '#D3C8B8' : '#5F4F3E';
  }

  static get inkTertiary(): string {
    return Theme.dark ? '#A99C8B' : '#7A6A57';
  }

  // ---------------------------------------------------------------- 背景
  static get paper(): string {
    return Theme.dark ? '#17140F' : '#F7F3EA';
  }

  static get paperDeep(): string {
    return Theme.dark ? '#221D17' : '#EFE6D4';
  }

  static get card(): string {
    return Theme.dark ? '#242019' : '#FFFFFF';
  }

  static get line(): string {
    return Theme.dark ? '#3E362B' : '#E2D6C2';
  }

  /** 输入框 / 下拉框底色 */
  static get field(): string {
    return Theme.dark ? '#2E2820' : '#F4EFE5';
  }

  // ---------------------------------------------------------------- 语义色
  static get male(): string {
    return Theme.dark ? '#7FB0E0' : '#2F5D8A';
  }

  static get female(): string {
    return Theme.dark ? '#E68BA8' : '#B04A6A';
  }

  static get alive(): string {
    return Theme.dark ? '#5FC79A' : '#2E7D5B';
  }

  static get deceased(): string {
    return Theme.dark ? '#B5A894' : '#8A7A66';
  }

  static get lost(): string {
    return Theme.dark ? '#E3B15E' : '#C08A2E';
  }

  static get danger(): string {
    return Theme.dark ? '#F07B6B' : '#C0392B';
  }

  /** 下拉箭头：深色背景下用更亮的蓝，浅色背景下用深蓝，均足够醒目 */
  static get selectArrow(): string {
    return Theme.dark ? '#5AA0FF' : '#1E6FD9';
  }

  static get shadow(): string {
    return Theme.dark ? 'rgba(0, 0, 0, 0.45)' : 'rgba(60, 40, 20, 0.10)';
  }

  /** 墓地图表底色 */
  static get mapBg(): string {
    return Theme.dark ? '#221D17' : '#EFE6D4';
  }

  static get mapGrid(): string {
    return Theme.dark ? '#3E362B' : '#DDCFB4';
  }

  /** 卡片强调底（如高亮人物、标签底） */
  static get highlightBg(): string {
    return Theme.dark ? '#3A3020' : '#FFF6E0';
  }
}

/** 间距令牌 */
export class Spacing {
  static readonly XS: number = 4;
  static readonly S: number = 8;
  static readonly M: number = 12;
  static readonly L: number = 16;
  static readonly XL: number = 24;
  static readonly XXL: number = 32;
}

/** 圆角 */
export class Radius {
  static readonly S: number = 8;
  static readonly M: number = 12;
  static readonly L: number = 16;
  static readonly XL: number = 24;
}
