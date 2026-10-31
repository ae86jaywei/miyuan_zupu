import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { AccountService } from './AccountService';
import { GenealogyService } from './GenealogyService';
import { FamilyService } from './FamilyService';
import { OutboxService, OutboxItem } from './OutboxService';
import { GraveService } from './GraveService';
import { GenealogyStore } from '../store/GenealogyStore';
import { Person, createEmptyPerson, SpouseRelation } from '../model/Person';
import { Genealogy } from '../model/Genealogy';
import { SyncMode, SyncResult, bool, num, objectList, str } from '../model/FamilyDomain';
import { IntegrityService } from './IntegrityService';
import { IntegrityIssue, IntegrityReport } from '../model/Integrity';

const TAG: string = '[Genealogy][FamilySync]';
const PAGE_SIZE: number = 200;

/**
 * 家族协作同步（方案 §七 FamilySyncService）。
 *
 * 这是家族内数据的**唯一读取通道** —— 因为协作 Zone 的端侧权限是 []，
 * 端侧连 Family / FamilyMember 都读不到，只能经云函数 sync-pull 拿数据。
 *
 * 一次同步 = 推送本地 outbox → 按 rev 增量拉取 → 回放进 RDB → 更新 sync_state。
 */
export class FamilySyncService {
  private static instance: FamilySyncService | null = null;
  private running: boolean = false;

  static getInstance(): FamilySyncService {
    if (FamilySyncService.instance === null) {
      FamilySyncService.instance = new FamilySyncService();
    }
    return FamilySyncService.instance;
  }

  /** 同步是否进行中（UI 角标） */
  isRunning(): boolean {
    return this.running;
  }

  /** 全量同步当前打开的族谱 */
  async syncCurrent(reason: string): Promise<SyncResult> {
    const result: SyncResult = new SyncResult();
    const svc: GenealogyService = GenealogyService.getInstance();
    const book: Genealogy = svc.getBook();
    const familyId: string = book.familyId;
    if (familyId.length === 0) {
      result.message = '本谱尚未接入云家族';
      return result;
    }
    if (!AccountService.getInstance().isLoggedIn()) {
      result.message = '请先登录华为账号';
      return result;
    }
    if (!AccountService.getInstance().isCloudReady()) {
      result.message = AccountService.getInstance().getCloudMessage();
      return result;
    }
    if (this.running) {
      result.message = '正在同步中';
      return result;
    }
    this.running = true;
    FamilyService.getInstance().setSyncStatus('同步中…');
    try {
      if (book.syncMode !== SyncMode.CLOUD_PENDING) {
        await this.flushOutbox(familyId, result);
      }
      await this.pullAndReplay(familyId, result);
      // 以 outbox 实际剩余为准，避免「已同步完成」与「还有待传」同时出现
      const store0: relationalStore.RdbStore | null = svc.getStore();
      const remaining: number = store0 === null ? 0
        : await OutboxService.getInstance().pendingCount(store0, familyId);
      result.remainingOutbox = remaining;
      result.ok = remaining === 0 && result.integrityBlocked === 0;
      if (result.message.length === 0) {
        if (remaining === 0) {
          result.message = '同步完成';
        } else if (result.failedOutbox > 0) {
          const reason: string = result.warnings.length > 0 ? result.warnings[0] : '未知原因';
          result.message = '已拉取云端更新，但 ' + remaining.toString() + ' 条本地上传失败：' + reason;
        } else {
          result.message = '已拉取云端更新，' + remaining.toString() + ' 条本地变更仍待上传';
        }
      }
      if (result.integrityBlocked > 0) {
        result.message = '同步已暂缓 ' + result.integrityBlocked.toString() +
          ' 条编号冲突变更，请核对提示后重试';
      } else if (result.integrityIssues.length > 0) {
        result.message = result.message + '（发现 ' + result.integrityIssues.length.toString() +
          ' 项ID/关系异常）';
      }
      FamilyService.getInstance().setOffline(false);
    } catch (err) {
      const msg: string = FamilySyncService.describe(err);
      result.message = '同步失败：' + msg;
      FamilyService.getInstance().setOffline(true);
      hilog.warn(0x0000, TAG, 'sync failed (%{public}s): %{public}s', reason, msg);
    } finally {
      this.running = false;
      FamilyService.getInstance().setSyncStatus(result.message);
      const store: relationalStore.RdbStore | null = svc.getStore();
      if (store !== null) {
        const n: number = await OutboxService.getInstance().pendingCount(store, familyId);
        FamilyService.getInstance().setPendingCount(n);
      }
    }
    return result;
  }

