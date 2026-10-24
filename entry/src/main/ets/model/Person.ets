/**
 * 人物模型 —— 字段严格对应《关键信息字段_20261023.xlsx》
 *
 * 身份标识：世代 / 唯一ID / 谱名 / 曾用名小名 / 性别 / 辈分字派 / 在世状态
 * 时间信息：出生日期 / 逝世日期 / 出生地 / 现居地
 * 亲属关系：父亲ID / 母亲ID / 排行 / 过继出嗣
 * 生平履历：学历学位 / 职业职务 / 生平简介 / 墓葬信息（含GPS）
 * 联系方式：手机号 / 微信号（隐私字段）
 * 图像信息：头像（相片、视频资料）
 */

/**
 * 配偶关系：支持一夫一妻多妾制下的等级体系。
 * relation 为具体称谓（元配 / 平妻 / 媵 / 侧室 / 良妾 / 贱妾 / 外室……），
 * level 为名分等级（正妻 / 平妻 / 贵妾 / 良妾 / 贱妾 / 外室 / 夫 / 未记），
 * order 为先后次序。
 */
export class SpouseRelation {
  /** 配偶的唯一ID */
  uid: string = '';
  /** 具体称谓：元配 / 正室 / 平妻 / 媵 / 侧室 / 偏房 / 陪房 / 外室 / 夫 / 未记…… */
  relation: string = '元配';
  /** 名分等级：正妻 / 平妻 / 贵妾 / 良妾 / 贱妾 / 外室 / 夫 / 未记 */
  level: string = '正妻';
  /** 次序（从 1 开始） */
  order: number = 1;
}

/** 配偶名分元数据：称谓、等级与含意提示 */
export interface SpouseRelationMeta {
  relation: string;
  level: string;
  hint: string;
}

/**
 * 妻妾称谓与等级（按等级顺序排列）：
 * 正妻 → 平妻 → 贵妾（媵/侧室/副室）→ 良妾（偏房/二房/姨娘/如夫人）
 * → 贱妾（陪房/侍妾/婢妾/通房丫头）→ 外室 → 夫 → 未记
 */
