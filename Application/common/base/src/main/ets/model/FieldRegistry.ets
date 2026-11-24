import { FIELD_METAS } from './Person';

/**
 * 字段注册表（第一阶段）：先统一「字段清单 + 中文名」。
 *
 * 现状：Person 字段在模型、SQL、云同步、补丁、CSV、表单、详情等 10 处各维护一份。
 * 这里先收敛协作补丁需要的字段清单与中文名，避免新增字段时漏改；
 * 后续把 SQL 列、CSV 列、云 payload 也迁到同一份元数据上。
 */

/** 协作补丁文本字段（必须与云侧 PATCHABLE_FIELDS 保持一致） */
export const PATCH_TEXT_FIELD_KEYS: string[] = ['uid', 'name', 'courtesyName', 'artName', 'alias', 'gender',
  'generationChar', 'lifeStatus', 'childStatus',
  'childMark', 'childMarkTarget', 'childMarkSource',
  'birthDate', 'birthCalendar', 'deathDate', 'deathCalendar', 'birthPlace', 'residence',
  'fatherId', 'fatherName', 'fatherLifeStatus',
  'motherId', 'motherName', 'motherLifeStatus',
  'spouseId', 'marriageStatus', 'spouseFamily',
  'rank', 'adoption', 'education', 'occupation', 'biography', 'graveInfo',
  'phone', 'wechat', 'avatar', 'videos', 'photos'];

/** 协作补丁数值字段 */
export const PATCH_NUMBER_FIELD_KEYS: string[] = ['generation', 'childMarkSeq'];

/** 协作补丁布尔字段 */
export const PATCH_BOOLEAN_FIELD_KEYS: string[] = ['childless'];

/** FIELD_METAS 未覆盖或审核页需要简写的字段名 */
const EXTRA_LABELS: Map<string, string> = new Map<string, string>();
EXTRA_LABELS.set('birthCalendar', '出生历法');
EXTRA_LABELS.set('deathCalendar', '逝世历法');
EXTRA_LABELS.set('spouses', '配偶');
EXTRA_LABELS.set('alias', '曾用名');
EXTRA_LABELS.set('generationChar', '字派');
EXTRA_LABELS.set('education', '学历');
EXTRA_LABELS.set('occupation', '职业');
EXTRA_LABELS.set('photos', '相片');
EXTRA_LABELS.set('spouseId', '配偶ID');
EXTRA_LABELS.set('videos', '视频');

/**
 * 字段中文名：优先取 Person.FIELD_METAS，避免与表单/详情重复维护；
 * 审核页的简写名放在 EXTRA_LABELS。
 */
export function fieldLabelOf(key: string): string {
  const idx: number = key.indexOf('.');
  const root: string = idx >= 0 ? key.substring(0, idx) : key;
  const extra: string | undefined = EXTRA_LABELS.get(root);
  if (extra !== undefined) {
    return extra;
  }
  for (let i: number = 0; i < FIELD_METAS.length; i = i + 1) {
    if (FIELD_METAS[i].key === root) {
      return FIELD_METAS[i].label;
    }
  }
  return root;
}

/**
 * Person 表列定义：旧库补列由这张表驱动。
 * 新增字段时除 FIELD_METAS / PATCH 清单外，再补一行这里，旧库会自动 ALTER TABLE。
 * 类型使用 ALTER TABLE 可接受的定义（NOT NULL 列一律带 DEFAULT）。
 */
export interface DbColumnDef {
  key: string;
  column: string;
  type: string;
}

