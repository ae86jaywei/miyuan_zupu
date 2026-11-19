import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  Person, SpouseRelation, clonePerson, normalizeSpouseRelations, spouseRelationLevel,
  RelationGraph, RepairReport, IntegrityReport, IntegrityIssue
} from 'common_base';
import { ImportPlan, ImportOptions, ImportPlanner, ImportResult } from './ImportPlanner';
import { TABLE_PERSON, TABLE_SPOUSE } from './db/DatabaseSchema';
import { PersonRowMapper } from './db/PersonRowMapper';
import { PeopleStore } from './PeopleStore';
import { PersonRepository } from './PersonRepository';

const TAG: string = '[Genealogy][Import]';

/**
 * 导入宿主接口：由 `GenealogyService` 实现，暴露导入编排所需的少量状态与工具。
 */
export interface ImportHost {
  storeRef(): relationalStore.RdbStore | null;
  currentBookIdValue(): number;
  retiredMap(): Map<string, string>;
  retiredNameOf(uid: string): string;
  nextUid(gender: string, extra?: Set<string>): string;
  clearRetired(bookId: number): Promise<void>;
  reloadData(): Promise<void>;
  checkIntegrity(): IntegrityReport;
}

/**
 * 导入编排域：批量新增、导入计划生成、计划落库与全量替换。
 *
 * 从 `GenealogyService` 拆出，事务、分批写入与进度回调语义保持不变。
 */
export class ImportManager {
  private host: ImportHost;
  private peopleStore: PeopleStore;
  private repository: PersonRepository;

  constructor(host: ImportHost, peopleStore: PeopleStore, repository: PersonRepository) {
    this.host = host;
    this.peopleStore = peopleStore;
    this.repository = repository;
  }

  /** 批量新增（导入使用），返回成功条数 */
  async importPeople(list: Person[], mergeStrategy: string): Promise<number> {
    if (this.host.currentBookIdValue() <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    let count: number = 0;
    // 批量导入时 people 只每 50 条刷新一次，需单独记录本批已分配的编号
    const batchUsed: Set<string> = new Set<string>();
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = clonePerson(list[i]);
      p.uid = p.uid.trim().toUpperCase();
      normalizeSpouseRelations(p);
      if (p.uid.length === 0) {
        // 导入文件缺少唯一ID时补一个未使用的编号，避免空ID无法建立亲属关系
        p.uid = this.host.nextUid(p.gender, batchUsed);
        batchUsed.add(p.uid);
      }
      if (this.host.retiredNameOf(p.uid).length > 0) {
        // 该编号曾用于已删除族人：跳过或改用新编号，避免旧关系被错误挂接
        if (mergeStrategy === 'skip') {
          continue;
        }
        if (mergeStrategy === 'newId') {
          p.uid = this.host.nextUid(p.gender, batchUsed);
          batchUsed.add(p.uid);
        }
      }
      const exist: Person | undefined = this.peopleStore.getMap().get(p.uid);
      if (exist !== undefined) {
        if (mergeStrategy === 'skip') {
          continue;
        }
        if (mergeStrategy === 'replace') {
          p.key = exist.key;
          await this.repository.upsert(p);
          await this.repository.saveSpouses(p.uid, p.spouses);
          batchUsed.add(p.uid);
          count++;
          continue;
        }
        if (mergeStrategy === 'newId') {
          p.uid = this.host.nextUid(p.gender, batchUsed);
          batchUsed.add(p.uid);
        }
      }
      await this.repository.upsert(p);
      await this.repository.saveSpouses(p.uid, p.spouses);
      batchUsed.add(p.uid);
      count++;
      // 每 50 条刷新一次，避免内存映射未更新导致 ID 重复
      if (count % 50 === 0) {
        await this.host.reloadData();
      }
    }
    await this.host.reloadData();
    return count;
  }

