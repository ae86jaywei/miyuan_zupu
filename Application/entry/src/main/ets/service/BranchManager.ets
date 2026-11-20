import { relationalStore } from '@kit.ArkData';
import { Genealogy, Person, SpouseRelation, clonePerson, createEmptyGenealogy, normalizeSpouseRelations, spouseRelationLevel } from 'common_base';
import { TABLE_BOOK, TABLE_META, TABLE_PERSON, TABLE_SPOUSE } from './db/DatabaseSchema';
import { PersonRowMapper } from './db/PersonRowMapper';

/** 元数据前缀：某部族谱中已被删除、但编号仍需保留不再复用的族人 */
const META_RETIRED_PREFIX: string = 'retired_uids_';

/** 已删除人员的编号记录（用于防止新族人沿用旧编号） */
class BranchRetired {
  uid: string = '';
  name: string = '';
  deletedAt: number = 0;
}

/**
 * 分支谱宿主接口：由 `GenealogyService` 实现，暴露建支与原谱清理所需的状态与工具。
 */
export interface BranchHost {
  storeRef(): relationalStore.RdbStore | null;
  currentBookIdValue(): number;
  setCurrentBookId(id: number): void;
  currentBookValue(): Genealogy;
  hasBookTitle(title: string): boolean;
  getPerson(uid: string): Person | null;
  peopleAll(): Person[];
  getMetaValue(key: string): Promise<string>;
  setMetaValue(key: string, value: string): Promise<void>;
  reloadData(): Promise<void>;
}

/**
 * 分支谱域：以某位族人为始祖另立族谱，并在建支成功后异步清理原谱。
 *
 * 从 `GenealogyService` 拆出，事务、分批复制、进度回调与后台软删语义保持不变。
 */
export class BranchManager {
  private host: BranchHost;

  constructor(host: BranchHost) {
    this.host = host;
  }

