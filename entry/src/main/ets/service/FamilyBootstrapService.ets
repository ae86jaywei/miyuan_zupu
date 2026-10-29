import { hilog } from '@kit.PerformanceAnalysisKit';
import { relationalStore } from '@kit.ArkData';
import { AccountService } from './AccountService';
import { GenealogyService } from './GenealogyService';
import { FamilyService } from './FamilyService';
import { OutboxService } from './OutboxService';
import { Genealogy } from '../model/Genealogy';
import { Person } from '../model/Person';
import { SyncMode, SyncResult } from '../model/FamilyDomain';

const TAG: string = '[Genealogy][Bootstrap]';

/** 单次上传条数：≤100 规避单次请求体与超时限制（方案 §六 family-bootstrap） */
const BATCH_SIZE: number = 100;

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
    const people: Person[] = svc.getPeople();
    const total: number = people.length;
    progress('正在准备发布', 0, total);
    try {
      if (total === 0) {
        await this.sendBatch(familyId, 0, [], book);
      }
      let cursor: number = 0;
      while (cursor < total) {
        const end: number = Math.min(cursor + BATCH_SIZE, total);
        const batch: Record<string, Object>[] = [];
        for (let i: number = cursor; i < end; i++) {
          batch.push(FamilyBootstrapService.personToJson(people[i]));
        }
        const bookArg: Genealogy | null = cursor === 0 ? book : null;
        await this.sendBatch(familyId, cursor, batch, bookArg);
        cursor = end;
        progress('正在发布族人', cursor, total);
      }
      svc.setBookCloudState(familyId, SyncMode.CLOUD_READY, FamilyService.getInstance().roleOf(familyId), 0);
      book.syncMode = SyncMode.CLOUD_READY;
      book.cloudRev = 0;
      FamilyService.getInstance().publishState(SyncMode.CLOUD_READY, FamilyService.getInstance().currentRole());
      result.ok = true;
      result.familyId = familyId;
      result.message = '已发布 ' + total.toString() + ' 位族人到云端';
      progress(result.message, total, total);
      return result;
    } catch (err) {
      result.message = '发布失败：' + FamilyBootstrapService.describe(err);
      hilog.warn(0x0000, TAG, 'bootstrap failed: %{public}s', result.message);
      return result;
    }
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
    await AccountService.getInstance().callFunction('family-bootstrap', data);
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
    const e: Error = err as Error;
    return e.message !== undefined && e.message.length > 0 ? e.message : '网络异常，请稍后重试';
  }
}
