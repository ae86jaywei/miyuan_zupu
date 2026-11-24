import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountService } from './AccountService';
import { GenealogyService } from './GenealogyService';
import { FamilyService } from './FamilyService';
import { GraveEntry, num, objectList, str } from 'common_base';
import { CloudFunctionClient } from './CloudFunctionClient';

const TAG: string = '[Genealogy][Grave]';
const TABLE_GRAVE: string = 'grave_location';
/** 单次最多读取 200 行（与云函数 grave-list-public 的 limit 上限一致） */
const MAX_ROWS: number = 200;

/**
 * 祭祖寻墓（方案 §五.8、§七 GraveMap 行）。
 *
 * 数据来源：FamilyGraveLocation，但**必须经云函数 grave-list-public 按 Membership 校验**，
 * 只有已加入该家族的成员才能读取本家族墓葬；对象类型本身不再对端侧开放直读。
 *
 * 同时把读到的行写入本地 grave_location 表：山里常常没有信号，
 * 离线时仍能打开寻墓页看到上次缓存的位置（缓存读取同样要求成员身份）。
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

  /** 是否已加入当前家族（角色非空 = 拥有有效成员关系） */
  static hasMembership(): boolean {
    return FamilyService.getInstance().currentRole().length > 0;
  }

  /**
   * 读取当前家族的墓葬位置（仅家族成员可读）。
   *
   * 端侧不再直读云数据库，统一走云函数 grave-list-public：由云端按 Membership 校验，
   * 未加入家族一律查不到数据。
   * @param familyId 当前家族ID（必须非空）
   * @param keyword 关键字（人物名/谱名/墓地名/路线）
   */
  async loadPublic(familyId: string, keyword: string): Promise<GraveEntry[]> {
    const out: GraveEntry[] = [];
    if (familyId.length === 0 || !GraveService.hasMembership()) {
      return out;
    }
    if (!AccountService.getInstance().isCloudReady()) {
      return await this.loadCached(familyId, keyword);
    }
    try {
      const data: Record<string, Object> | null = await CloudFunctionClient.getInstance().call(
        'grave-list-public', {
          'familyId': familyId,
          'keyword': keyword,
          'limit': MAX_ROWS
        });
      const rows: Record<string, Object>[] = objectList(data, 'graves');
      for (let i: number = 0; i < rows.length; i++) {
        const entry: GraveEntry = GraveService.fromRecord(rows[i]);
        if (GraveService.matches(entry, keyword)) {
          out.push(entry);
        }
      }
      await this.cacheEntries(out);
      return out;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'query member graves failed: %{public}s', JSON.stringify(err));
      // 权限校验失败（非成员 / 授权到期）：绝不回落本地缓存，避免旧缓存被非成员读到
      if (CloudFunctionClient.errorCode(err as Error) === 403) {
        throw err as Error;
      }
      // 云端不可用时回落到本地缓存（离线寻墓）
      return await this.loadCached(familyId, keyword);
    }
  }

  /** 由同步回放写入本地缓存（sync-pull 返回的 graves） */
  async cacheRows(rows: Record<string, Object>[]): Promise<void> {
    const list: GraveEntry[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const g: GraveEntry = GraveService.fromRecord(rows[i]);
      if (g.graveId.length > 0) {
        list.push(g);
      }
    }
    await this.cacheEntries(list);
  }

  /** 本地缓存读取（离线寻墓）：同样要求已加入家族，避免残留缓存被非成员读到 */
  async loadCached(familyId: string, keyword: string): Promise<GraveEntry[]> {
    const out: GraveEntry[] = [];
    if (familyId.length === 0 || !GraveService.hasMembership()) {
      return out;
    }
    const svc: GenealogyService = GenealogyService.getInstance();
    const store: relationalStore.RdbStore | null = svc.getStore();
    if (store === null) {
      return out;
    }
    await GraveService.ensureTable(store);
    const sql: string = `SELECT * FROM ${TABLE_GRAVE} WHERE family_id = ? AND visibility = 'PUBLIC'
      ORDER BY updated_at DESC LIMIT ${MAX_ROWS}`;
    const args: relationalStore.ValueType[] = [familyId];
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
    // 500 行逐条 await 会在主线程产生大量 IPC；统一放进一个事务，失败整体回滚
    store.beginTransaction();
    let committed: boolean = false;
    try {
      for (let i: number = 0; i < list.length; i = i + 1) {
        const g: GraveEntry = list[i];
        await store.executeSql(`INSERT OR REPLACE INTO ${TABLE_GRAVE}
        (grave_id, family_id, uid, person_name, generation, book_title, grave_name, lng, lat, altitude,
         facing, bearing, route_note, photo_refs, visibility, precision, rev, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [g.graveId, g.familyId, g.uid, g.personName, g.generation, g.bookTitle, g.graveName, g.lng, g.lat,
            g.altitude, g.facing, g.bearing, g.routeNote, g.photoRefs, g.visibility, g.precision, g.rev,
            g.updatedAt]);
      }
      store.commit();
      committed = true;
    } finally {
      if (!committed) {
        store.rollBack();
      }
    }
  }

  /**
   * 更新墓葬位置（谱主/编辑者）。
   * @param visibility PUBLIC / FAMILY_ONLY —— FAMILY_ONLY 时云函数会把该行**从寻墓列表删除**
   * @param evidence 位置变更（>50m）时必须提供的依据说明
   */
  async updateGrave(familyId: string, uid: string, grave: Record<string, Object>, visibility: string,
    precision: string, evidence: string): Promise<void> {
    await CloudFunctionClient.getInstance().call('grave-update', {
      'familyId': familyId, 'uid': uid, 'grave': grave, 'visibility': visibility,
      'precision': precision, 'evidence': evidence
    });
  }

  private static fromRecord(row: Record<string, Object>): GraveEntry {
    const g: GraveEntry = new GraveEntry();
    g.graveId = str(row, 'graveId');
    g.familyId = str(row, 'familyId');
    g.uid = str(row, 'uid');
    g.personName = str(row, 'personName');
    g.generation = num(row, 'generation');
    g.bookTitle = str(row, 'bookTitle');
    g.graveName = str(row, 'graveName');
    g.lng = num(row, 'lng');
    g.lat = num(row, 'lat');
    g.altitude = num(row, 'altitude');
    g.facing = str(row, 'facing');
    g.bearing = str(row, 'bearing');
    g.routeNote = str(row, 'routeNote');
    g.photoRefs = str(row, 'photoRefs');
    g.visibility = str(row, 'visibility').length > 0 ? str(row, 'visibility') : 'PUBLIC';
    g.precision = str(row, 'precision').length > 0 ? str(row, 'precision') : 'EXACT';
    g.rev = num(row, 'rev');
    g.updatedAt = num(row, 'updatedAt');
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