  /** 首次同步 / 重新安装：sinceRev=0 触发全量基线 */
  async fullResync(): Promise<SyncResult> {
    const svc: GenealogyService = GenealogyService.getInstance();
    svc.setBookCloudState(svc.getBook().familyId, svc.getBook().syncMode, svc.getBook().familyRole, 0);
    return await this.syncCurrent('full');
  }

  /** 推送 outbox（在线才推，离线直接返回） */
  private async flushOutbox(familyId: string, result: SyncResult): Promise<void> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const store: relationalStore.RdbStore | null = svc.getStore();
    if (store === null) {
      return;
    }
    const items: OutboxItem[] = await OutboxService.getInstance().pending(store, familyId);
    result.pendingOutbox = items.length;
    if (items.length === 0) {
      return;
    }
    const book: Genealogy = svc.getBook();
    for (let i: number = 0; i < items.length; i++) {
      const item: OutboxItem = items[i];
      const baseRev: number = item.baseRev <= 0 ? book.cloudRev : item.baseRev;
      try {
        if (item.scope === 'book' || FamilyService.getInstance().isOwnerCurrent()) {
          // 谱主（或谱元信息）走直写
          await AccountService.getInstance().callFunction('member-direct-write', {
            'familyId': familyId,
            'uid': item.scope === 'book' ? '' : item.target,
            'op': item.op === 'DELETE' ? 'DELETE_REQ' : item.op,
            'patchJson': item.payload,
            'baseRev': baseRev
          });
        } else {
          await AccountService.getInstance().callFunction('change-submit', {
            'familyId': familyId,
            'op': item.op === 'DELETE' ? 'DELETE_REQ' : item.op,
            'targetUid': item.target,
            'patchJson': item.payload,
            'baseRev': baseRev,
            'evidence': item.targetName
          });
        }
        await OutboxService.getInstance().markDone(store, item.id);
      } catch (err) {
        const msg: string = FamilySyncService.describe(err);
        const permanent: boolean = msg.indexOf('Conflict') >= 0 || msg.indexOf('已被他人修改') >= 0 ||
          msg.indexOf('无权') >= 0 || msg.indexOf('只被授权') >= 0 || msg.indexOf('成环') >= 0 ||
          msg.indexOf('已存在') >= 0;
        await OutboxService.getInstance().markFailed(store, item.id, msg, permanent);
        result.failedOutbox++;
        if (permanent) {
          result.rejectedOutbox++;
          result.conflicts.push(msg);
        } else if (result.warnings.length < 3) {
          // 保留前几条可重试失败原因，供同步提示展示
          result.warnings.push(msg);
        }
      }
    }
    await OutboxService.getInstance().compact(store, familyId);
  }

  /** 拉取并回放 */
  private async pullAndReplay(familyId: string, result: SyncResult): Promise<void> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const book: Genealogy = svc.getBook();
    let since: number = book.cloudRev;
    let committedRev: number = since;
    let offset: number = 0;
    result.fromRev = since;
    let guard: number = 0;
    while (guard < 20) {
      guard++;
      const data: Record<string, Object> | null = await AccountService.getInstance().callFunction('sync-pull', {
        'familyId': familyId, 'sinceRev': since, 'limit': PAGE_SIZE, 'offset': offset
      });
      if (data === null) {
        break;
      }
      AccountService.getInstance().setIdentityVerified(true);
      const headRev: number = num(data, 'headRev');
      const members: Record<string, Object>[] = objectList(data, 'members');
      const graves: Record<string, Object>[] = objectList(data, 'graves');
      const fullSnapshot: boolean = bool(data, 'fullSnapshot');
      for (let i: number = 0; i < members.length; i++) {
        const changed: boolean = await this.replayMember(members[i], result);
        if (changed) {
          result.applied++;
        }
      }
      offset = num(data, 'nextOffset');
      await GraveService.getInstance().cacheRows(graves);
      result.graves += graves.length;
      const bookRaw: Record<string, Object> | undefined = data['book'] as Record<string, Object> | undefined;
      if (bookRaw !== undefined && bookRaw !== null) {
        this.replayBook(bookRaw);
      }
      since = headRev;
      if (result.integrityBlocked === 0) {
        committedRev = headRev;
      }
      if (!fullSnapshot || !bool(data, 'hasMore')) {
        break;
      }
    }
    // 存在编号冲突时基线停在上一次已确认的 rev，下次同步会再次拉取并提示
    svc.setBookCloudState(familyId, SyncMode.CLOUD_READY, FamilyService.getInstance().roleOf(familyId), committedRev);
    await svc.reloadAfterReplay();
    // 有变更被应用或存在编号冲突时才体检，避免每次同步重复弹历史提示
    if (result.applied > 0 || result.integrityBlocked > 0) {
      this.collectIntegrity(result);
    }
    GenealogyStore.notifyChanged();
    result.familyId = familyId;
    result.role = FamilyService.getInstance().roleOf(familyId);
    result.headRev = since;
  }

  /** 回放单个人物 */
  private async replayMember(raw: Record<string, Object>, result: SyncResult): Promise<boolean> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const uid: string = str(raw, 'uid').trim().toUpperCase();
    if (uid.length === 0) {
      return false;
    }
    const deleted: boolean = bool(raw, 'deleted');
    const rev: number = num(raw, 'rev');
    if (deleted) {
      await svc.applyRemoteChange(uid, null, rev, true);
      return true;
    }
    const person: Person = FamilySyncService.personFromRow(raw);
    const personName: string = person.name.trim();

    // 1. 本地已明确记录该编号属于某个已删除族人：同名视为删后恢复，异名视为编号被复用
    const retiredName: string = svc.retiredNameOf(uid);
    if (retiredName.length > 0 && personName.length > 0 && personName !== retiredName) {
      result.integrityBlocked++;
      result.integrityIssues.push('云端编号 ' + uid + ' 曾用于已删除族人“' + retiredName +
        '”，现对应“' + personName + '”，已暂缓合入，避免旧关系挂错人');
      return false;
    }

    // 2. 同编号在本机与云端代表不同人物：暂缓覆盖，保留本地关系不被冲掉
    const exist: Person | null = svc.getPerson(uid);
    if (exist !== null) {
      const report: IntegrityReport = IntegrityService.compare([exist], [person], '本机', '云端');
      let fatal: boolean = false;
      for (let i: number = 0; i < report.issues.length; i++) {
        const issue: IntegrityIssue = report.issues[i];
        if (issue.level !== 'error') {
          continue;
        }
        fatal = true;
        result.integrityIssues.push('编号 ' + uid + '：' + issue.message);
      }
      if (fatal) {
        result.integrityBlocked++;
        return false;
      }
    }
    await svc.applyRemoteChange(uid, person, rev, false);
    return true;
  }

  /** 同步结束后做一次ID/亲属关系体检，把严重问题交给界面弹窗 */
  private collectIntegrity(result: SyncResult): void {
    const svc: GenealogyService = GenealogyService.getInstance();
    const report: IntegrityReport = IntegrityService.check(svc.getPeople(), svc.getBook().title);
    report.merge(IntegrityService.reused(svc.getPeople(), svc.getRetiredMap()));
    report.merge(IntegrityService.reusedReferences(svc.getPeople(), svc.getRetiredMap()));
    for (let i: number = 0; i < report.issues.length; i++) {
      const issue: IntegrityIssue = report.issues[i];
      if (issue.level !== 'error') {
        continue;
      }
      const who: string = issue.uid.length > 0 ? issue.uid : '族谱';
      const text: string = who + '：' + issue.message;
      if (result.integrityIssues.indexOf(text) < 0) {
        result.integrityIssues.push(text);
      }
    }
  }

  /** 谱元信息回放：本地未填的字段才用云端值覆盖 */
  private replayBook(raw: Record<string, Object>): void {
    const payloadText: string = str(raw, 'payload');
    if (payloadText.length === 0) {
      return;
    }
    try {
      const payload: Record<string, Object> = JSON.parse(payloadText) as Record<string, Object>;
      const incoming: Genealogy = Genealogy.fromCloudPayload(payload);
      const svc: GenealogyService = GenealogyService.getInstance();
      const local: Genealogy = svc.getBook();
      if (local.title.length === 0) {
        local.title = incoming.title;
      }
      if (local.hallName.length === 0) {
        local.hallName = incoming.hallName;
      }
      if (local.ancestorName.length === 0) {
        local.ancestorName = incoming.ancestorName;
      }
      if (local.generationPoem.length === 0) {
        local.generationPoem = incoming.generationPoem;
      }
      if (local.preface.length === 0) {
        local.preface = incoming.preface;
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'parse book payload failed');
    }
  }

  /** 云侧 FamilyMember 行 → 本地 Person（payload 只有公开字段） */
  static personFromRow(raw: Record<string, Object>): Person {
    const p: Person = createEmptyPerson();
    p.uid = str(raw, 'uid');
    p.name = str(raw, 'name');
    p.generation = num(raw, 'generation');
    p.fatherId = str(raw, 'parentId');
    p.updatedAt = num(raw, 'updatedAt');
    p.rev = num(raw, 'rev');
    p.baseRev = num(raw, 'baseRev');
    const payloadText: string = str(raw, 'payload');
    if (payloadText.length === 0) {
      return p;
    }
    try {
      const src: Record<string, Object> = JSON.parse(payloadText) as Record<string, Object>;
      FamilySyncService.fillPerson(p, src);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'parse member payload failed');
    }
    return p;
  }

  private static fillPerson(p: Person, src: Record<string, Object>): void {
    if (str(src, 'name').length > 0) {
      p.name = str(src, 'name');
    }
    if (num(src, 'generation') > 0) {
      p.generation = num(src, 'generation');
    }
    p.alias = str(src, 'alias');
    p.gender = str(src, 'gender').length > 0 ? str(src, 'gender') : '男';
    p.generationChar = str(src, 'generationChar');
    p.lifeStatus = str(src, 'lifeStatus').length > 0 ? str(src, 'lifeStatus') : '在世';
    p.childStatus = str(src, 'childStatus').length > 0 ? str(src, 'childStatus') : '未记';
    p.birthDate = str(src, 'birthDate');
    p.birthCalendar = str(src, 'birthCalendar').length > 0 ? str(src, 'birthCalendar') : '公历';
    p.deathDate = str(src, 'deathDate');
    p.deathCalendar = str(src, 'deathCalendar').length > 0 ? str(src, 'deathCalendar') : '公历';
    p.birthPlace = str(src, 'birthPlace');
    p.residence = str(src, 'residence');
    p.fatherId = str(src, 'fatherId');
    p.motherId = str(src, 'motherId');
    p.spouseId = str(src, 'spouseId');
    p.rank = str(src, 'rank');
    p.adoption = str(src, 'adoption');
    p.education = str(src, 'education');
    p.occupation = str(src, 'occupation');
    p.biography = str(src, 'biography');
    p.graveInfo = str(src, 'graveInfo');
    p.phone = str(src, 'phone');
    p.wechat = str(src, 'wechat');
    p.avatar = str(src, 'avatar');
    p.videos = str(src, 'videos');
    p.photos = str(src, 'photos');
    p.createdAt = num(src, 'createdAt');
    p.spouses = FamilySyncService.spousesOf(src);
  }

  private static spousesOf(src: Record<string, Object>): SpouseRelation[] {
    const out: SpouseRelation[] = [];
    const raw: Object | undefined = src['spouses'];
    if (raw === undefined || raw === null) {
      return out;
    }
    const arr: Object[] = raw as Object[];
    if (arr.length === undefined) {
      return out;
    }
    for (let i: number = 0; i < arr.length; i++) {
      const item: Record<string, Object> = arr[i] as Record<string, Object>;
      const r: SpouseRelation = new SpouseRelation();
      r.uid = str(item, 'uid');
      r.relation = str(item, 'relation');
      r.level = str(item, 'level');
      r.order = num(item, 'order');
      if (r.uid.length > 0) {
        out.push(r);
      }
    }
    return out;
  }

  /** 把云函数抛出的 Error 转成中文提示 */
  static describe(err: Object): string {
    const e: Error = err as Error;
    const msg: string = e.message !== undefined ? e.message : String(err);
    return msg.length > 0 ? msg : '网络异常';
  }
}
