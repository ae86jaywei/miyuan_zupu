/**
 * 基础枚举。
 */

/** 性别 */
export enum Gender {
  MALE = '男',
  FEMALE = '女'
}

export const GENDER_OPTIONS: string[] = [Gender.MALE, Gender.FEMALE];

/** 在世状态：在世 / 已故 / 失联 / 不详 */
export enum LifeStatus {
  ALIVE = '在世',
  DECEASED = '已故',
  LOST = '失联',
  UNKNOWN = '不详'
}

export const LIFE_STATUS_OPTIONS: string[] = [LifeStatus.ALIVE, LifeStatus.DECEASED, LifeStatus.LOST,
  LifeStatus.UNKNOWN];

/** 在世状态对应颜色 */
export function lifeStatusColor(status: string): string {
  switch (status) {
    case LifeStatus.DECEASED:
      return '#796B5A';
    case LifeStatus.LOST:
      return '#8D6622';
    case LifeStatus.UNKNOWN:
      return '#766B5E';
    default:
      return '#2D7A59';
  }
}

/** 日期历法 */
export enum DateCalendar {
  SOLAR = '公历',
  LUNAR = '农历'
}

export const CALENDAR_OPTIONS: string[] = [DateCalendar.SOLAR, DateCalendar.LUNAR];

/** 五种谱式 */
export enum TreeStyle {
  EU = 'eu',
  SU = 'su',
  PAGODA = 'pagoda',
  DIE = 'die',
  MODERN = 'modern'
}

export interface TreeStyleMeta {
  key: TreeStyle;
  name: string;
  subtitle: string;
  desc: string;
  feature: string;
}

export const TREE_STYLES: TreeStyleMeta[] = [
  {
    key: TreeStyle.EU,
    name: '欧式谱',
    subtitle: '横轴世系图',
    desc: '始祖居左，世序自左向右展开，同辈平行排列，以横线连接宗支，脉络清晰、适合电脑与宽屏浏览。',
    feature: '左右横排 · 世序递进 · 一屏览全宗'
  },
  {
    key: TreeStyle.SU,
    name: '苏式谱',
    subtitle: '竖式吊线图',
    desc: '仿苏轼所创体例，自上而下按世代排行，父居上、子居下，以竖线相缀，五世一图、昭穆分明。',
    feature: '上下直排 · 辈分分明 · 昭穆有序'
  },
  {
    key: TreeStyle.PAGODA,
    name: '宝塔式谱',
    subtitle: '金字塔世系',
    desc: '形如宝塔，上窄下宽，始祖居中为塔尖，子孙逐代向两侧铺开，一目了然族之丁口兴旺。',
    feature: '上窄下宽 · 始祖居中 · 丁口繁盛'
  },
  {
    key: TreeStyle.DIE,
    name: '牒记式谱',
    subtitle: '文字编年体',
    desc: '以文字为体，按世序逐人编记，一人一条，内容详备，是传统家谱最正统的书写样式，便于打印与印刷成册。',
    feature: '文字编年 · 内容详备 · 便于成册'
  },
  {
    key: TreeStyle.MODERN,
    name: '现代创新式',
    subtitle: '卡片时间轴',
    desc: '以人物卡片与时间轴呈现家族脉络，融合生卒年、辈分与头像，兼具温度与科技感，适合手机与平板浏览。',
    feature: '卡片时间轴 · 图文并茂 · 沉浸交互'
  }
];

/** 本族排行（长子/次女等）：不含随母子/随母女 */
export const CLAN_RANK_OPTIONS: string[] = ['长子', '次子', '三子', '四子', '五子', '六子', '七子', '八子', '九子', '十子',
  '长女', '次女', '三女', '四女', '五女', '六女', '七女', '八女', '九女', '十女',
  '独子', '独女'];

/** 娘家排行：比本族多随母子/随母女，页面再按性别过滤 */
export const NATAL_RANK_OPTIONS: string[] = ['长子', '次子', '三子', '四子', '五子', '六子', '七子', '八子', '九子', '十子',
  '长女', '次女', '三女', '四女', '五女', '六女', '七女', '八女', '九女', '十女',
  '独子', '独女', '随母子', '随母女'];

/** 婚配状态：女性 */
export const MARRIAGE_OPTIONS_FEMALE: string[] = ['未记', '未字', '适人', '招赘', '不详'];

/** 婚配状态：男性（入赘女家记“出赘”） */
export const MARRIAGE_OPTIONS_MALE: string[] = ['未记', '未娶', '娶妻', '出赘', '不详'];

/** 标记：殇/幼殇/早卒/无出（出嗣/兼祧/继养统一在“过继/出嗣/兼祧”字段记录） */
export const CHILD_MARK_OPTIONS: string[] = ['未记', '殇', '幼殇', '早卒', '无出'];

/** 一…三十的中文数字（模块级常量，避免每次调用重建数组） */
const GEN_CN: string[] = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十',
  '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
  '二十一', '二十二', '二十三', '二十四', '二十五', '二十六', '二十七', '二十八', '二十九', '三十'];

/** 世代表述：一世…二十世 */
export function generationLabel(gen: number): string {
  if (gen <= 0) {
    return '未编世';
  }
  if (gen <= GEN_CN.length) {
    return '第' + GEN_CN[gen - 1] + '世';
  }
  return '第' + gen + '世';
}

/** 世代下拉候选（1…40 世称谓，模块加载时构建一次，供各页面共用） */
export const GENERATION_LABELS: string[] = buildGenerationLabels(40);
/** 世代候选对应的数值键，与 GENERATION_LABELS 一一对应 */
export const GENERATION_KEYS: string[] = buildGenerationKeys(40);

function buildGenerationLabels(max: number): string[] {
  const list: string[] = [];
  for (let i: number = 1; i <= max; i++) {
    list.push(generationLabel(i));
  }
  return list;
}

function buildGenerationKeys(max: number): string[] {
  const list: string[] = [];
  for (let i: number = 1; i <= max; i++) {
    list.push(i.toString());
  }
  return list;
}