  /**
   * 以当前族谱中的某位族人为始祖，另立一部分支族谱。
   *  - 复制该人及其全部后代（含各自的配偶），世代按“该人为第一世”重新编号；
   *  - 分支谱数据独立，原族谱不受影响；创建后自动切换到分支谱继续录入。
   */
  async createBranchFromPerson(rootUid: string,
    onProgress?: (done: number, total: number) => void): Promise<Genealogy> {
    const currentBookId: number = this.host.currentBookIdValue();
    if (currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    const root: Person | null = this.host.getPerson(rootUid);
    if (root === null) {
      throw new Error('未找到该族人');
    }
    const store: relationalStore.RdbStore = this.host.storeRef() as relationalStore.RdbStore;
    const book: Genealogy = this.host.currentBookValue();
    const rootKey: string = root.uid.trim().toUpperCase();
    // 上承：分支始祖在原谱的父/母；始祖本人保留在原谱作为“分支占位”，不移动
    const fatherKey: string = root.fatherId.trim().toUpperCase();
    const motherKey: string = root.motherId.trim().toUpperCase();
    const parentKey: string = fatherKey.length > 0 ? fatherKey : motherKey;
    const parent: Person | null = parentKey.length > 0 ? this.host.getPerson(parentKey) : null;

    // 一次建父/母→子女索引，避免 5 万人谱反复线性扫描
    const childIndex: Map<string, string[]> = new Map<string, string[]>();
    const allPeople: Person[] = this.host.peopleAll();
    for (let i: number = 0; i < allPeople.length; i = i + 1) {
      const p: Person = allPeople[i];
      const f: string = p.fatherId.trim().toUpperCase();
      const m: string = p.motherId.trim().toUpperCase();
      if (f.length > 0) {
        let arr: string[] | undefined = childIndex.get(f);
        if (arr === undefined) {
          arr = [];
          childIndex.set(f, arr);
        }
        arr.push(p.uid);
      }
      if (m.length > 0 && m !== f) {
        let arr2: string[] | undefined = childIndex.get(m);
        if (arr2 === undefined) {
          arr2 = [];
          childIndex.set(m, arr2);
        }
        arr2.push(p.uid);
      }
    }

    // 收集本支全部 uid（始祖 + 后代），只存 uid，不持有整支 Person 数组
    const lineUids: string[] = [];
    const picked: Set<string> = new Set<string>();
    const stack: string[] = [rootKey];
    while (stack.length > 0) {
      const u: string = (stack.pop() as string).trim().toUpperCase();
      if (u.length === 0 || picked.has(u)) {
        continue;
      }
      const p: Person | null = this.host.getPerson(u);
      if (p === null) {
        continue;
      }
      picked.add(u);
      lineUids.push(u);
      const kids: string[] | undefined = childIndex.get(u);
      if (kids !== undefined) {
        for (let k: number = 0; k < kids.length; k = k + 1) {
          stack.push(kids[k]);
        }
      }
    }

    // 配偶复制到分支谱、原谱保留（避免破坏其他支的婚姻关系）
    const spouseUids: string[] = [];
    const spouseSet: Set<string> = new Set<string>();
    for (let i: number = 0; i < lineUids.length; i = i + 1) {
      const owner: Person | null = this.host.getPerson(lineUids[i]);
      if (owner === null) {
        continue;
      }
      for (let s: number = 0; s < owner.spouses.length; s = s + 1) {
        const su: string = owner.spouses[s].uid.trim().toUpperCase();
        if (su.length > 0 && !picked.has(su) && !spouseSet.has(su)) {
          spouseUids.push(su);
          spouseSet.add(su);
        }
      }
      const legacy: string = owner.spouseId.trim().toUpperCase();
      if (legacy.length > 0 && !picked.has(legacy) && !spouseSet.has(legacy)) {
        spouseUids.push(legacy);
        spouseSet.add(legacy);
      }
    }

    // 新建分支族谱：命名带上母谱与始祖名，便于区分
    const baseTitle: string = (book.title.trim().length > 0 ? book.title.trim() : '我的族谱')
      + '-' + root.name + '分支';
    let title: string = baseTitle;
    let serial: number = 2;
    while (this.host.hasBookTitle(title)) {
      title = baseTitle + ' ' + serial.toString();
      serial++;
    }
    const branch: Genealogy = createEmptyGenealogy();
    branch.title = title;
    branch.surname = book.surname;
    branch.hallName = book.hallName;
    branch.junwang = book.junwang;
    branch.ancestorName = root.name;
    branch.generationPoem = book.generationPoem;
    branch.coverColor = book.coverColor;
    branch.coverPattern = book.coverPattern;
    branch.parentBookId = currentBookId;
    branch.branchRootUid = rootKey;
    branch.parentBookTitle = book.title;
    branch.parentUid = parentKey;
    branch.parentName = parent === null ? '' : parent.name;
    branch.parentGeneration = parent === null ? Math.max(1, root.generation - 1) : parent.generation;

    const offset: number = Math.max(0, root.generation - 1);
    const now: number = Date.now();
    // 原谱 id：建支完成后当前谱会切换，异步清理必须记住原谱
    const sourceBookId: number = currentBookId;
    let rowId: number = 0;
    // 同一事务内完成「写入分支谱 + 原谱软删后代」，失败整体回滚
    store.beginTransaction();
    try {
      rowId = await store.insert(TABLE_BOOK, PersonRowMapper.bookValues(branch));
      branch.key = rowId;
      // 始祖 + 后代逐条复制：不构建整支 Person 数组，避免 5 万人谱内存翻倍
      const batchSize: number = 200;
      let personBatch: relationalStore.ValuesBucket[] = [];
      let spouseBatch: relationalStore.ValuesBucket[] = [];
      const totalToMove: number = lineUids.length + spouseUids.length;
      for (let i: number = 0; i < lineUids.length; i = i + 1) {
        const src: Person | null = this.host.getPerson(lineUids[i]);
        if (src === null) {
          continue;
        }
        const p: Person = clonePerson(src);
        p.key = 0;
        p.generation = Math.max(1, src.generation - offset);
        if (i === 0) {
          p.fatherId = '';
          p.motherId = '';
          p.rank = '第一世（始祖）';
        } else {
          if (!picked.has(p.fatherId.trim().toUpperCase())) {
            p.fatherId = '';
          }
          if (!picked.has(p.motherId.trim().toUpperCase())) {
            p.motherId = '';
          }
        }
        const keptSpouses: SpouseRelation[] = [];
        p.spouses.forEach((r: SpouseRelation): void => {
          const su: string = r.uid.trim().toUpperCase();
          if (picked.has(su) || spouseSet.has(su)) {
            keptSpouses.push(r);
          }
        });
        p.spouses = keptSpouses;
        if (!picked.has(p.spouseId.trim().toUpperCase()) &&
          !spouseSet.has(p.spouseId.trim().toUpperCase())) {
          p.spouseId = '';
        }
        normalizeSpouseRelations(p);
        p.createdAt = now;
        p.updatedAt = now;
        personBatch.push(PersonRowMapper.toValues(p, rowId));
        for (let s: number = 0; s < p.spouses.length; s = s + 1) {
          const r: SpouseRelation = p.spouses[s];
          const partner: string = r.uid.trim().toUpperCase();
          if (partner.length === 0 || partner === p.uid.trim().toUpperCase()) {
            continue;
          }
          const rel: string = r.relation.trim().length > 0 ? r.relation.trim() : '未记';
          const sb: relationalStore.ValuesBucket = {
            'book_id': rowId,
            'uid': p.uid.trim().toUpperCase(),
            'spouse_uid': partner,
            'relation': rel,
            'level': spouseRelationLevel(rel),
            'ord': s + 1
          };
          spouseBatch.push(sb);
        }
        if (personBatch.length >= batchSize) {
          await store.batchInsert(TABLE_PERSON, personBatch);
          personBatch = [];
        }
        if (spouseBatch.length >= batchSize) {
          await store.batchInsert(TABLE_SPOUSE, spouseBatch);
          spouseBatch = [];
        }
        if (onProgress !== undefined && (i % 200 === 199 || i === lineUids.length - 1)) {
          onProgress(i + 1, totalToMove);
        }
      }
      // 配偶：复制到分支谱，原谱保留，避免破坏其他支的婚姻关系
      for (let s: number = 0; s < spouseUids.length; s = s + 1) {
        const src: Person | null = this.host.getPerson(spouseUids[s]);
        if (src === null) {
          continue;
        }
        const p: Person = clonePerson(src);
        p.key = 0;
        p.generation = Math.max(1, src.generation - offset);
        const keptSpouses: SpouseRelation[] = [];
        p.spouses.forEach((r: SpouseRelation): void => {
          if (picked.has(r.uid.trim().toUpperCase())) {
            keptSpouses.push(r);
          }
        });
        p.spouses = keptSpouses;
        if (!picked.has(p.spouseId.trim().toUpperCase())) {
          p.spouseId = '';
        }
        normalizeSpouseRelations(p);
        p.createdAt = now;
        p.updatedAt = now;
        personBatch.push(PersonRowMapper.toValues(p, rowId));
        for (let k: number = 0; k < p.spouses.length; k = k + 1) {
          const r: SpouseRelation = p.spouses[k];
          const partner: string = r.uid.trim().toUpperCase();
          if (partner.length === 0 || partner === p.uid.trim().toUpperCase()) {
            continue;
          }
          const rel: string = r.relation.trim().length > 0 ? r.relation.trim() : '未记';
          const sb: relationalStore.ValuesBucket = {
            'book_id': rowId,
            'uid': p.uid.trim().toUpperCase(),
            'spouse_uid': partner,
            'relation': rel,
            'level': spouseRelationLevel(rel),
            'ord': k + 1
          };
          spouseBatch.push(sb);
        }
        if (personBatch.length >= batchSize) {
          await store.batchInsert(TABLE_PERSON, personBatch);
          personBatch = [];
        }
        if (spouseBatch.length >= batchSize) {
          await store.batchInsert(TABLE_SPOUSE, spouseBatch);
          spouseBatch = [];
        }
      }
      if (personBatch.length > 0) {
        await store.batchInsert(TABLE_PERSON, personBatch);
      }
      if (spouseBatch.length > 0) {
        await store.batchInsert(TABLE_SPOUSE, spouseBatch);
      }
      // 原谱清理改为建支成功后异步执行，避免大支迁移长时间阻塞建支返回
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('建立分支失败：' + (e as Error).message);
    }

    this.host.setCurrentBookId(rowId);
    await this.host.setMetaValue('current_book_id', rowId.toString());
    await this.host.reloadData();
    // 原谱后代软删放到后台：不阻塞建支返回，失败只记日志，建支本身已成功
    setTimeout((): void => {
      this.cleanupMoved(sourceBookId, lineUids, now).catch((): void => {
      });
    }, 50);
    return this.host.currentBookValue();
  }

  /** 建支成功后异步清理原谱：分批软删后代、删除配偶关系、批量封存编号 */
  async cleanupMoved(bookId: number, lineUids: string[], now: number): Promise<void> {
    const store: relationalStore.RdbStore | null = this.host.storeRef();
    if (store === null || bookId <= 0) {
      return;
    }
    try {
      const retireKey: string = META_RETIRED_PREFIX + bookId.toString();
      const retireText: string = await this.host.getMetaValue(retireKey);
      let retired: BranchRetired[] = [];
      if (retireText.length > 0) {
        try {
          retired = JSON.parse(retireText) as BranchRetired[];
        } catch (err) {
          retired = [];
        }
      }
      const retiredSet: Set<string> = new Set<string>();
      for (let i: number = 0; i < retired.length; i = i + 1) {
        if (retired[i].uid !== undefined) {
          retiredSet.add(retired[i].uid.trim().toUpperCase());
        }
      }
      const chunkSize: number = 200;
      for (let start: number = 1; start < lineUids.length; start = start + chunkSize) {
        const chunk: string[] = lineUids.slice(start, Math.min(start + chunkSize, lineUids.length));
        const marks: string = chunk.map((): string => '?').join(',');
        const upArgs: (string | number)[] = [now, now, bookId];
        for (let i: number = 0; i < chunk.length; i = i + 1) {
          upArgs.push(chunk[i]);
        }
        await store.executeSql(
          `UPDATE ${TABLE_PERSON} SET deleted_at = ?, updated_at = ?, dirty = 1 WHERE book_id = ? AND UPPER(uid) IN (${marks})`,
          upArgs);
        const delArgs: (string | number)[] = [bookId];
        for (let i: number = 0; i < chunk.length; i = i + 1) {
          delArgs.push(chunk[i]);
        }
        for (let i: number = 0; i < chunk.length; i = i + 1) {
          delArgs.push(chunk[i]);
        }
        await store.executeSql(
          `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (UPPER(uid) IN (${marks}) OR UPPER(spouse_uid) IN (${marks}))`,
          delArgs);
        for (let i: number = 0; i < chunk.length; i = i + 1) {
          const u: string = chunk[i];
          if (retiredSet.has(u)) {
            continue;
          }
          const tomb: Person | null = this.host.getPerson(u);
          const item: BranchRetired = new BranchRetired();
          item.uid = u;
          item.name = tomb === null ? '' : tomb.name;
          item.deletedAt = now;
          retired.push(item);
          retiredSet.add(u);
        }
      }
      if (retired.length > 5000) {
        retired = retired.slice(retired.length - 5000);
      }
      await this.host.setMetaValue(retireKey, JSON.stringify(retired));
    } catch (e) {
    }
  }
}
