import { Person, SpouseRelation } from '../model/Person';

/** 字段级 diff（方案 §五.5：形如 {"birthDate":{"b":"","a":"1942-05"}}） */
export class FieldChange {
  b: Object | null = null;
  a: Object | null = null;
}

/**
 * 生成人物字段级 patch。
 *
 * - ADD：b 全部为空（云端没有旧值）；
 * - UPDATE：逐字段比较，只带出真正变化的字段（含隐私字段，云端会拆到 FamilyPrivate）；
 * - DELETE：返回空 patch（云端按 op=DELETE_REQ 处理）。
 *
 * 隐私字段（phone/wechat/residence）参与 diff：它们在云侧会落到 FamilyPrivate
 * （端侧永不可直读），不进 FamilyMember.payload。
 */
export function buildPersonPatch(before: Person | null, after: Person, op: string): string {
  const patch: Record<string, FieldChange> = {};
  if (op === 'DELETE' || op === 'DELETE_REQ') {
    return '{}';
  }
  const fields: string[] = TEXT_FIELDS;
  for (let i: number = 0; i < fields.length; i++) {
    const key: string = fields[i];
    const a: string = textOf(after, key);
    const b: string = before === null ? '' : textOf(before, key);
    if (op === 'ADD') {
      if (a.length > 0) {
        patch[key] = makeChange(null, a);
      }
    } else if (a !== b) {
      patch[key] = makeChange(b, a);
    }
  }
  const nums: string[] = NUMBER_FIELDS;
  for (let i: number = 0; i < nums.length; i++) {
    const key: string = nums[i];
    const a: number = numberOf(after, key);
    const b: number = before === null ? 0 : numberOf(before, key);
    if (op === 'ADD') {
      if (a !== 0) {
        patch[key] = makeChange(null, a);
      }
    } else if (a !== b) {
      patch[key] = makeChange(b, a);
    }
  }
  // 配偶关系（对象数组，整体替换）
  const spousesNow: string = JSON.stringify(after.spouses);
  const spousesBefore: string = before === null ? '[]' : JSON.stringify(before.spouses);
  if (op === 'ADD') {
    if (after.spouses.length > 0) {
      patch['spouses'] = makeChange(null, after.spouses);
    }
  } else if (spousesNow !== spousesBefore) {
    patch['spouses'] = makeChange(before === null ? [] : before.spouses, after.spouses);
  }
  return JSON.stringify(patch);
}

function makeChange(b: Object | null, a: Object): FieldChange {
  const c: FieldChange = new FieldChange();
  c.b = b;
  c.a = a;
  return c;
}

/** 文本字段（与云侧 PATCHABLE_FIELDS 保持一致） */
const TEXT_FIELDS: string[] = ['uid', 'name', 'alias', 'gender', 'generationChar', 'lifeStatus', 'childStatus',
  'birthDate', 'birthCalendar', 'deathDate', 'deathCalendar', 'birthPlace', 'residence', 'fatherId', 'motherId',
  'spouseId', 'rank', 'adoption', 'education', 'occupation', 'biography', 'graveInfo', 'phone', 'wechat',
  'avatar', 'videos', 'photos'];

/** 数值字段 */
const NUMBER_FIELDS: string[] = ['generation'];

function textOf(p: Person, key: string): string {
  switch (key) {
    case 'uid': return p.uid;
    case 'name': return p.name;
    case 'alias': return p.alias;
    case 'gender': return p.gender;
    case 'generationChar': return p.generationChar;
    case 'lifeStatus': return p.lifeStatus;
    case 'childStatus': return p.childStatus;
    case 'birthDate': return p.birthDate;
    case 'birthCalendar': return p.birthCalendar;
    case 'deathDate': return p.deathDate;
    case 'deathCalendar': return p.deathCalendar;
    case 'birthPlace': return p.birthPlace;
    case 'residence': return p.residence;
    case 'fatherId': return p.fatherId;
    case 'motherId': return p.motherId;
    case 'spouseId': return p.spouseId;
    case 'rank': return p.rank;
    case 'adoption': return p.adoption;
    case 'education': return p.education;
    case 'occupation': return p.occupation;
    case 'biography': return p.biography;
    case 'graveInfo': return p.graveInfo;
    case 'phone': return p.phone;
    case 'wechat': return p.wechat;
    case 'avatar': return p.avatar;
    case 'videos': return p.videos;
    case 'photos': return p.photos;
    default: return '';
  }
}

function numberOf(p: Person, key: string): number {
  return key === 'generation' ? p.generation : 0;
}

/** 从 patch JSON 还原为「字段名 → {b, a}」便于审核页展示 */
export function parsePatchJson(patchJson: string): Map<string, FieldChange> {
  const out: Map<string, FieldChange> = new Map<string, FieldChange>();
  if (patchJson === undefined || patchJson.length === 0) {
    return out;
  }
  let raw: Record<string, Record<string, Object>>;
  try {
    raw = JSON.parse(patchJson) as Record<string, Record<string, Object>>;
  } catch (e) {
    return out;
  }
  const keys: string[] = Object.keys(raw);
  for (let i: number = 0; i < keys.length; i++) {
    const item: Record<string, Object> = raw[keys[i]];
    const c: FieldChange = new FieldChange();
    c.b = item['b'] !== undefined ? item['b'] : null;
    c.a = item['a'] !== undefined ? item['a'] : null;
    out.set(keys[i], c);
  }
  return out;
}

/** 字段中文名（审核 diff 视图用） */
export function fieldLabel(key: string): string {
  const idx: number = key.indexOf('.');
  const root: string = idx >= 0 ? key.substring(0, idx) : key;
  switch (root) {
    case 'name': return '谱名';
    case 'alias': return '曾用名';
    case 'gender': return '性别';
    case 'generation': return '世代';
    case 'generationChar': return '字派';
    case 'lifeStatus': return '在世状态';
    case 'childStatus': return '子女身份';
    case 'birthDate': return '出生日期';
    case 'birthCalendar': return '出生历法';
    case 'deathDate': return '逝世日期';
    case 'deathCalendar': return '逝世历法';
    case 'birthPlace': return '出生地';
    case 'residence': return '现居地';
    case 'fatherId': return '父亲ID';
    case 'motherId': return '母亲ID';
    case 'spouses': return '配偶';
    case 'rank': return '排行';
    case 'adoption': return '过继/出嗣';
    case 'education': return '学历';
    case 'occupation': return '职业';
    case 'biography': return '生平简介';
    case 'graveInfo': return '墓葬信息';
    case 'phone': return '手机号';
    case 'wechat': return '微信号';
    case 'avatar': return '头像';
    case 'videos': return '视频';
    case 'photos': return '相片';
    case 'uid': return '唯一ID';
    default: return root;
  }
}

/** 值转展示文本（配偶关系等对象数组做可读化） */
export function displayValue(value: Object | null): string {
  if (value === null || value === undefined) {
    return '（空）';
  }
  if (typeof value === 'string') {
    return (value as string).length === 0 ? '（空）' : value as string;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  const arr: Object[] = value as Object[];
  if (arr !== undefined && arr !== null && arr.length !== undefined) {
    const parts: string[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      const rel: SpouseRelation = arr[i] as SpouseRelation;
      if (rel !== null && rel !== undefined && rel.uid !== undefined) {
        parts.push(rel.uid + (rel.relation !== undefined ? '（' + rel.relation + '）' : ''));
      }
    }
    return parts.length > 0 ? parts.join('、') : '（空）';
  }
  return JSON.stringify(value);
}
