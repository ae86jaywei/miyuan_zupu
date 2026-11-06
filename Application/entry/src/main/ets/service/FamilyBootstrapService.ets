import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { AccountService } from './AccountService';
import { GenealogyService } from './GenealogyService';
import { FamilyService } from './FamilyService';
import { OutboxService } from './OutboxService';
import { Genealogy } from '../model/Genealogy';
import { Person } from '../model/Person';
import { SyncMode, SyncResult } from '../model/FamilyDomain';

const TAG: string = '[Genealogy][Bootstrap]';
/** 单批人数必须与云端 family-bootstrap 的 MAX_BATCH（100）保持一致，否则云端返回 400 */
const MAX_BATCH_SIZE: number = 100;
const MAX_BATCH_CHARS: number = 220000;
const MAX_BOOK_CHARS: number = 300000;
const BATCH_INTERVAL_MS: number = 150;
const MAX_RETRY: number = 4;
const MAX_RATE_RETRY: number = 6;
const FUNCTION_TIMEOUT_MS: number = 35 * 1000;
const CHECKPOINT_PREF: string = 'zupu_bootstrap';

/** 发布进度回调（页面上展示「正在发布 200/1200」） */
export type BootstrapProgress = (message: string, done: number, total: number) => void;

/**
 * 首次把本地全量谱基线发布到协作 Zone（方案 §六 family-bootstrap / §十 P0-c）。
 *
 * 为什么要单独一步：千人谱首次上云无法一次塞进一个请求体，
 * 而且必须**先把基线发上去**，之后才有 rev 可增量同步。
 * 上传是幂等的（按 memberId upsert），中断后重跑不会产生重复数据。
 */
export class FamilyBootstrapService {
  private static instance: FamilyBootstrapService | null = null;
  private prefs: preferences.Preferences | null = null;
  private checkpointFamilyId: string = '';
  private checkpointTotal: number = 0;
  private checkpointCursor: number = 0;
  private checkpointFingerprint: string = '';
  private running: boolean = false;
  private batchIntervalMs: number = BATCH_INTERVAL_MS;

  static getInstance(): FamilyBootstrapService {
    if (FamilyBootstrapService.instance === null) {
      FamilyBootstrapService.instance = new FamilyBootstrapService();
    }
    return FamilyBootstrapService.instance;
  }