  /**
   * 生成导入计划（纯内存，不落库）：身份匹配 + 全局 ID 重映射。
   * strategy 与旧界面保持一致：
   *   auto（智能匹配）/ skip（冲突跳过）/ replace（冲突覆盖）/ newId（冲突另编号）。
   * asNewBook 为 true 时按「另立独立族谱」规划：不与当前谱人物做身份匹配，
   * 也不受当前谱已删除编号限制，避免把另一部族谱的人员并进当前谱导致编号冲突。
   */
  async planImport(list: Person[], strategy: string, asNewBook: boolean = false,
    onProgress?: (done: number, total: number) => void): Promise<ImportPlan> {
    const opt: ImportOptions = new ImportOptions();
    if (strategy === 'skip' || strategy === 'defer') {
      opt.conflictPolicy = 'defer';
    } else if (strategy === 'replace' || strategy === 'merge') {
      opt.conflictPolicy = 'merge';
      opt.localFieldFirst = false;
    } else if (strategy === 'newId' || strategy === 'new') {
      opt.conflictPolicy = 'new';
    } else {
      opt.conflictPolicy = 'auto';
    }
    return ImportPlanner.plan(list, asNewBook ? [] : this.peopleStore.getAll(),
      asNewBook ? new Map<string, string>() : this.host.retiredMap(), opt);
  }