export const SPOUSE_RELATION_METAS: SpouseRelationMeta[] = [
  {
    relation: '元配', level: '正妻',
    hint: '正妻（正室、嫡妻、发妻、正房）：唯一经“六礼”聘娶的合法配偶，与夫“夫妻一体”，主理家事，死后入宗祠、与夫合葬；其子女为嫡出，享有优先继承权。'
  },
  { relation: '正室', level: '正妻', hint: '正妻别称，强调其主持家事、居住正房的正统地位。' },
  { relation: '嫡妻', level: '正妻', hint: '正妻别称，强调“嫡”的宗法正统身份。' },
  { relation: '发妻', level: '正妻', hint: '结发之妻，通常指丈夫首次正式迎娶的正妻；丧偶再娶者为继室。' },
  { relation: '继室', level: '正妻', hint: '继室：元配去世或离异后再娶的正妻，仍属正妻名分，其子女亦为嫡出；名分与礼数略逊于元配。' },
  { relation: '继妻', level: '正妻', hint: '继妻：元配之后续娶的正妻，即继室；其子女为嫡出，但礼法上仍以元配所出为嫡长。' },
  { relation: '继配', level: '正妻', hint: '继配：继娶之正妻的书面称谓，与继室、继妻同义。' },
  { relation: '后妻', level: '正妻', hint: '后妻：相对“前妻/元配”而言，指后娶的正妻，名分为正妻。' },
  { relation: '续弦', level: '正妻', hint: '续弦：以“琴弦再续”喻丧妻后再娶正妻，属正妻名分。' },
  { relation: '填房', level: '正妻', hint: '填房：元配亡故后续娶以“填补房分”的正妻；少数地区亦借指收房的婢妾，本谱按正妻名分记录。' },
  { relation: '正房', level: '正妻', hint: '正妻别称，指居住正房、主持内务的正妻。' },
  {
    relation: '平妻', level: '平妻',
    hint: '平妻（并嫡、对房、两头大）：名义上与正妻地位相当、无需向正妻行妾礼，但仍以正妻为“大姐”；多见于商人、异地官员；子女通常视为嫡出，实际地位略低于正妻之子。'
  },
  { relation: '并嫡', level: '平妻', hint: '平妻别称，谓与正妻并立为嫡。' },
  { relation: '对房', level: '平妻', hint: '平妻别称，指与正妻分房而居、地位相当者。' },
  { relation: '两头大', level: '平妻', hint: '平妻别称，多指商人在外另娶，家乡正妻与外地平妻两头皆以“大”相称。' },
  {
    relation: '媵', level: '贵妾',
    hint: '贵妾（媵）：先秦陪嫁制度遗存，正妻的同族姊妹、侄女随嫁，身份介于妻妾之间，高于普通妾室；正妻去世后可能被扶正。'
  },
  {
    relation: '侧室', level: '贵妾',
    hint: '贵妾（侧室、副室）：出身较高（如官宦庶女），有正式名分与宗族背景；其子可入族谱。'
  },
  { relation: '副室', level: '贵妾', hint: '侧室别称，地位高于普通偏房。' },
  {
    relation: '偏房', level: '良妾',
    hint: '良妾（偏房、二房、姨娘、如夫人）：出身清白平民，经正式纳妾手续并在官府或家族簿册备案，人身较有保障，不可随意买卖。'
  },
  { relation: '二房', level: '良妾', hint: '良妾别称，按入门先后称“二房”。' },
  { relation: '姨娘', level: '良妾', hint: '良妾别称；亦为庶出子女对生母的日常称呼。' },
  { relation: '如夫人', level: '良妾', hint: '良妾别称，谓待遇近于夫人而名分仍为妾。' },
  {
    relation: '陪房', level: '贱妾',
    hint: '贱妾（陪房、侍妾、婢妾、通房丫头）：出身婢女、歌姬或贱籍，签有卖身契，近于主人私有财产，可被买卖、转赠。'
  },
  { relation: '侍妾', level: '贱妾', hint: '贱妾称谓，指贴身服侍主人的妾室。' },
  { relation: '婢妾', level: '贱妾', hint: '贱妾称谓，出身婢女而被收房者。' },
  {
    relation: '通房丫头', level: '贱妾',
    hint: '贱妾中最低者：居所与主人卧室相通，往往连正式妾的名分都没有。'
  },
  {
    relation: '外室', level: '外室',
    hint: '外室（外妇）：男子在府外另置房产供养，不进家门、不被家族承认，不具备法律意义上的妾室地位；其所生子女通常被视为私生子，无继承资格。'
  },
  { relation: '外妇', level: '外室', hint: '外室别称，即府外供养、未入家门的女子。' },
  { relation: '夫', level: '夫', hint: '女性对男性配偶的称谓。' },
  { relation: '未记', level: '未记', hint: '名分未详或暂未考证。' }
];

/** 配偶名分候选项（供编辑页下拉使用，与 SPOUSE_RELATION_METAS 顺序一致） */
export const SPOUSE_RELATIONS: string[] = [
  '元配', '正室', '嫡妻', '发妻', '继室', '继妻', '继配', '后妻', '续弦', '填房', '正房',
  '平妻', '并嫡', '对房', '两头大',
  '媵', '侧室', '副室',
  '偏房', '二房', '姨娘', '如夫人',
  '陪房', '侍妾', '婢妾', '通房丫头',
  '外室', '外妇',
  '夫', '未记'
];

export function spouseRelationMeta(relation: string): SpouseRelationMeta {
  for (let i: number = 0; i < SPOUSE_RELATION_METAS.length; i++) {
    if (SPOUSE_RELATION_METAS[i].relation === relation) {
      return SPOUSE_RELATION_METAS[i];
    }
  }
  const fallback: SpouseRelationMeta = {
    relation: relation,
    level: '未记',
    hint: '名分未详或暂未考证。'
  };
  return fallback;
}

export function spouseRelationLevel(relation: string): string {
  return spouseRelationMeta(relation).level;
}

export function spouseRelationHint(relation: string): string {
  return spouseRelationMeta(relation).hint;
}

/** 下拉展示文案：称谓（等级） */
export function spouseRelationLabel(relation: string): string {
  const level: string = spouseRelationLevel(relation);
  if (level === '未记' || level === '夫' || level === relation) {
    return relation;
  }
  return relation + '（' + level + '）';
}

