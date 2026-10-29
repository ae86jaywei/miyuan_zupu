import { cloudDatabase } from '@kit.CloudFoundationKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountService } from './AccountService';
import { GenealogyService } from './GenealogyService';
import { GraveEntry, num, str } from '../model/FamilyDomain';
import { CloudGraveLocation } from '../model/FamilyModels';

const TAG: string = '[Genealogy][Grave]';
const TABLE_GRAVE: string = 'grave_location';
const ZONE_NAME: string = 'miyuanfamily';
/** 全局重读：不分家族地列出全部公开墓穴（祭祖寻墓场景，任何人可查） */
const MAX_ROWS: number = 500;

/**
 * 祭祖寻墓（方案 §五.8、§七 GraveMap 行）。
 *
 * 数据来源：**公开对象类型 FamilyGraveLocation**（端侧 Authenticated 可直读），
 * 不需要 Membership、不需要云函数鉴权 —— 这正是它能被「任意登录用户」查到的原因。
 *
 * 同时把读到的行写入本地 grave_location 表：山里常常没有信号，
 * 离线时仍能打开寻墓页看到上次缓存的位置。
 */
export class GraveService {
  private static instance: GraveService | null = null;

  static getInstance(): GraveService {
    if (GraveService.instance === null) {
      GraveService.instance = new GraveService();
    }
    return GraveService.instance;
  }

