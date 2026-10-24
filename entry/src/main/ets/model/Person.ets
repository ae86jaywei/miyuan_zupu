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
  /** 配偶ID（扩展字段，夫妻关系） */
  spouseId: string = '';
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
  { key: 'birthDate', label: '出生日期', hint: '拉起日历选择（公历），或手填农历 1980年农历四月六', group: '时间信息', type: 'date', privacy: false },
  { key: 'deathDate', label: '逝世日期', hint: '格式同上，在世者留空', group: '时间信息', type: 'date', privacy: false },
  { key: 'birthPlace', label: '出生地', hint: '省-市-县-乡镇-村，如：广东-梅州-兴宁-罗岗镇', group: '时间信息', type: 'text', privacy: false },
  { key: 'residence', label: '现居地', hint: '同上，精确到小区/街道', group: '时间信息', type: 'text', privacy: false },
  { key: 'fatherId', label: '父亲ID', hint: '填写父亲的【唯一ID】，如：F000', group: '亲属关系', type: 'relation', privacy: false },
  { key: 'motherId', label: '母亲ID', hint: '填写母亲的【唯一ID】，如：M050', group: '亲属关系', type: 'relation', privacy: false },
  { key: 'spouseId', label: '配偶ID', hint: '扩展字段：配偶的唯一ID', group: '亲属关系', type: 'relation', privacy: false },
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
  p.birthDate = src.birthDate;
  p.birthCalendar = src.birthCalendar;
  p.deathDate = src.deathDate;
  p.deathCalendar = src.deathCalendar;
  p.birthPlace = src.birthPlace;
  p.residence = src.residence;
  p.fatherId = src.fatherId;
  p.motherId = src.motherId;
  p.spouseId = src.spouseId;
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