/** 妻妾所生子女的宗法身份：正妻/平妻 → 嫡出，妾室 → 庶出，外室 → 奸生 */
export function childRankOfSpouseRelation(relation: string): string {
  const level: string = spouseRelationLevel(relation);
  if (level === '正妻' || level === '平妻') {
    return '嫡出';
  }
  if (level === '贵妾' || level === '良妾' || level === '贱妾') {
    return '庶出';
  }
  if (level === '外室') {
    return '奸生';
  }
  return '';
}

/** 子女出身/身份元数据 */
export interface ChildStatusMeta {
  status: string;
  hint: string;
}

export const CHILD_STATUS_OPTIONS: string[] = ['未记', '嫡出', '庶出', '婢生', '奸生', '嗣子', '养子'];

export const CHILD_STATUS_METAS: ChildStatusMeta[] = [
  { status: '未记', hint: '未标注出身名分。' },
  {
    status: '嫡出',
    hint: '正妻（含平妻）所生，宗法地位最高；嫡长子是爵位、宗祧继承的第一顺位人。'
  },
  {
    status: '庶出',
    hint: '妾室（贵妾、良妾、贱妾）所生，身份低于嫡出，但仍是父亲的合法血脉，享有一定继承权（通常远少于嫡子）。'
  },
  {
    status: '婢生',
    hint: '生母为未获正式妾室名分的婢女；在庶出中地位又低一层，明清法律中其应继份仅为妻、妾之子的一半。'
  },
  {
    status: '奸生',
    hint: '非婚所生（奸生子／私生子／孽子）：生母与父亲无妻妾关系，法律地位最低，早期甚至无继承权。'
  },
  {
    status: '嗣子',
    hint: '宗法继承子（过继子）：本人无子，依礼法以同宗兄弟之子为后；过继后法律与宗法上视为亲子，与本生父母关系相应削弱。'
  },
  {
    status: '养子',
    hint: '异姓收养子（义子／螟蛉之子）：通常不改变原姓，严格宗法下继承权受限（如明代规定异姓不得继承），地位不如嗣子稳固。'
  }
];

export function childStatusMeta(status: string): ChildStatusMeta {
  for (let i: number = 0; i < CHILD_STATUS_METAS.length; i++) {
    if (CHILD_STATUS_METAS[i].status === status) {
      return CHILD_STATUS_METAS[i];
    }
  }
  const fallback: ChildStatusMeta = { status: status, hint: '未标注出身名分。' };
  return fallback;
}

/** 子女身份展示称谓（按性别生成嫡子/嫡女等） */
export function childStatusLabel(status: string, gender: string): string {
  const female: boolean = gender === '女';
  switch (status) {
    case '嫡出': return female ? '嫡女' : '嫡子';
    case '庶出': return female ? '庶女' : '庶子';
    case '婢生': return female ? '婢生女' : '婢生子';
    case '奸生': return female ? '奸生女' : '奸生子';
    case '嗣子': return female ? '嗣女' : '嗣子';
    case '养子': return female ? '养女' : '养子';
    default: return '未记';
  }
}

export function childStatusHint(status: string): string {
  return childStatusMeta(status).hint;
}

/** 庶出子女的礼法称谓提示（嫡母为“母亲”，生母称“姨娘/阿姨”） */
export const CONCUBINE_CHILD_TITLE_HINT: string =
  '礼法称谓：庶出子女在名分上以父亲的嫡妻（嫡母）为“母亲”，对亲生母亲（妾室）通常只能称“姨娘”或“阿姨”，公开场合不得直呼“母亲”。';

export function cloneSpouseRelation(src: SpouseRelation): SpouseRelation {
  const r: SpouseRelation = new SpouseRelation();
  r.uid = src.uid;
  r.relation = src.relation;
  r.level = src.level;
  r.order = src.order;
  return r;
}

