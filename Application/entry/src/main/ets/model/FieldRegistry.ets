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