  static async ensureTable(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_GRAVE} (
      grave_id TEXT PRIMARY KEY,
      family_id TEXT,
      uid TEXT,
      person_name TEXT,
      generation INTEGER,
      book_title TEXT,
      grave_name TEXT,
      lng REAL,
      lat REAL,
      altitude REAL,
      facing TEXT,
      bearing TEXT,
      route_note TEXT,
      photo_refs TEXT,
      visibility TEXT,
      precision TEXT,
      rev INTEGER,
      updated_at INTEGER
    )`);
  }

  /**
   * 从云端公开表读取（任意登录用户可读）。
   * @param familyId 为空表示「全部家族」；否则只取该家族
   * @param keyword 关键字（人物名/谱名/墓地名/路线）
   */
  async loadPublic(familyId: string, keyword: string): Promise<GraveEntry[]> {
    const out: GraveEntry[] = [];
    if (!AccountService.getInstance().isCloudReady()) {
      return await this.loadCached(familyId, keyword);
    }
    try {
      const zone: cloudDatabase.DatabaseZone = cloudDatabase.zone(ZONE_NAME);
      const query: cloudDatabase.DatabaseQuery<CloudGraveLocation> =
        new cloudDatabase.DatabaseQuery<CloudGraveLocation>(CloudGraveLocation);
      // 只查公开可见的（FAMILY_ONLY 的行本就不在公开表里，这里再加一层防御性过滤）
      query.equalTo('visibility', 'PUBLIC');
      if (familyId.length > 0) {
        query.equalTo('familyId', familyId);
      }
      query.limit(MAX_ROWS);
      const rows: CloudGraveLocation[] = await zone.query(query);
      for (let i: number = 0; i < rows.length; i++) {
        const entry: GraveEntry = GraveService.fromCloudRow(rows[i]);
        if (GraveService.matches(entry, keyword)) {
          out.push(entry);
        }
      }
      await this.cacheEntries(out);
      return out;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'query public graves failed: %{public}s', JSON.stringify(err));
      // 云端不可用时回落到本地缓存（离线寻墓）
      return await this.loadCached(familyId, keyword);
    }
  }

  /** 由同步回放写入本地缓存（sync-pull 返回的 graves） */
  async cacheRows(rows: Record<string, Object>[]): Promise<void> {
    const list: GraveEntry[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const g: GraveEntry = new GraveEntry();
      g.graveId = str(rows[i], 'graveId');
      g.familyId = str(rows[i], 'familyId');
      g.uid = str(rows[i], 'uid');
      g.personName = str(rows[i], 'personName');
      g.generation = num(rows[i], 'generation');
      g.bookTitle = str(rows[i], 'bookTitle');
      g.graveName = str(rows[i], 'graveName');
      g.lng = num(rows[i], 'lng');
      g.lat = num(rows[i], 'lat');
      g.altitude = num(rows[i], 'altitude');
      g.facing = str(rows[i], 'facing');
      g.bearing = str(rows[i], 'bearing');
      g.routeNote = str(rows[i], 'routeNote');
      g.photoRefs = str(rows[i], 'photoRefs');
      g.visibility = str(rows[i], 'visibility').length > 0 ? str(rows[i], 'visibility') : 'PUBLIC';
      g.precision = str(rows[i], 'precision').length > 0 ? str(rows[i], 'precision') : 'EXACT';
      g.rev = num(rows[i], 'rev');
      g.updatedAt = num(rows[i], 'updatedAt');
      if (g.graveId.length > 0) {
        list.push(g);
      }
    }
    await this.cacheEntries(list);
  }

  /** 本地缓存读取（离线寻墓） */
  async loadCached(familyId: string, keyword: string): Promise<GraveEntry[]> {
    const out: GraveEntry[] = [];
    const svc: GenealogyService = GenealogyService.getInstance();
    const store: relationalStore.RdbStore | null = svc.getStore();
    if (store === null) {
      return out;
    }
    await GraveService.ensureTable(store);
    const sql: string = familyId.length > 0
      ? `SELECT * FROM ${TABLE_GRAVE} WHERE family_id = ? ORDER BY updated_at DESC LIMIT ${MAX_ROWS}`
      : `SELECT * FROM ${TABLE_GRAVE} ORDER BY updated_at DESC LIMIT ${MAX_ROWS}`;
    const args: relationalStore.ValueType[] = familyId.length > 0 ? [familyId] : [];
    const rs: relationalStore.ResultSet = await store.querySql(sql, args);
    try {
      while (rs.goToNextRow()) {
        const g: GraveEntry = new GraveEntry();
        g.graveId = readText(rs, 'grave_id');
        g.familyId = readText(rs, 'family_id');
        g.uid = readText(rs, 'uid');
        g.personName = readText(rs, 'person_name');
        g.generation = readLong(rs, 'generation');
        g.bookTitle = readText(rs, 'book_title');
        g.graveName = readText(rs, 'grave_name');
        g.lng = readDouble(rs, 'lng');
        g.lat = readDouble(rs, 'lat');
        g.altitude = readDouble(rs, 'altitude');
        g.facing = readText(rs, 'facing');
        g.bearing = readText(rs, 'bearing');
        g.routeNote = readText(rs, 'route_note');
        g.photoRefs = readText(rs, 'photo_refs');
        g.visibility = readText(rs, 'visibility');
        g.precision = readText(rs, 'precision');
        g.rev = readLong(rs, 'rev');
        g.updatedAt = readLong(rs, 'updated_at');
        if (GraveService.matches(g, keyword)) {
          out.push(g);
        }
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 写入本地缓存 */
  async cacheEntries(list: GraveEntry[]): Promise<void> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const store: relationalStore.RdbStore | null = svc.getStore();
    if (store === null || list.length === 0) {
      return;
    }
    await GraveService.ensureTable(store);
    for (let i: number = 0; i < list.length; i++) {
      const g: GraveEntry = list[i];
      await store.executeSql(`INSERT OR REPLACE INTO ${TABLE_GRAVE}
        (grave_id, family_id, uid, person_name, generation, book_title, grave_name, lng, lat, altitude,
         facing, bearing, route_note, photo_refs, visibility, precision, rev, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [g.graveId, g.familyId, g.uid, g.personName, g.generation, g.bookTitle, g.graveName, g.lng, g.lat,
          g.altitude, g.facing, g.bearing, g.routeNote, g.photoRefs, g.visibility, g.precision, g.rev,
          g.updatedAt]);
    }
  }

  /**
   * 更新墓葬位置（谱主/编辑者）。
   * @param visibility PUBLIC / FAMILY_ONLY —— FAMILY_ONLY 时云函数会把该行**从公开表删除**
   * @param evidence 位置变更（>50m）时必须提供的依据说明
   */
  async updateGrave(familyId: string, uid: string, grave: Record<string, Object>, visibility: string,
    precision: string, evidence: string): Promise<void> {
    await AccountService.getInstance().callFunction('grave-update', {
      'familyId': familyId, 'uid': uid, 'grave': grave, 'visibility': visibility,
      'precision': precision, 'evidence': evidence
    });
  }

  private static fromCloudRow(row: CloudGraveLocation): GraveEntry {
    const g: GraveEntry = new GraveEntry();
    g.graveId = row.graveId !== undefined ? row.graveId : '';
    g.familyId = row.familyId !== undefined ? row.familyId : '';
    g.uid = row.uid !== undefined ? row.uid : '';
    g.personName = row.personName !== undefined ? row.personName : '';
    g.generation = row.generation !== undefined ? row.generation : 0;
    g.bookTitle = row.bookTitle !== undefined ? row.bookTitle : '';
    g.graveName = row.graveName !== undefined ? row.graveName : '';
    g.lng = row.lng !== undefined ? row.lng : 0;
    g.lat = row.lat !== undefined ? row.lat : 0;
    g.altitude = row.altitude !== undefined ? row.altitude : 0;
    g.facing = row.facing !== undefined ? row.facing : '';
    g.bearing = row.bearing !== undefined ? row.bearing : '';
    g.routeNote = row.routeNote !== undefined ? row.routeNote : '';
    g.photoRefs = row.photoRefs !== undefined ? row.photoRefs : '';
    g.visibility = row.visibility !== undefined ? row.visibility : 'PUBLIC';
    g.precision = row.precision !== undefined ? row.precision : 'EXACT';
    g.rev = row.rev !== undefined ? row.rev : 0;
    g.updatedAt = row.updatedAt !== undefined ? row.updatedAt : 0;
    return g;
  }

  private static matches(g: GraveEntry, keyword: string): boolean {
    const kw: string = keyword.trim();
    if (kw.length === 0) {
      return true;
    }
    return g.personName.indexOf(kw) >= 0 || g.bookTitle.indexOf(kw) >= 0 || g.graveName.indexOf(kw) >= 0 ||
      g.routeNote.indexOf(kw) >= 0;
  }
}

function readText(rs: relationalStore.ResultSet, column: string): string {
  const idx: number = rs.getColumnIndex(column);
  if (idx < 0) {
    return '';
  }
  const v: string = rs.getString(idx);
  return v === null || v === undefined ? '' : v;
}

function readLong(rs: relationalStore.ResultSet, column: string): number {
  const idx: number = rs.getColumnIndex(column);
  return idx < 0 ? 0 : rs.getLong(idx);
}

function readDouble(rs: relationalStore.ResultSet, column: string): number {
  const idx: number = rs.getColumnIndex(column);
  return idx < 0 ? 0 : rs.getDouble(idx);
}
