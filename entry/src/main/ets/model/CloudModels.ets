import { cloudDatabase } from '@kit.CloudFoundationKit';
import { Person, SpouseRelation, createEmptyPerson } from './Person';

/**
 * 云数据库对象类型：族谱成员（精简结构）。
 *
 * 只有少量字段用于云端过滤与排序，成员完整信息序列化到 payload。
 * 这样 AGC 控制台只需维护 8 个字段，后续 Person 增删字段无需改云端结构。
 * 字段名必须与 schema.json 保持一致。
 */
export class CloudFamilyMember extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyMember';
  }

  public memberId: string | undefined;
  public userId: string | undefined;
  public name: string | undefined;
  public generation: number | undefined;
  public parentId: string | undefined;
  public updatedAt: number | undefined;
  public deleted: boolean | undefined;
  /** 成员完整信息：Person 的 JSON 序列化结果 */
  public payload: string | undefined;
}

/**
 * 云数据库对象类型：成员媒体索引。
 * 文件本体保存在 Cloud Storage，本对象只保存 cloudPath 等索引信息。
 */
export class CloudFamilyMedia extends cloudDatabase.DatabaseObject {
  public naturalbase_ClassName(): string {
    return 'FamilyMedia';
  }

  public mediaId: string | undefined;
  public userId: string | undefined;
  public memberId: string | undefined;
  public type: string | undefined;
  public cloudPath: string | undefined;
  public fileName: string | undefined;
  public size: number | undefined;
  public uploadedAt: number | undefined;
  public deleted: boolean | undefined;
}

/** 云端占用统计 */
export class CloudUsage {
  memberCount: number = 0;
  mediaCount: number = 0;
  imageCount: number = 0;
  videoCount: number = 0;
  totalBytes: number = 0;
}

/** 备份结果 */
export class BackupResult {
  memberCount: number = 0;
  mediaUploaded: number = 0;
  mediaSkipped: number = 0;
  warnings: string[] = [];
}

/** 恢复结果 */
export class RestoreResult {
  memberCount: number = 0;
  imageDownloaded: number = 0;
  videoDeferred: number = 0;
  warnings: string[] = [];
}

/** 把本地人物转换为云数据库记录 */
export function personToCloudMember(person: Person, userId: string): CloudFamilyMember {
  const doc: CloudFamilyMember = new CloudFamilyMember();
  doc.memberId = person.uid;
  doc.userId = userId;
  doc.name = person.name;
  doc.generation = person.generation;
  doc.parentId = person.fatherId;
  doc.updatedAt = person.updatedAt > 0 ? person.updatedAt : Date.now();
  doc.deleted = false;
  doc.payload = JSON.stringify(person);
  return doc;
}

function parsePersonPayload(json: string | undefined): Person | null {
  if (json === undefined || json.length === 0) {
    return null;
  }
  try {
    return JSON.parse(json) as Person;
  } catch (err) {
    return null;
  }
}

function asText(value: string | undefined, fallback: string): string {
  return value !== undefined && value.length > 0 ? value : fallback;
}

function asNumber(value: number | undefined, fallback: number): number {
  return value !== undefined ? value : fallback;
}

function normalizeSpouses(src: SpouseRelation[] | undefined): SpouseRelation[] {
  const list: SpouseRelation[] = [];
  if (src === undefined) {
    return list;
  }
  for (let i: number = 0; i < src.length; i++) {
    const from: SpouseRelation = src[i];
    const item: SpouseRelation = new SpouseRelation();
    item.uid = asText(from.uid, '');
    item.relation = asText(from.relation, '');
    item.level = asText(from.level, '');
    item.order = asNumber(from.order, 0);
    list.push(item);
  }
  return list;
}

/** 把云数据库记录还原为本地人物 */
export function cloudMemberToPerson(doc: CloudFamilyMember): Person {
  const p: Person = createEmptyPerson();
  p.uid = asText(doc.memberId, '');
  p.name = asText(doc.name, '');
  p.generation = asNumber(doc.generation, 1);
  p.fatherId = asText(doc.parentId, '');
  p.updatedAt = asNumber(doc.updatedAt, Date.now());

  const src: Person | null = parsePersonPayload(doc.payload);
  if (src === null) {
    return p;
  }
  p.uid = asText(src.uid, p.uid);
  p.name = asText(src.name, p.name);
  p.generation = asNumber(src.generation, p.generation);
  p.fatherId = asText(src.fatherId, p.fatherId);
  p.updatedAt = asNumber(src.updatedAt, p.updatedAt);
  p.alias = asText(src.alias, '');
  p.gender = asText(src.gender, '男');
  p.generationChar = asText(src.generationChar, '');
  p.lifeStatus = asText(src.lifeStatus, '在世');
  p.childStatus = asText(src.childStatus, '未记');
  p.birthDate = asText(src.birthDate, '');
  p.birthCalendar = asText(src.birthCalendar, '公历');
  p.deathDate = asText(src.deathDate, '');
  p.deathCalendar = asText(src.deathCalendar, '公历');
  p.birthPlace = asText(src.birthPlace, '');
  p.residence = asText(src.residence, '');
  p.motherId = asText(src.motherId, '');
  p.spouseId = asText(src.spouseId, '');
  p.spouses = normalizeSpouses(src.spouses);
  p.rank = asText(src.rank, '');
  p.adoption = asText(src.adoption, '');
  p.education = asText(src.education, '');
  p.occupation = asText(src.occupation, '');
  p.biography = asText(src.biography, '');
  p.graveInfo = asText(src.graveInfo, '');
  p.graveLng = asNumber(src.graveLng, 0);
  p.graveLat = asNumber(src.graveLat, 0);
  p.graveAltitude = asNumber(src.graveAltitude, 0);
  p.phone = asText(src.phone, '');
  p.wechat = asText(src.wechat, '');
  p.avatar = asText(src.avatar, '');
  p.videos = asText(src.videos, '');
  p.photos = asText(src.photos, '');
  p.createdAt = asNumber(src.createdAt, Date.now());
  return p;
}
