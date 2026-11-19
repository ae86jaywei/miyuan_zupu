/**
 * 主题配色。
 *
 * 浅色：宣纸米色底 + 朱砂红 + 鎏金，契合族谱传统质感。
 * 深色：墨色底 + 朱砂 + 鎏金，保证所有文字与背景对比度充足。
 *
 * 颜色值统一来源于 `resources/base/element/color.json`（`theme_*` / `theme_*_dark`），
 * 组件通过 @StorageProp('darkMode') 订阅深浅色，在 build 中调用
 * Theme.use(isDark) 之后再读取配色；切换应用内深浅色时自动切换资源。
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
  static get primary(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_primary_dark') : $r('app.color.theme_primary');
  }

  static get primaryLight(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_primary_light_dark') : $r('app.color.theme_primary_light');
  }

  static get gold(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_gold_dark') : $r('app.color.theme_gold');
  }

  static get goldLight(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_gold_light_dark') : $r('app.color.theme_gold_light');
  }

  // ---------------------------------------------------------------- 文字
  static get ink(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_ink_dark') : $r('app.color.theme_ink');
  }

  static get inkSecondary(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_ink_secondary_dark') : $r('app.color.theme_ink_secondary');
  }

  static get inkTertiary(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_ink_tertiary_dark') : $r('app.color.theme_ink_tertiary');
  }

  // ---------------------------------------------------------------- 背景
  static get paper(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_paper_dark') : $r('app.color.theme_paper');
  }

  static get paperDeep(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_paper_deep_dark') : $r('app.color.theme_paper_deep');
  }

  static get card(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_card_dark') : $r('app.color.theme_card');
  }

  static get line(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_line_dark') : $r('app.color.theme_line');
  }

  /** 输入框 / 下拉框底色 */
  static get field(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_field_dark') : $r('app.color.theme_field');
  }

  // ---------------------------------------------------------------- 语义色
  static get male(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_male_dark') : $r('app.color.theme_male');
  }

  static get female(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_female_dark') : $r('app.color.theme_female');
  }

  static get alive(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_alive_dark') : $r('app.color.theme_alive');
  }

  static get deceased(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_deceased_dark') : $r('app.color.theme_deceased');
  }

  static get lost(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_lost_dark') : $r('app.color.theme_lost');
  }

  static get danger(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_danger_dark') : $r('app.color.theme_danger');
  }

  /** 下拉箭头：深色背景下用更亮的蓝，浅色背景下用深蓝，均足够醒目 */
  static get selectArrow(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_select_arrow_dark') : $r('app.color.theme_select_arrow');
  }

  static get shadow(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_shadow_dark') : $r('app.color.theme_shadow');
  }

  /** 墓地图表底色 */
  static get mapBg(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_map_bg_dark') : $r('app.color.theme_map_bg');
  }

  static get mapGrid(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_map_grid_dark') : $r('app.color.theme_map_grid');
  }

  /** 卡片强调底（如高亮人物、标签底） */
  static get highlightBg(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_highlight_bg_dark') : $r('app.color.theme_highlight_bg');
  }

  /** 主色底上的文字 / 图标 */
  static get onPrimary(): ResourceColor {
    return $r('app.color.theme_on_primary');
  }

  /** 主色底上的次级文字（选中态说明） */
  static get onPrimarySubtle(): ResourceColor {
    return $r('app.color.theme_on_primary_subtle');
  }

  /** 弹层遮罩 */
  static get scrim(): ResourceColor {
    return $r('app.color.theme_scrim');
  }

  /** 轻遮罩 */
  static get scrimLight(): ResourceColor {
    return $r('app.color.theme_scrim_light');
  }

  /** 金色高亮底（选中标签、始祖提示） */
  static get goldBg(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_gold_bg_dark') : $r('app.color.theme_gold_bg');
  }

  /** 危险提示底 */
  static get dangerBg(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_danger_bg_dark') : $r('app.color.theme_danger_bg');
  }

  /** 女性标签底 */
  static get femaleBg(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_female_bg_dark') : $r('app.color.theme_female_bg');
  }

  /** 性别描边（树卡片） */
  static get femaleLine(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_female_line_dark') : $r('app.color.theme_female_line');
  }

  static get maleLine(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_male_line_dark') : $r('app.color.theme_male_line');
  }

  /** 在世 / 正面状态底 */
  static get aliveBg(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_alive_bg_dark') : $r('app.color.theme_alive_bg');
  }

  /** 在世高亮浅底（详情页强调块） */
  static get aliveSoftBg(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_alive_soft_bg_dark') : $r('app.color.theme_alive_soft_bg');
  }

  /** 轻遮罩 / 轻阴影（弹层、浮层投影） */
  static get overlayLight(): ResourceColor {
    return $r('app.color.theme_overlay_light');
  }

  /** 深色封面渐变终点 */
  static get coverDeep(): ResourceColor {
    return $r('app.color.theme_cover_deep');
  }

  /** 主色 / 封面深底上的浅金文字 */
  static get onGoldSoft(): ResourceColor {
    return $r('app.color.theme_on_gold_soft');
  }

  // ---------------------------------------------------------------- 沉浸光感材质
  /** 悬浮导航 / 顶栏的半透明材质底色（配合背景模糊使用） */
  static get glass(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_glass_dark') : $r('app.color.theme_glass');
  }

  /** 材质高光描边，营造悬浮玻璃边缘 */
  static get glassBorder(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_glass_border_dark') : $r('app.color.theme_glass_border');
  }

  /** 沉浸光感的光晕色（封面、页头辉光） */
  static get glow(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_glow_dark') : $r('app.color.theme_glow');
  }

  /** 悬浮元素的深投影 */
  static get shadowDeep(): ResourceColor {
    return Theme.dark ? $r('app.color.theme_shadow_deep_dark') : $r('app.color.theme_shadow_deep');
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
