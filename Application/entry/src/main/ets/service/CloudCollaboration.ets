import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Genealogy, Person, buildPersonPatch, clonePerson } from 'common_base';
import { TABLE_PERSON } from './db/DatabaseSchema';
import { PeopleStore } from './PeopleStore';
import { FamilyService } from './FamilyService';

const TAG: string = '[Genealogy][Cloud]';

/**
 * 协作通知域：本地写入后的云端同步触发、编辑前快照与脏标记。
 *
 * 从 `GenealogyService` 拆出：
 *  - 在线时把字段级 patch 推给云函数，离线时落 outbox 并标记 dirty；
 *  - `captureBefore` 保存编辑前快照，供 diff 生成 patch；
 *  - 墓碑查询 `isDeleted` 供协作层过滤已删除人员。
 */
export class CloudCollaboration {
  private peopleStore: PeopleStore;
  private bookProvider: () => Genealogy;
  private storeProvider: () => relationalStore.RdbStore | null;
  private bookIdProvider: () => number;
  /** 编辑前快照（uid → Person），用于生成字段级 diff */
  private beforeSnapshots: Map<string, Person> = new Map<string, Person>();

  constructor(peopleStore: PeopleStore,
    bookProvider: () => Genealogy,
    storeProvider: () => relationalStore.RdbStore | null,
    bookIdProvider: () => number) {
    this.peopleStore = peopleStore;
    this.bookProvider = bookProvider;
    this.storeProvider = storeProvider;
    this.bookIdProvider = bookIdProvider;
  }

  /**
   * 记录「编辑前的快照」，供字段级 diff 生成 patch（§五.5 patchJson）。
   * 由编辑页在保存前调用。
   */
  captureBefore(uid: string): void {
    const p: Person | null = this.peopleStore.getPerson(uid);
    if (p !== null) {
      this.beforeSnapshots.set(uid.trim().toUpperCase(), clonePerson(p));
    }
  }

  /** 墓碑查询：某人是否已被删除 */
  isDeleted(uid: string): boolean {
    const p: Person | undefined = this.peopleStore.getMap().get(uid.trim().toUpperCase());
    return p !== undefined && p.deletedAt > 0;
  }

  /** 本地写入后把变更推给协作层（在线→云函数，离线→outbox） */
  async notifyPersonChange(op: string, changed: Person, originalUid: string | null): Promise<void> {
    const book: Genealogy = this.bookProvider();
    if (book.familyId.length === 0) {
      return;
    }
    let before: Person | null = null;
    if (originalUid !== null) {
      const snap: Person | undefined = this.beforeSnapshots.get(originalUid.trim().toUpperCase());
      before = snap !== undefined ? snap : null;
    }
    const patchJson: string = buildPersonPatch(before, changed, op);
    const baseRev: number = changed.baseRev > 0 ? changed.baseRev : book.cloudRev;
    try {
      const result: string = await FamilyService.getInstance()
        .afterPersonSaved(op, changed.uid, changed.name, patchJson, baseRev);
      if (result === 'queued') {
        await this.markDirty(changed.uid);
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'notify cloud change failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 标记某人物本地有未上传修改 */
  private async markDirty(uid: string): Promise<void> {
    const store: relationalStore.RdbStore | null = this.storeProvider();
    if (store === null) {
      return;
    }
    await store.executeSql(
      `UPDATE ${TABLE_PERSON} SET dirty = 1 WHERE book_id = ? AND UPPER(uid) = ?`,
      [this.bookIdProvider(), uid.trim().toUpperCase()]);
  }
}