  /** 把当前打开的族谱全量发布（含谱元信息） */
  async publishCurrent(progress: BootstrapProgress): Promise<SyncResult> {
    const result: SyncResult = new SyncResult();
    const svc: GenealogyService = GenealogyService.getInstance();
    const book: Genealogy = svc.getBook();
    const familyId: string = book.familyId;
    if (familyId.length === 0) {
      result.message = '本谱还没有创建云家族';
      return result;
    }
    if (!FamilyService.getInstance().canEditCurrent()) {
      result.message = '只有谱主或编辑者可以发布族谱';
      return result;
    }
    if (!AccountService.getInstance().isCloudReady()) {
      result.message = AccountService.getInstance().getCloudMessage();
      return result;
    }
    if (this.running || AppStorage.get<boolean>('gpCloudBusy') === true) {
      result.message = '正在发布或同步中，请稍候';
      return result;
    }
    this.running = true;
    AppStorage.setOrCreate<boolean>('gpCloudBusy', true);
    let cursor: number = 0;
    let total: number = 0;
    try {
      const people: Person[] = svc.getPeople();
      total = people.length;
      const fingerprint: string = FamilyBootstrapService.fingerprint(people);
      cursor = this.loadCursor(familyId, total, fingerprint);
      this.report(progress, cursor > 0 ? '继续发布族人' : '正在准备发布', cursor, total);
      const bookJson: string = JSON.stringify(book.toCloudPayload());
      if (bookJson.length > MAX_BOOK_CHARS) {
        throw new Error('族谱序言或谱规内容过大，请精简后重新发布');
      }
      await this.sendBatch(familyId, 0, [], book);
      while (cursor < total) {
        const chunk: BootstrapBatch = this.collectBatch(people, cursor);
        await this.sendBatch(familyId, cursor, chunk.persons, null);
        cursor = chunk.next;
        await this.saveCursor(familyId, total, cursor, fingerprint);
        this.report(progress, '正在发布族人', cursor, total);
      }
      const current: Genealogy = svc.getBook();
      const sameBook: boolean = svc.getCurrentBookId() === book.key && current.familyId === familyId;
      if (sameBook) {
        const finalFingerprint: string = FamilyBootstrapService.fingerprint(svc.getPeople());
        if (finalFingerprint !== fingerprint) {
          result.message = '发布期间本地数据已变化，本次未标记完成；请再次点击发布会重新补传并校验';
          this.report(progress, result.message, cursor, total);
          return result;
        }
        svc.setBookCloudState(familyId, SyncMode.CLOUD_READY,
          FamilyService.getInstance().roleOf(familyId), 0);
        book.syncMode = SyncMode.CLOUD_READY;
        book.cloudRev = 0;
        FamilyService.getInstance().publishState(SyncMode.CLOUD_READY,
          FamilyService.getInstance().roleOf(familyId));
        await this.clearCursor();
      }
      this.batchIntervalMs = BATCH_INTERVAL_MS;
      result.ok = true;
      result.familyId = familyId;
      result.message = sameBook ? '已发布 ' + total.toString() + ' 位族人到云端' :
        '已发布 ' + total.toString() + ' 位族人到云端；发布期间已切换族谱，请切回《' + book.title +
          '》后再次点击发布以确认状态';
      this.report(progress, result.message, total, total);
      return result;
    } catch (err) {
      const retryable: boolean = FamilyBootstrapService.isRetryable(err);
      const rateLimited: boolean = FamilyBootstrapService.isRateLimited(err);
      const hint: string = rateLimited ? '请求过于频繁，请等待约 1 分钟后再次点击继续' :
        (retryable ? '可再次点击继续' : '请修正数据后重新发布');
      result.message = '发布失败（已完成 ' + cursor.toString() + '/' + total.toString() +
        '，' + hint + '）：' + FamilyBootstrapService.describe(err);
      hilog.warn(0x0000, TAG, 'bootstrap failed at %{public}d/%{public}d: %{public}s',
        cursor, total, result.message);
      return result;
    } finally {
      this.running = false;
      AppStorage.setOrCreate<boolean>('gpCloudBusy', false);
    }
  }