export class Person {
  /** 自增主键（数据库内部） */
  key: number = 0;
  /** 唯一ID：主键，不可重复，如 F001 / M050 */
  uid: string = '';
  /** 世代：1 表示一世（始祖），2 表示二世…… */
  generation: number = 1;
  /** 谱名：族谱上的正式名字 */
  name: string = '';
  /** 曾用名/小名：多个用逗号隔开 */
  alias: string = '';
  /** 性别：男 / 女 */
  gender: string = '男';
  /** 辈分/字派：如“德” */
  generationChar: string = '';
  /** 在世状态：在世 / 已故 / 失联 */
  lifeStatus: string = '在世';
  /** 子女出身/身份：未记 / 嫡出 / 庶出 / 婢生 / 奸生 / 嗣子 / 养子 */
  childStatus: string = '未记';
  /** 出生日期（公历年月日或农历原文） */
  birthDate: string = '';
  /** 出生日期历法：公历 / 农历 */
  birthCalendar: string = '公历';
  /** 逝世日期 */
  deathDate: string = '';
  /** 逝世日期历法 */
  deathCalendar: string = '公历';
  /** 出生地：省-市-县-乡镇-村 */
  birthPlace: string = '';
  /** 现居地 */
  residence: string = '';
  /** 父亲ID（关联 person.uid） */
  fatherId: string = '';
  /** 母亲ID（关联 person.uid） */
  motherId: string = '';
  /** 配偶ID（主配偶，兼容旧数据；始终等于 spouses[0].uid） */
  spouseId: string = '';
  /** 配偶关系（可多位，含元配/继室/妾等名分与顺序） */
  spouses: SpouseRelation[] = [];
  /** 排行：长子、次女…… */
  rank: string = '';
  /** 过继/出嗣 */
  adoption: string = '';
  /** 学历/学位：本科-华南理工大学 */
  education: string = '';
  /** 职业/职务 */
  occupation: string = '';
  /** 生平简介（500字以内） */
  biography: string = '';
  /** 墓葬信息：地点、山向、碑文摘要 */
  graveInfo: string = '';
  /** 墓葬经度 */
  graveLng: number = 0;
  /** 墓葬纬度 */
  graveLat: number = 0;
  /** 墓葬海拔（米） */
  graveAltitude: number = 0;
  /** 手机号（隐私字段，仅管理员可见） */
  phone: string = '';
  /** 微信号（隐私字段） */
  wechat: string = '';
  /** 头像/相片 URI */
  avatar: string = '';
  /** 视频资料 URI（多个以 ; 分隔） */
  videos: string = '';
  /** 照片/视频资料 URI（多个以 ; 分隔，新版字段“照片视频”） */
  photos: string = '';
  /** 创建时间（毫秒） */
  createdAt: number = 0;
  /** 更新时间（毫秒） */
  updatedAt: number = 0;
}

/** 字段说明（用于表单分组渲染与校验提示） */
export interface FieldMeta {
  key: string;
  label: string;
  hint: string;
  group: string;
  type: string;
  privacy: boolean;
}

/** 与 Excel 五个字段分类一一对应的字段元数据 */
export const FIELD_GROUPS: string[] = ['身份标识', '时间信息', '亲属关系', '生平履历', '联系方式', '图像信息'];