  /**
   * 执行导入计划：
   *   事务内逐条落库 → 关系图修复（悬空清理 + 配偶双向）→ 体检 → 提交；
   *   任何异常都回滚事务，避免留下半成品。
   */
  async applyImportPlan(plan: ImportPlan,
    onProgress?: (done: number, total: number) => void): Promise<ImportResult> {
    const bookId: number = this.host.currentBookIdValue();
    if (bookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    const storeRef: relationalStore.RdbStore | null = this.host.storeRef();
    if (storeRef === null) {
      throw new Error('数据库未就绪');
    }
    const store: relationalStore.RdbStore = storeRef;
    const result: ImportResult = new ImportResult();
    const total: number = plan.people.length;
    /** 事务是否已提交：提交后的错误不再回滚，避免把已落库的族人删掉 */
    let committed: boolean = false;
    // 整段写入放进一个事务：失败由 SQLite 回滚，不再序列化「整谱快照」。
    // 数万人的快照是几十 MB 的 JSON，序列化 + 写单行 TEXT 比导入本身还慢；
    // 事务还省掉了逐条 fsync，实测 3.6 万条从约 9 分钟降到分钟级。
    try {
      store.beginTransaction();
      // 逐条 insert/update 每次都要跨线程做一次 IPC（实测约 90ms/条，数万人要几十分钟）。
      // 改为「先分批删除被覆盖的 uid，再分批 batchInsert」：SQL 从十万条降到百来条。
      // 删除只覆盖本次导入的 uid，导入文件里没有的本机族人不受影响；事务失败会整体回滚。
      const batchSize: number = 500;
      for (let start: number = 0; start < total; start = start + batchSize) {
        const end: number = Math.min(start + batchSize, total);
        const marks: string[] = [];
        const args: relationalStore.ValueType[] = [bookId];
        for (let j: number = start; j < end; j++) {
          marks.push('?');
          args.push(plan.people[j].uid.trim().toUpperCase());
        }
        const inList: string = marks.join(',');
        await store.executeSql(
          `DELETE FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) IN (${inList})`, args);
        await store.executeSql(
          `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND UPPER(uid) IN (${inList})`, args);
      }
      let personBatch: relationalStore.ValuesBucket[] = [];
      let spouseBatch: relationalStore.ValuesBucket[] = [];
      for (let i: number = 0; i < total; i++) {
        const p: Person = clonePerson(plan.people[i]);
        p.uid = p.uid.trim().toUpperCase();
        normalizeSpouseRelations(p);
        const exist: Person | undefined = this.peopleStore.getMap().get(p.uid);
        if (exist !== undefined) {
          p.createdAt = exist.createdAt > 0 ? exist.createdAt : p.createdAt;
          p.updatedAt = Date.now();
        }
        personBatch.push(PersonRowMapper.toValues(p, bookId));
        for (let s: number = 0; s < p.spouses.length; s++) {
          const r: SpouseRelation = p.spouses[s];
          const partner: string = r.uid.trim().toUpperCase();
          if (partner.length === 0 || partner === p.uid) {
            continue;
          }
          const rel: string = r.relation.trim().length > 0 ? r.relation.trim() : '未记';
          spouseBatch.push({
            'book_id': bookId,
            'uid': p.uid,
            'spouse_uid': partner,
            'relation': rel,
            'level': spouseRelationLevel(rel),
            'ord': s + 1
          });
        }
        result.saved = result.saved + 1;
        if (personBatch.length >= batchSize) {
          await store.batchInsert(TABLE_PERSON, personBatch);
          personBatch = [];
        }
        if (spouseBatch.length >= batchSize) {
          await store.batchInsert(TABLE_SPOUSE, spouseBatch);
          spouseBatch = [];
        }
        // 每 200 条回报一次进度（一批几千条也只回刷几次，避免频繁触发界面重建）
        if (onProgress !== undefined && (i % 200 === 199 || i === total - 1)) {
          onProgress(i + 1, total);
        }
      }
      if (personBatch.length > 0) {
        await store.batchInsert(TABLE_PERSON, personBatch);
      }
      if (spouseBatch.length > 0) {
        await store.batchInsert(TABLE_SPOUSE, spouseBatch);
      }
      // 先提交、再重读：ArkTS 的异步 SQL 走独立连接，事务内 SELECT 读不到未提交数据。
      // 旧实现把 reload 放在事务里，首次建谱导入后人员列表会被重读成空数组 ——
      // 库里其实已有几万人，界面却显示 0 人，用户只能再导入一次才「看得见」。
      store.commit();
      committed = true;
      // 提交后先把导入过程中的大对象全部释放，再重读库：
      // 「另编号」会把整谱翻倍（4 万 → 8 万），若此时仍持有导入文件解析出的
      // 人物、计划克隆副本和旧内存数据，重读 + 重建谱系会直接 OutOfMemoryError
      //（实测堆已用到 447MB，本地堆上限约 474MB）。
      plan.people = [];
      plan.matches = [];
      plan.remaps = [];
      plan.warnings = [];
      plan.errors = [];
      this.peopleStore.reset();
      await this.host.reloadData();
      // 关系图修复：断链清理 + 配偶双向补齐（世代默认只统计，不改史料）
      const repaired: RepairReport = RelationGraph.repair(this.peopleStore.getAll(), false);
      for (let i: number = 0; i < repaired.touched.length; i++) {
        const target: Person | undefined = this.peopleStore.getMap().get(repaired.touched[i]);
        if (target === undefined) {
          continue;
        }
        await this.repository.upsert(target);
        await this.repository.saveSpouses(target.uid, target.spouses);
      }
      if (repaired.touched.length > 0) {
        await this.host.reloadData();
      }
      result.danglingCount = repaired.danglingCount;
      result.oneWaySpouseCount = repaired.oneWaySpouseCount;
      result.generationMismatchCount = repaired.generationMismatchCount;
      const report: IntegrityReport = this.host.checkIntegrity();
      report.issues.forEach((issue: IntegrityIssue): void => {
        if (issue.level === 'error') {
          result.integrityErrors = result.integrityErrors + 1;
        }
      });
      hilog.info(0x0000, TAG, 'import applied, saved=%{public}d', result.saved);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      if (!committed) {
        hilog.error(0x0000, TAG, 'import failed, rolling back: %{public}s', err.message);
        try {
          store.rollBack();
        } catch (rb) {
          hilog.error(0x0000, TAG, 'import rollback failed');
        }
        // 回滚后必须重读库修正内存状态
        await this.host.reloadData();
        throw new Error('导入写入失败，已回滚：' + err.message);
      }
      // 已提交：族人已经落库，关系修复阶段出错不能回滚，
      // 否则会把刚导入的整谱删掉；只记录日志并按已写入人数返回。
      hilog.error(0x0000, TAG, 'import repair failed after commit: %{public}s', err.message);
      await this.host.reloadData();
      return result;
    }
  }

  /** 全量替换当前族谱的人物（恢复备份） */
  async replaceAll(list: Person[]): Promise<void> {
    const bookId: number = this.host.currentBookIdValue();
    if (bookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    const store: relationalStore.RdbStore = this.host.storeRef() as relationalStore.RdbStore;
    await store.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [bookId]);
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [bookId]);
    // 全量替换后，历史ID与旧关系不再可信，清空复用黑名单避免误报
    await this.host.clearRetired(bookId);
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = clonePerson(list[i]);
      p.uid = p.uid.trim().toUpperCase();
      normalizeSpouseRelations(p);
      await this.repository.upsert(p);
      await this.repository.saveSpouses(p.uid, p.spouses);
    }
    await this.host.reloadData();
  }
}