  private report(progress: BootstrapProgress, message: string, done: number, totalCount: number): void {
    try {
      progress(message, done, totalCount);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'bootstrap progress callback failed: %{public}s', JSON.stringify(err));
    }
  }

  private static fingerprint(people: Person[]): string {
    let sum: number = 0;
    let newest: number = 0;
    for (let i: number = 0; i < people.length; i++) {
      const stamp: number = people[i].updatedAt > 0 ? people[i].updatedAt : 0;
      sum = (sum + stamp) % 1000000000000;
      if (stamp > newest) {
        newest = stamp;
      }
    }
    const first: string = people.length > 0 ? people[0].uid : '';
    const last: string = people.length > 0 ? people[people.length - 1].uid : '';
    return people.length.toString() + ':' + newest.toString() + ':' + sum.toString() + ':' + first + ':' + last;
  }

  private collectBatch(people: Person[], cursor: number): BootstrapBatch {
    const batch: Record<string, Object>[] = [];
    let next: number = cursor;
    let totalChars: number = 0;
    while (next < people.length && batch.length < MAX_BATCH_SIZE) {
      const person: Record<string, Object> = FamilyBootstrapService.personToJson(people[next]);
      const size: number = JSON.stringify(person).length;
      if (batch.length === 0 && size > MAX_BATCH_CHARS) {
        throw new Error('人物 ' + people[next].uid + ' 的单条数据过大，请精简照片或长文本');
      }
      if (batch.length > 0 && totalChars + size > MAX_BATCH_CHARS) {
        break;
      }
      batch.push(person);
      totalChars = totalChars + size;
      next = next + 1;
    }
    const out: BootstrapBatch = new BootstrapBatch();
    out.persons = batch;
    out.next = next;
    return out;
  }

  /** 发布单批（云函数幂等，失败可直接重试） */
  private async sendBatch(familyId: string, cursor: number, persons: Record<string, Object>[],
    book: Genealogy | null): Promise<void> {
    const data: Record<string, Object> = {
      'familyId': familyId,
      'cursor': cursor,
      'persons': persons
    };
    if (book !== null) {
      data['book'] = book.toCloudPayload();
    }
    await this.delay(this.batchIntervalMs);
    let attempt: number = 0;
    while (true) {
      try {
        await AccountService.getInstance().callFunction('family-bootstrap', data, FUNCTION_TIMEOUT_MS);
        this.batchIntervalMs = Math.max(BATCH_INTERVAL_MS, this.batchIntervalMs - 20);
        return;
      } catch (err) {
        if (FamilyBootstrapService.isBatchTooLarge(err) && persons.length > 1) {
          const middle: number = Math.floor(persons.length / 2);
          await this.sendBatch(familyId, cursor, persons.slice(0, middle), null);
          await this.sendBatch(familyId, cursor + middle, persons.slice(middle), null);
          return;
        }
        const rateLimited: boolean = FamilyBootstrapService.isRateLimited(err);
        const maxRetry: number = rateLimited ? MAX_RATE_RETRY : MAX_RETRY;
        if (!FamilyBootstrapService.isRetryable(err) || attempt >= maxRetry) {
          throw err as Error;
        }
        if (rateLimited) {
          this.batchIntervalMs = Math.min(1000, this.batchIntervalMs + 150);
        }
        const base: number = rateLimited ? 2000 : 800;
        const cap: number = rateLimited ? 30000 : 8000;
        const wait: number = Math.min(cap, base * Math.pow(2, attempt)) + Math.floor(Math.random() * 300);
        hilog.warn(0x0000, TAG, 'bootstrap retry %{public}d after %{public}dms: %{public}s',
          attempt + 1, wait, FamilyBootstrapService.describe(err));
        await this.delay(wait);
        attempt = attempt + 1;
      }
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  private static isRateLimited(err: Object): boolean {
    const text: string = FamilyBootstrapService.describe(err).toLowerCase();
    return text.indexOf('3007009') >= 0 || text.indexOf('too many requests') >= 0 ||
      text.indexOf('429') >= 0 || text.indexOf('rate limit') >= 0 || text.indexOf('frequent') >= 0 ||
      text.indexOf('busy') >= 0 || text.indexOf('限流') >= 0 || text.indexOf('请求过于频繁') >= 0 ||
      text.indexOf('频率') >= 0 || text.indexOf('系统繁忙') >= 0;
  }

  private static isBatchTooLarge(err: Object): boolean {
    const text: string = FamilyBootstrapService.describe(err).toLowerCase();
    return text.indexOf('数据过大') >= 0 || text.indexOf('单次上传不超过') >= 0 ||
      text.indexOf('payload too large') >= 0 || text.indexOf('too large') >= 0 ||
      text.indexOf('413') >= 0;
  }

  private static isRetryable(err: Object): boolean {
    const text: string = FamilyBootstrapService.describe(err).toLowerCase();
    return FamilyBootstrapService.isRateLimited(err) || text.indexOf('timeout') >= 0 ||
      text.indexOf('timed out') >= 0 || text.indexOf('1008210001') >= 0 ||
      text.indexOf('1008211001') >= 0 || text.indexOf('1008210009') >= 0 ||
      text.indexOf('network') >= 0 || text.indexOf('网络') >= 0 || text.indexOf('超时') >= 0 ||
      text.indexOf('500') >= 0 || text.indexOf('502') >= 0 || text.indexOf('503') >= 0 ||
      text.indexOf('unavailable') >= 0;
  }

  private preferencesOrNull(): preferences.Preferences | null {
    if (this.prefs !== null) {
      return this.prefs;
    }
    const context = AccountService.getInstance().getContext();
    if (context === null) {
      return null;
    }
    try {
      const opt: preferences.Options = { name: CHECKPOINT_PREF };
      this.prefs = preferences.getPreferencesSync(context, opt);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'open bootstrap checkpoint failed: %{public}s', JSON.stringify(err));
    }
    return this.prefs;
  }

  private loadCursor(familyId: string, total: number, fingerprint: string): number {
    const prefs: preferences.Preferences | null = this.preferencesOrNull();
    if (prefs !== null) {
      try {
        const savedFamily: string = prefs.getSync('familyId', '') as string;
        const savedTotal: number = prefs.getSync('total', 0) as number;
        const savedCursor: number = prefs.getSync('cursor', 0) as number;
        const savedFingerprint: string = prefs.getSync('fingerprint', '') as string;
        if (savedFamily === familyId && savedTotal === total && savedCursor > 0 && savedCursor <= total &&
          savedFingerprint === fingerprint) {
          this.checkpointFamilyId = familyId;
          this.checkpointTotal = total;
          this.checkpointCursor = savedCursor;
          this.checkpointFingerprint = fingerprint;
          return savedCursor;
        }
      } catch (err) {
        hilog.warn(0x0000, TAG, 'load bootstrap checkpoint failed: %{public}s', JSON.stringify(err));
      }
    }
    if (this.checkpointFamilyId === familyId && this.checkpointTotal === total &&
      this.checkpointCursor > 0 && this.checkpointCursor <= total && this.checkpointFingerprint === fingerprint) {
      return this.checkpointCursor;
    }
    return 0;
  }

  private async saveCursor(familyId: string, total: number, cursor: number, fingerprint: string): Promise<void> {
    this.checkpointFamilyId = familyId;
    this.checkpointTotal = total;
    this.checkpointCursor = cursor;
    this.checkpointFingerprint = fingerprint;
    const prefs: preferences.Preferences | null = this.preferencesOrNull();
    if (prefs === null) {
      return;
    }
    try {
      prefs.putSync('familyId', familyId);
      prefs.putSync('total', total);
      prefs.putSync('cursor', cursor);
      prefs.putSync('fingerprint', fingerprint);
      await prefs.flush();
    } catch (err) {
      hilog.warn(0x0000, TAG, 'save bootstrap checkpoint failed: %{public}s', JSON.stringify(err));
    }
  }

  private async clearCursor(): Promise<void> {
    this.checkpointFamilyId = '';
    this.checkpointTotal = 0;
    this.checkpointCursor = 0;
    this.checkpointFingerprint = '';
    const prefs: preferences.Preferences | null = this.preferencesOrNull();
    if (prefs === null) {
      return;
    }
    try {
      prefs.putSync('familyId', '');
      prefs.putSync('total', 0);
      prefs.putSync('cursor', 0);
      prefs.putSync('fingerprint', '');
      await prefs.flush();
    } catch (err) {
      hilog.warn(0x0000, TAG, 'clear bootstrap checkpoint failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Person → 云函数入参 JSON。
   * **完整上传**（含 phone/wechat/residence 与墓葬坐标）是允许的：
   * 云函数会立刻把它们拆到 FamilyPrivate / FamilyGraveLocation，
   * 只有公开字段留在 FamilyMember.payload。
   */
  static personToJson(p: Person): Record<string, Object> {
    return JSON.parse(JSON.stringify(p)) as Record<string, Object>;
  }

  /** 发布后还有多少条历史变更待推（用于提示） */
  async pendingHistory(): Promise<number> {
    const svc: GenealogyService = GenealogyService.getInstance();
    const store: relationalStore.RdbStore | null = svc.getStore();
    if (store === null) {
      return 0;
    }
    return await OutboxService.getInstance().pendingCount(store, svc.getBook().familyId);
  }

  private static describe(err: Object): string {
    if (err === null || err === undefined) {
      return '未知错误';
    }
    if (err instanceof Error && err.message !== undefined && err.message.length > 0) {
      const name: string = err.name !== undefined ? err.name : '';
      return name.indexOf('CloudFunctionError:') === 0 ? err.message + ' ' + name : err.message;
    }
    try {
      const text: string = JSON.stringify(err);
      return text.length > 2 ? text : String(err);
    } catch (e) {
      return String(err);
    }
  }
}

class BootstrapBatch {
  persons: Record<string, Object>[] = [];
  next: number = 0;
}
