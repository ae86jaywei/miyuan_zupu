import { CALENDAR_OPTIONS, CHILD_MARK_OPTIONS, CLAN_RANK_OPTIONS, GENDER_OPTIONS, LIFE_STATUS_OPTIONS } from './Enums';
import { CHILD_STATUS_OPTIONS, FIELD_METAS, FieldMeta } from './Person';

/**
 * 字段编辑器说明：把 FIELD_METAS 的 type/key 映射为表单控件与选项。
 * 表单只依赖这里，不再各自维护一份 label/hint/options。
 */

/** 父母（未收录）在世状态：只取在世/已故两种 */
export const PARENT_LIFE_STATUS_OPTIONS: string[] = ['在世', '已故'];

/** 按 key 取字段元数据；未登记时返回最小可用定义，避免调用方判空 */
export function fieldMetaOf(key: string): FieldMeta {
  for (let i: number = 0; i < FIELD_METAS.length; i = i + 1) {
    if (FIELD_METAS[i].key === key) {
      return FIELD_METAS[i];
    }
  }
  const meta: FieldMeta = { key: key, label: key, hint: '', group: '', type: 'text', privacy: false };
  return meta;
}

/** 字段的可选项；返回空数组表示用文本输入 */
export function editorOptionsOf(key: string): string[] {
  switch (key) {
    case 'gender':
      return GENDER_OPTIONS;
    case 'lifeStatus':
      return LIFE_STATUS_OPTIONS;
    case 'childStatus':
      return CHILD_STATUS_OPTIONS;
    case 'childMark':
      return CHILD_MARK_OPTIONS;
    case 'rank':
      return CLAN_RANK_OPTIONS;
    case 'fatherLifeStatus':
    case 'motherLifeStatus':
      return PARENT_LIFE_STATUS_OPTIONS;
    case 'birthCalendar':
    case 'deathCalendar':
      return CALENDAR_OPTIONS;
    default:
      return [];
  }
}

/** 是否为日期字段（由日期控件渲染） */
export function isDateField(key: string): boolean {
  return key === 'birthDate' || key === 'deathDate';
}
