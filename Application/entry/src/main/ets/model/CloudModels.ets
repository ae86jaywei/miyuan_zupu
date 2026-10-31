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

/**
 * 云端成员 payload 包装。
 * 多族谱下需要记录人物所属族谱，避免恢复时全部混入同一部族谱。
 * 旧版本 payload 直接是 Person 的 JSON，解析时做兼容。
 */
export class CloudMemberPayload {
  bookKey?: number;
  bookTitle?: string;
  person?: Person | null;
}

/** 生成带族谱前缀的云端成员ID（旧版无前缀，保持兼容） */
export function cloudMemberKey(bookKey: number, uid: string): string {
  return bookKey > 0 ? 'b' + bookKey.toString() + '#' + uid : uid;
}

/** 从云端成员ID中解析族谱ID（无前缀视为 0） */
export function parseBookKeyFromMemberId(memberId: string): number {
  if (memberId.length > 2 && memberId.charAt(0) === 'b') {
    const idx: number = memberId.indexOf('#');
    if (idx > 1) {
      const num: number = Number.parseInt(memberId.substring(1, idx), 10);
      if (num > 0) {
        return num;
      }
    }
  }
  return 0;
}

/** 提取云端成员ID中的唯一ID（去掉族谱前缀） */
export function memberUid(memberId: string): string {
  const idx: number = memberId.indexOf('#');
  return idx >= 0 ? memberId.substring(idx + 1) : memberId;
}

/** 活人隐私字段：写云前必须剔除（方案 §八.2 第 1 步「payload 脱敏」） */
export const PRIVATE_FIELDS: string[] = ['phone', 'wechat', 'residence'];

/** 墓葬坐标字段：不在 payload 中留存，迁往公开对象类型 FamilyGraveLocation（§五.8） */
export const GRAVE_COORD_FIELDS: string[] = ['graveLng', 'graveLat', 'graveAltitude'];

/**
 * 生成「脱敏副本」：剔除活人隐私字段与墓葬坐标，其余字段原样保留。
 *
 * ⚠️ 两步不能混（方案 §八.2）：
 *   - 活人隐私字段只能「剔除」（权限仍在云函数后面，进 FamilyPrivate）；
 *   - 墓葬坐标只能「迁出去公开」（进 FamilyGraveLocation），不能又剔除又想公开。
 */
export function sanitizePersonForCloud(person: Person): Person {
  const copy: Person = clonePersonForCloud(person);
  copy.phone = '';
  copy.wechat = '';
  copy.residence = '';
  copy.graveLng = 0;
  copy.graveLat = 0;
  copy.graveAltitude = 0;
  return copy;
}

/** 用于写云的深拷贝（避免把本地对象引用直接序列化进 payload） */
function clonePersonForCloud(src: Person): Person {
  const json: string = JSON.stringify(src);
  const p: Person = JSON.parse(json) as Person;
  if (p.spouses === undefined || p.spouses === null) {
    p.spouses = [];
  }
  return p;
}

/** 生成墓碑记录（不再物理删除，供「一人删一人改」提示，方案 §五.3 / §九） */
export function personToCloudTombstone(person: Person, userId: string, bookKey: number = 0,
  bookTitle: string = ''): CloudFamilyMember {
  const doc: CloudFamilyMember = personToCloudMember(person, userId, bookKey, bookTitle);
  doc.deleted = true;
  doc.parentId = '';
  const wrapper: CloudMemberPayload = new CloudMemberPayload();
  wrapper.bookKey = bookKey;
  wrapper.bookTitle = bookTitle;
  wrapper.person = null;
  doc.payload = JSON.stringify(wrapper);
  return doc;
}

/**
 * 把本地人物转换为云端备份记录（带族谱信息）。
 * **payload 中的 person 已脱敏**——这是现状漏洞（§一.4 / §十三.2）的止血点。
 */
export function personToCloudMember(person: Person, userId: string, bookKey: number = 0,
  bookTitle: string = ''): CloudFamilyMember {
  const doc: CloudFamilyMember = new CloudFamilyMember();
  doc.memberId = cloudMemberKey(bookKey, person.uid);
  doc.userId = userId;
  doc.name = person.name;
  doc.generation = person.generation;
  doc.parentId = person.fatherId;
  doc.updatedAt = person.updatedAt > 0 ? person.updatedAt : Date.now();
  doc.deleted = false;
  const wrapper: CloudMemberPayload = new CloudMemberPayload();
  wrapper.bookKey = bookKey;
  wrapper.bookTitle = bookTitle;
  wrapper.person = sanitizePersonForCloud(person);
  doc.payload = JSON.stringify(wrapper);
  return doc;
}

/** 读取云端成员记录（兼容旧版 payload 直接存 Person 的情况） */
export function readCloudMember(doc: CloudFamilyMember): CloudMemberPayload {
  const out: CloudMemberPayload = new CloudMemberPayload();
  const rawId: string = doc.memberId !== undefined ? doc.memberId : '';
  out.bookKey = parseBookKeyFromMemberId(rawId);
  out.bookTitle = '';
  out.person = null;
  const json: string = doc.payload !== undefined ? doc.payload : '';
  if (json.length === 0) {
    return out;
  }
  try {
    const parsed: CloudMemberPayload = JSON.parse(json) as CloudMemberPayload;
    if (parsed.person !== undefined && parsed.person !== null) {
      out.person = parsed.person;
      out.bookKey = parsed.bookKey !== undefined ? parsed.bookKey : out.bookKey;
      out.bookTitle = parsed.bookTitle !== undefined ? parsed.bookTitle : '';
      return out;
    }
    // 旧格式：payload 直接是 Person
    const legacy: Person = JSON.parse(json) as Person;
    out.person = legacy;
    return out;
  } catch (err) {
    return out;
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
  p.uid = memberUid(asText(doc.memberId, ''));
  p.name = asText(doc.name, '');
  p.generation = asNumber(doc.generation, 1);
  p.fatherId = asText(doc.parentId, '');
  p.updatedAt = asNumber(doc.updatedAt, Date.now());

  const payload: CloudMemberPayload = readCloudMember(doc);
  const src: Person | null = payload.person !== undefined ? payload.person : null;
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