export const PERSON_DB_COLUMNS: DbColumnDef[] = [
  { key: 'bookId', column: 'book_id', type: 'INTEGER DEFAULT 0' },
  { key: 'uid', column: 'uid', type: 'TEXT' },
  { key: 'generation', column: 'generation', type: 'INTEGER' },
  { key: 'name', column: 'name', type: 'TEXT' },
  { key: 'courtesyName', column: 'courtesy_name', type: 'TEXT' },
  { key: 'artName', column: 'art_name', type: 'TEXT' },
  { key: 'alias', column: 'alias', type: 'TEXT' },
  { key: 'gender', column: 'gender', type: 'TEXT' },
  { key: 'generationChar', column: 'generation_char', type: 'TEXT' },
  { key: 'lifeStatus', column: 'life_status', type: 'TEXT' },
  { key: 'childStatus', column: 'child_status', type: 'TEXT' },
  { key: 'childMark', column: 'child_mark', type: 'TEXT' },
  { key: 'childMarkTarget', column: 'child_mark_target', type: 'TEXT' },
  { key: 'childMarkSource', column: 'child_mark_source', type: 'TEXT' },
  { key: 'childMarkSeq', column: 'child_mark_seq', type: 'INTEGER' },
  { key: 'childless', column: 'childless', type: 'INTEGER' },
  { key: 'birthDate', column: 'birth_date', type: 'TEXT' },
  { key: 'birthCalendar', column: 'birth_calendar', type: 'TEXT' },
  { key: 'deathDate', column: 'death_date', type: 'TEXT' },
  { key: 'deathCalendar', column: 'death_calendar', type: 'TEXT' },
  { key: 'birthPlace', column: 'birth_place', type: 'TEXT' },
  { key: 'residence', column: 'residence', type: 'TEXT' },
  { key: 'fatherId', column: 'father_id', type: 'TEXT' },
  { key: 'fatherName', column: 'father_name', type: 'TEXT' },
  { key: 'fatherLifeStatus', column: 'father_life_status', type: 'TEXT' },
  { key: 'motherId', column: 'mother_id', type: 'TEXT' },
  { key: 'motherName', column: 'mother_name', type: 'TEXT' },
  { key: 'motherLifeStatus', column: 'mother_life_status', type: 'TEXT' },
  { key: 'spouseId', column: 'spouse_id', type: 'TEXT' },
  { key: 'marriageStatus', column: 'marriage_status', type: 'TEXT' },
  { key: 'spouseFamily', column: 'spouse_family', type: 'TEXT' },
  { key: 'rank', column: 'rank', type: 'TEXT' },
  { key: 'adoption', column: 'adoption', type: 'TEXT' },
  { key: 'education', column: 'education', type: 'TEXT' },
  { key: 'occupation', column: 'occupation', type: 'TEXT' },
  { key: 'biography', column: 'biography', type: 'TEXT' },
  { key: 'graveInfo', column: 'grave_info', type: 'TEXT' },
  { key: 'graveLng', column: 'grave_lng', type: 'REAL' },
  { key: 'graveLat', column: 'grave_lat', type: 'REAL' },
  { key: 'graveAltitude', column: 'grave_altitude', type: 'REAL' },
  { key: 'phone', column: 'phone', type: 'TEXT' },
  { key: 'wechat', column: 'wechat', type: 'TEXT' },
  { key: 'avatar', column: 'avatar', type: 'TEXT' },
  { key: 'videos', column: 'videos', type: 'TEXT' },
  { key: 'photos', column: 'photos', type: 'TEXT' },
  { key: 'createdAt', column: 'created_at', type: 'INTEGER' },
  { key: 'updatedAt', column: 'updated_at', type: 'INTEGER' },
  { key: 'rev', column: 'rev', type: 'INTEGER DEFAULT 0' },
  { key: 'baseRev', column: 'base_rev', type: 'INTEGER DEFAULT 0' },
  { key: 'dirty', column: 'dirty', type: 'INTEGER DEFAULT 0' },
  { key: 'deletedAt', column: 'deleted_at', type: 'INTEGER DEFAULT 0' }
];

/** CSV 导出列（顺序即表格列顺序，与 ExportService.fieldOf 的 case 对应） */
export const PERSON_CSV_COLUMNS: string[] = [
  '世代', '唯一ID', '谱名', '字', '号', '曾用名/小名', '性别', '辈分/字派', '在世状态', '子女身份',
  '标记', '出嗣/兼祧对象', '入继来源', '在源第几子', '无出',
  '出生日期', '逝世日期', '出生地', '现居地',
  '父亲ID', '父名（未收录）', '父名在世状态', '母亲ID', '母名（未收录）', '母名在世状态',
  '配偶关系', '婚配状态', '夫家/婆家（未收录）', '排行', '过继/出嗣/兼祧',
  '学历/学位', '职业/职务', '生平简介', '墓葬信息', '手机号', '微信号', '头像'
];