export const FIELD_METAS: FieldMeta[] = [
  { key: 'generation', label: '世代', hint: '如：始祖（一世）、二世、三世', group: '身份标识', type: 'number', privacy: false },
  { key: 'uid', label: '唯一ID', hint: '自动生成或按规则编号，如 F001；主键不可重复', group: '身份标识', type: 'text', privacy: false },
  { key: 'name', label: '谱名', hint: '族谱上的正式名字，如：李德明', group: '身份标识', type: 'text', privacy: false },
  { key: 'alias', label: '曾用名/小名', hint: '如有多个用逗号隔开，如：建国, 狗剩', group: '身份标识', type: 'text', privacy: false },
  { key: 'gender', label: '性别', hint: '男 / 女', group: '身份标识', type: 'select', privacy: false },
  { key: 'generationChar', label: '辈分/字派', hint: '所属字辈，如：德', group: '身份标识', type: 'text', privacy: false },
  { key: 'lifeStatus', label: '在世状态', hint: '在世 / 已故 / 失联 / 不详（上下滑动选择）', group: '身份标识', type: 'select', privacy: false },
  { key: 'childStatus', label: '子女身份', hint: '未记 / 嫡出 / 庶出 / 婢生 / 奸生 / 嗣子 / 养子；决定宗法地位与继承顺序', group: '身份标识', type: 'select', privacy: false },
  { key: 'birthDate', label: '出生日期', hint: '拉起日历选择（公历），或手填农历 1980年农历四月六', group: '时间信息', type: 'date', privacy: false },
  { key: 'deathDate', label: '逝世日期', hint: '格式同上，在世者留空', group: '时间信息', type: 'date', privacy: false },
  { key: 'birthPlace', label: '出生地', hint: '省-市-县-乡镇-村，如：广东-梅州-兴宁-罗岗镇', group: '时间信息', type: 'text', privacy: false },
  { key: 'residence', label: '现居地', hint: '同上，精确到小区/街道', group: '时间信息', type: 'text', privacy: false },
  { key: 'fatherId', label: '父亲ID', hint: '填写父亲的【唯一ID】，如：F000', group: '亲属关系', type: 'relation', privacy: false },
  { key: 'motherId', label: '母亲ID', hint: '填写母亲的【唯一ID】，如：M050', group: '亲属关系', type: 'relation', privacy: false },
  { key: 'spouses', label: '配偶关系', hint: '支持多位配偶：元配 / 继室 / 妾，按先后顺序记录', group: '亲属关系', type: 'relation', privacy: false },
  { key: 'rank', label: '排行', hint: '第几子/女，如：长子、次女、三子', group: '亲属关系', type: 'text', privacy: false },
  { key: 'adoption', label: '过继/出嗣', hint: '若有过继，填“过继自XX”或“出嗣给XX”', group: '亲属关系', type: 'text', privacy: false },
  { key: 'education', label: '学历/学位', hint: '如：本科-华南理工大学', group: '生平履历', type: 'text', privacy: false },
  { key: 'occupation', label: '职业/职务', hint: '如：高级工程师、村支书', group: '生平履历', type: 'text', privacy: false },
  { key: 'biography', label: '生平简介', hint: '500字以内，记录重大成就、品德、事迹', group: '生平履历', type: 'text', privacy: false },
  { key: 'graveInfo', label: '墓葬信息', hint: '地点、山向、碑文摘要；可拾取GPS经纬度与海拔', group: '生平履历', type: 'grave', privacy: false },
  { key: 'phone', label: '手机号', hint: '仅管理员可见，用于核实信息', group: '联系方式', type: 'text', privacy: true },
  { key: 'wechat', label: '微信号', hint: '用于建立家族群或电子族谱推送', group: '联系方式', type: 'text', privacy: true },
  { key: 'avatar', label: '头像', hint: '点击头像更换头像图片', group: '图像信息', type: 'image', privacy: false },
  { key: 'photos', label: '照片视频', hint: '用于上传及展示相片、视频资料（拉起图库/相机/文件管理器）', group: '图像信息', type: 'media', privacy: false }
];

/** 创建空白人物 */
export function createEmptyPerson(): Person {
  const p: Person = new Person();
  p.createdAt = Date.now();
  p.updatedAt = p.createdAt;
  return p;
}

/** 深拷贝人物（避免状态引用串改） */
export function clonePerson(src: Person): Person {
  const p: Person = new Person();
  p.key = src.key;
  p.uid = src.uid;
  p.generation = src.generation;
  p.name = src.name;
  p.alias = src.alias;
  p.gender = src.gender;
  p.generationChar = src.generationChar;
  p.lifeStatus = src.lifeStatus;
  p.childStatus = src.childStatus;
  p.birthDate = src.birthDate;
  p.birthCalendar = src.birthCalendar;
  p.deathDate = src.deathDate;
  p.deathCalendar = src.deathCalendar;
  p.birthPlace = src.birthPlace;
  p.residence = src.residence;
  p.fatherId = src.fatherId;
  p.motherId = src.motherId;
  p.spouseId = src.spouseId;
  p.spouses = src.spouses.map((r: SpouseRelation): SpouseRelation => cloneSpouseRelation(r));
  p.rank = src.rank;
  p.adoption = src.adoption;
  p.education = src.education;
  p.occupation = src.occupation;
  p.biography = src.biography;
  p.graveInfo = src.graveInfo;
  p.graveLng = src.graveLng;
  p.graveLat = src.graveLat;
  p.graveAltitude = src.graveAltitude;
  p.phone = src.phone;
  p.wechat = src.wechat;
  p.avatar = src.avatar;
  p.videos = src.videos;
  p.photos = src.photos;
  p.createdAt = src.createdAt;
  p.updatedAt = src.updatedAt;
  return p;
}