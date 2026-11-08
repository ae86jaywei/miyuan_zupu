import { Person, SpouseRelation, clonePerson, cloneSpouseRelation, spouseRelationLevel } from '../model/Person';
import { IntegrityReport, IntegrityIssue } from '../model/Integrity';
import { IntegrityService } from './IntegrityService';
import { UidAllocator } from '../util/IdGenerator';

/**
 * 导入合并引擎。
 *
 * 解决的根因：旧实现只对「导入文件里的单条记录」做局部处理（跳过 / 覆盖 / 另编号），
 * 从不改写「文件内部所有人共享的 uid 引用网」，也不管本机已有引用，
 * 于是断链成根（多出宗支）、关系错挂、世代与树深度不一致（重叠）。
 *
 * 新流程是三段式：
 *   ① 身份匹配：用业务指纹（姓名 / 性别 / 生日 / 父母姓名 / 世代）判断「不同 uid 是否同一人」；
 *   ② 全局重映射：先分配目标 uid，再统一改写 fatherId / motherId / spouseId / spouses[].uid；
 *   ③ 落库后由 RelationGraph 做关系图修复（断链清理、配偶双向补齐、世代校正）。
 *
 * 本文件只做纯内存计算，不改数据库，便于预览与回滚。
 */

/** 业务指纹：不依赖 uid，用于识别「同一个人」 */
export class PersonFingerprint {
  /** 归一化姓名（去掉所有空白） */
  nameKey: string = '';
  gender: string = '';
  /** 出生日期原文 */
  birthDate: string = '';
  /** 出生年份（解析不到为 0） */
  birthYear: number = 0;
  /** 父亲姓名（按 fatherId 解析） */
  fatherName: string = '';
  /** 母亲姓名（按 motherId 解析） */
  motherName: string = '';
  generation: number = 0;
  generationChar: string = '';
  /** 配偶姓名（排序后逗号拼接） */
  spouseKeys: string = '';
}

/** 单条身份匹配结果 */
export class IdentityMatch {
  sourceUid: string = '';
  targetUid: string = '';
  /** merge（并入本机已有）/ new（分配新编号）/ skip（不导入） */
  action: string = 'new';
  score: number = 0;
  /** 分数处于待核对区间：已按新人导入，但提示人工复核 */
  review: boolean = false;
  reason: string = '';
}

/** uid 重映射项 */
export class UidRemap {
  oldUid: string = '';
  newUid: string = '';
}

/** 导入选项 */
export class ImportOptions {
  /** 指纹分 ≥ 该值自动合并 */
  autoMergeScore: number = 85;
  /** 指纹分 ≥ 该值视为「疑似同一人」（供 defer / new 策略使用） */
  reviewScore: number = 60;
  /** auto 智能匹配 / defer 冲突跳过 / merge 冲突覆盖 / new 冲突另编号 */
  conflictPolicy: string = 'auto';
  /** 字段冲突时是否以本机值为准 */
  localFieldFirst: boolean = true;
  /** 是否按树深度回填世代（默认关闭，避免篡改史料） */
  fixGenerationByDepth: boolean = false;
}

/** 导入计划：先算后写，可预览、可回滚 */
export class ImportPlan {
  matches: IdentityMatch[] = [];
  remaps: UidRemap[] = [];
  /** 最终要写入的人员（已重映射、已合并） */
  people: Person[] = [];
  warnings: string[] = [];
  errors: string[] = [];
  incomingCount: number = 0;

  mergeCount(): number {
    let n: number = 0;
    this.matches.forEach((m: IdentityMatch): void => {
      if (m.action === 'merge') {
        n = n + 1;
      }
    });
    return n;
  }

  newCount(): number {
    let n: number = 0;
    this.matches.forEach((m: IdentityMatch): void => {
      if (m.action === 'new') {
        n = n + 1;
      }
    });
    return n;
  }

  skipCount(): number {
    let n: number = 0;
    this.matches.forEach((m: IdentityMatch): void => {
      if (m.action === 'skip') {
        n = n + 1;
      }
    });
    return n;
  }

  reviewCount(): number {
    let n: number = 0;
    this.matches.forEach((m: IdentityMatch): void => {
      if (m.review) {
        n = n + 1;
      }
    });
    return n;
  }

  summary(): string {
    const lines: string[] = [];
    lines.push('解析 ' + this.incomingCount.toString() + ' 条；合并 ' + this.mergeCount().toString() +
      ' 人，新增 ' + this.newCount().toString() + ' 人，跳过 ' + this.skipCount().toString() + ' 人');
    if (this.reviewCount() > 0) {
      lines.push('待核对 ' + this.reviewCount().toString() + ' 人（已按新人导入，可稍后在人物详情里合并）');
    }
    if (this.warnings.length > 0) {
      lines.push('提示 ' + this.warnings.length.toString() + ' 条：');
      const maxW: number = this.warnings.length > 5 ? 5 : this.warnings.length;
      for (let i: number = 0; i < maxW; i++) {
        lines.push('· ' + this.warnings[i]);
      }
    }
    if (this.errors.length > 0) {
      lines.push('无法导入 ' + this.errors.length.toString() + ' 条：');
      const maxE: number = this.errors.length > 5 ? 5 : this.errors.length;
      for (let i: number = 0; i < maxE; i++) {
        lines.push('· ' + this.errors[i]);
      }
    }
    if (this.people.length === 0) {
      lines.push('没有可写入的记录。');
    }
    return lines.join('\n');
  }
}

/** 导入执行结果 */
export class ImportResult {
  saved: number = 0;
  integrityErrors: number = 0;
  danglingCount: number = 0;
  oneWaySpouseCount: number = 0;
  generationMismatchCount: number = 0;

  summary(): string {
    let text: string = '写入 ' + this.saved.toString() + ' 人';
    if (this.danglingCount > 0) {
      text = text + '，清理悬空关系 ' + this.danglingCount.toString() + ' 处';
    }
    if (this.oneWaySpouseCount > 0) {
      text = text + '，补齐配偶 ' + this.oneWaySpouseCount.toString() + ' 对';
    }
    if (this.integrityErrors > 0) {
      text = text + '，仍有 ' + this.integrityErrors.toString() + ' 个严重问题待处理';
    }
    return text;
  }
}

/** 身份指纹计算与打分 */
export class IdentityMatcher {
  /** 归一化姓名：去掉全部空白（含全角空格） */
  static normalizeName(name: string): string {
    return name.replace(/[\s\u3000]+/g, '');
  }

  /** 从出生日期原文中提取四位年份（解析不到返回 0） */
  static birthYear(date: string): number {
    const m: RegExpMatchArray | null = date.match(/([0-9]{4})/);
    if (m === null) {
      return 0;
    }
    const y: number = parseInt(m[1], 10);
    if (isNaN(y) || y < 1000 || y > 2200) {
      return 0;
    }
    return y;
  }

  /** 构造业务指纹；names 为 uid → 姓名 的映射（含本机与导入文件） */
  static fingerprint(p: Person, names: Map<string, string>): PersonFingerprint {
    const fp: PersonFingerprint = new PersonFingerprint();
    fp.nameKey = IdentityMatcher.normalizeName(p.name);
    fp.gender = p.gender;
    fp.birthDate = p.birthDate.trim();
    fp.birthYear = IdentityMatcher.birthYear(p.birthDate);
    const fName: string | undefined = names.get(p.fatherId.trim().toUpperCase());
    fp.fatherName = fName === undefined ? '' : IdentityMatcher.normalizeName(fName);
    const mName: string | undefined = names.get(p.motherId.trim().toUpperCase());
    fp.motherName = mName === undefined ? '' : IdentityMatcher.normalizeName(mName);
    fp.generation = p.generation;
    fp.generationChar = p.generationChar.trim();
    const spouseNames: string[] = [];
    p.spouses.forEach((r: SpouseRelation): void => {
      const n: string | undefined = names.get(r.uid.trim().toUpperCase());
      if (n !== undefined && n.trim().length > 0) {
        spouseNames.push(IdentityMatcher.normalizeName(n));
      }
    });
    spouseNames.sort();
    fp.spouseKeys = spouseNames.join(',');
    return fp;
  }

  /**
   * 相似度打分（0-100）。
   * 姓名不一致或性别相反直接判 0 分（视为不同人）。
   */
  static score(a: PersonFingerprint, b: PersonFingerprint): number {
    if (a.nameKey.length === 0 || b.nameKey.length === 0 || a.nameKey !== b.nameKey) {
      return 0;
    }
    if (a.gender.length > 0 && b.gender.length > 0 && a.gender !== b.gender) {
      return 0;
    }
    let s: number = 40;
    if (a.gender === b.gender) {
      s = s + 10;
    } else {
      s = s + 4;
    }
    if (a.birthDate.length > 0 && b.birthDate.length > 0) {
      if (a.birthDate === b.birthDate) {
        s = s + 20;
      } else if (a.birthYear > 0 && a.birthYear === b.birthYear) {
        s = s + 12;
      }
    } else {
      s = s + 8;
    }
    if (a.fatherName.length > 0 && b.fatherName.length > 0) {
      if (a.fatherName === b.fatherName) {
        s = s + 15;
      }
    } else {
      s = s + 5;
    }
    if (a.generation > 0 && b.generation > 0) {
      if (a.generation === b.generation) {
        s = s + 10;
      }
    } else {
      s = s + 3;
    }
    if (a.generationChar.length > 0 && a.generationChar === b.generationChar) {
      s = s + 2;
    }
    if (a.spouseKeys.length > 0 && a.spouseKeys === b.spouseKeys) {
      s = s + 3;
    }
    return s;
  }
}

/** 候选扫描结果（同世代优先、低分时退回全桶，两轮扫描共用） */
class BestMatch {
  score: number = 0;
  person: Person | null = null;
}

/**
 * 导入计划生成器：身份匹配 → 全局 ID 重映射。
 * 全程只读内存，不落库。
 */
export class ImportPlanner {
  static async plan(incoming: Person[], local: Person[], retired: Map<string, string>,
    opt: ImportOptions, onProgress?: (done: number, total: number) => void): Promise<ImportPlan> {
    const plan: ImportPlan = new ImportPlan();
    plan.incomingCount = incoming.length;

    // 本机索引
    const localMap: Map<string, Person> = new Map<string, Person>();
    const localSet: Set<string> = new Set<string>();
    const names: Map<string, string> = new Map<string, string>();
    local.forEach((p: Person): void => {
      const u: string = ImportPlanner.up(p.uid);
      if (u.length === 0) {
        return;
      }
      localSet.add(u);
      localMap.set(u, p);
      if (p.name.trim().length > 0 && names.get(u) === undefined) {
        names.set(u, p.name);
      }
    });
    // 导入文件内部姓名也要登记，才能解析「文件内父子」姓名
    incoming.forEach((p: Person): void => {
      const u: string = ImportPlanner.up(p.uid);
      if (u.length > 0 && p.name.trim().length > 0 && names.get(u) === undefined) {
        names.set(u, p.name);
      }
    });
    // 本机同名同性别候选索引（用于指纹匹配召回）
    const byNameGender: Map<string, Person[]> = new Map<string, Person[]>();
    // 再按世代分桶：谱内同名极多（如大量「韦氏」），只扫同世代能大幅减少候选量
    const byNameGenderGen: Map<string, Person[]> = new Map<string, Person[]>();
    local.forEach((p: Person): void => {
      const nk: string = IdentityMatcher.normalizeName(p.name);
      if (nk.length === 0) {
        return;
      }
      const key: string = nk + '|' + p.gender;
      let arr: Person[] | undefined = byNameGender.get(key);
      if (arr === undefined) {
        arr = [];
        byNameGender.set(key, arr);
      }
      arr.push(p);
      if (p.generation > 0) {
        const gKey: string = key + '|' + p.generation.toString();
        let gArr: Person[] | undefined = byNameGenderGen.get(gKey);
        if (gArr === undefined) {
          gArr = [];
          byNameGenderGen.set(gKey, gArr);
        }
        gArr.push(p);
      }
    });

    // 已占用编号（本机 + 已删除黑名单 + 本批已分配）
    const used: Set<string> = new Set<string>();
    localSet.forEach((u: string): void => {
      used.add(u);
    });
    retired.forEach((name: string, uid: string): void => {
      if (uid.trim().length > 0) {
        used.add(uid.trim().toUpperCase());
      }
    });
    // 本机数据里被他人引用、但本人已不存在的编号（悬空引用）也算已占用：
    // 否则新导入的人恰好分到该编号，就会凭空顶替成别人的父母/配偶（世代倒挂、多出宗支）
    local.forEach((p: Person): void => {
      ImportPlanner.reserveRef(p.fatherId, localSet, used);
      ImportPlanner.reserveRef(p.motherId, localSet, used);
      ImportPlanner.reserveRef(p.spouseId, localSet, used);
      p.spouses.forEach((r: SpouseRelation): void => {
        ImportPlanner.reserveRef(r.uid, localSet, used);
      });
    });

    // 一次性把已占用编号建成索引，之后每次分配摊销 O(1)。
    // 旧实现每次分配都重扫整谱 + 黑名单并逐条正则，导入 4 万人时会退化成 O(n²)，
    // 主线程连续阻塞 >6 秒后被系统判定 THREAD_BLOCK_6S 直接杀死进程。
    const allocator: UidAllocator = new UidAllocator();
    used.forEach((u: string): void => {
      allocator.reserve(u);
    });

    // 本机指纹缓存：同名同姓候选常被多条导入记录反复打分，
    // 每次重算都要解析生日正则、遍历配偶，4 万条导入下开销可观。
    // names 此时已完整（本机 + 导入文件），缓存结果与逐次计算一致。
    const localFp: Map<string, PersonFingerprint> = new Map<string, PersonFingerprint>();
    local.forEach((p: Person): void => {
      const u: string = ImportPlanner.up(p.uid);
      if (u.length > 0 && localFp.get(u) === undefined) {
        localFp.set(u, IdentityMatcher.fingerprint(p, names));
      }
    });

    // 计划内按目标 uid 累积（同一人可能有多条来源）
    const planned: Map<string, Person> = new Map<string, Person>();
    const remap: Map<string, string> = new Map<string, string>();
    const sourceSeen: Set<string> = new Set<string>();
    const matched: IdentityMatch[] = [];

    for (let i: number = 0; i < incoming.length; i++) {
      const src: Person = incoming[i];
      const p: Person = clonePerson(src);
      p.uid = ImportPlanner.up(p.uid);
      const match: IdentityMatch = new IdentityMatch();
      match.sourceUid = p.uid;

      // 文件内部编号重复：数据缺陷，只认第一条，其余不导入
      if (p.uid.length > 0 && sourceSeen.has(p.uid)) {
        match.action = 'skip';
        match.reason = '文件内编号重复';
        plan.errors.push('导入文件内编号重复：' + p.uid + '（' + p.name + '），重复条目已跳过');
        matched.push(match);
        continue;
      }
      if (p.uid.length > 0) {
        sourceSeen.add(p.uid);
      }

      const existByUid: Person | undefined = p.uid.length > 0 ? localMap.get(p.uid) : undefined;
      // 同编号身份比对：error 表示「编号相同但人物不同」
      let sameUidConflict: boolean = false;
      if (existByUid !== undefined) {
        const rep: IntegrityReport = IntegrityService.compare([existByUid], [p], '本机', '导入');
        rep.issues.forEach((issue: IntegrityIssue): void => {
          if (issue.level === 'error') {
            sameUidConflict = true;
          }
        });
      }
      let bestLocal: Person | null = null;
      let bestScore: number = 0;
      if (existByUid !== undefined && !sameUidConflict) {
        // 同编号且身份一致：直接按同一人合并，不再扫描同名候选桶。
        // 数万条重导入（本机已存在同一编号）时这是唯一的快速路径，
        // 否则每条都要扫数千个同名候选，主线程必然超过 6 秒被系统强杀。
        bestLocal = existByUid;
        bestScore = 100;
      } else {
        const fp: PersonFingerprint = IdentityMatcher.fingerprint(p, names);
        const best: BestMatch = new BestMatch();
        // 先扫同世代候选桶；同世代没有达到自动合并线时再退回全桶，
        // 兼顾「世代写错但确实是同一人」的数据。每扫 500 人让出一次主线程，
        // 避免同名极多（如大量「韦氏」）时单个循环阻塞超过 6 秒被系统强杀。
        const bucketKey: string = fp.nameKey + '|' + p.gender;
        const allCands: Person[] | undefined = byNameGender.get(bucketKey);
        const sameGenCands: Person[] | undefined = p.generation > 0
          ? byNameGenderGen.get(bucketKey + '|' + p.generation.toString()) : undefined;
        if (sameGenCands !== undefined) {
          await ImportPlanner.scanBucket(sameGenCands, p.uid, fp, localFp, names, best);
        }
        if (best.score < opt.autoMergeScore && allCands !== undefined) {
          await ImportPlanner.scanBucket(allCands, p.uid, fp, localFp, names, best);
        }
        bestLocal = best.person;
        bestScore = best.score;
      }

      let action: string = 'new';
      let target: string = '';
      let review: boolean = false;
      let reason: string = '';

      if (existByUid !== undefined && !sameUidConflict) {
        if (opt.conflictPolicy === 'defer') {
          action = 'skip';
          reason = '策略跳过：同编号已存在';
        } else if (opt.conflictPolicy === 'new') {
          action = 'new';
          reason = '策略另编号：同编号改新号';
        } else {
          action = 'merge';
          reason = '同编号且身份一致，合并';
        }
      } else if (existByUid !== undefined && sameUidConflict) {
        // 编号在本机属于另一个人：先看能不能按身份并入本机同名同性别的人
        if (bestLocal !== null && bestScore >= opt.autoMergeScore) {
          action = 'merge';
          reason = '编号 ' + p.uid + ' 在本机属于「' + existByUid.name + '」，按身份并入「' +
            bestLocal.name + '（' + bestLocal.uid + '）」';
          plan.warnings.push('编号 ' + p.uid + ' 本机是「' + existByUid.name + '」，导入的「' + p.name +
            '」按身份并入「' + bestLocal.name + '（' + bestLocal.uid + '）」');
        } else if (opt.conflictPolicy === 'defer') {
          action = 'skip';
          reason = '策略跳过：同编号已存在';
        } else {
          action = 'new';
          reason = '同编号但身份不符（姓名/父母等不一致），另编号';
          plan.warnings.push('编号 ' + p.uid + ' 本机是「' + existByUid.name + '」，导入是「' + p.name +
            '」，已为新记录分配编号');
        }
      } else if (bestLocal !== null) {
        // 编号不同但疑似同一人
        if (opt.conflictPolicy === 'defer' && bestScore >= opt.reviewScore) {
          action = 'skip';
          reason = '策略跳过：与「' + bestLocal.name + '」疑似同一人（' + bestScore.toString() + ' 分）';
        } else if (opt.conflictPolicy === 'new' && bestScore >= opt.reviewScore) {
          action = 'new';
          reason = '策略另编号：与「' + bestLocal.name + '」疑似同一人（' + bestScore.toString() + ' 分）';
        } else if (bestScore >= opt.autoMergeScore) {
          action = 'merge';
          reason = '与本机「' + bestLocal.name + '（' + bestLocal.uid + '）」指纹一致（' +
            bestScore.toString() + ' 分）';
        } else if (opt.conflictPolicy === 'merge' && bestScore >= opt.reviewScore) {
          action = 'merge';
          reason = '策略覆盖：与「' + bestLocal.name + '」疑似同一人（' + bestScore.toString() + ' 分）';
        } else {
          action = 'new';
          if (bestScore >= opt.reviewScore) {
            review = true;
            reason = '与「' + bestLocal.name + '」相似（' + bestScore.toString() + ' 分），按新人导入，请复核';
            plan.warnings.push('「' + p.name + '」与「' + bestLocal.name + '（' + bestLocal.uid +
              '）」相似度 ' + bestScore.toString() + ' 分，已作为新人导入');
          } else {
            reason = '新人物';
          }
        }
      } else {
        reason = '新人物（本机无匹配）';
      }

      if (action === 'merge') {
        const base: Person = bestLocal as Person;
        target = ImportPlanner.up(base.uid);
        match.targetUid = target;
        match.action = 'merge';
        match.score = bestScore;
        match.reason = reason;
        const merged: Person = ImportPlanner.mergePerson(base, p, opt.localFieldFirst, plan.warnings);
        planned.set(target, merged);
        remap.set(p.uid, target);
      } else if (action === 'new') {
        let newUid: string = ImportPlanner.up(p.uid);
        const needsNew: boolean = newUid.length === 0 || used.has(newUid);
        if (needsNew) {
          newUid = ImportPlanner.alloc(p.gender, allocator, used);
        } else {
          used.add(newUid);
          allocator.reserve(newUid);
        }
        p.uid = newUid;
        target = newUid;
        match.targetUid = target;
        match.action = 'new';
        match.score = bestScore;
        match.review = review;
        match.reason = reason;
        planned.set(target, p);
        if (ImportPlanner.up(src.uid).length > 0) {
          remap.set(ImportPlanner.up(src.uid), target);
        }
      } else {
        // skip：编号若在本机存在，引用仍可指向本机那个人
        match.action = 'skip';
        match.score = bestScore;
        match.reason = reason;
        if (existByUid !== undefined) {
          remap.set(p.uid, ImportPlanner.up(existByUid.uid));
        }
      }
      matched.push(match);
      if (i % 100 === 99) {
        if (onProgress !== undefined) {
          onProgress(i + 1, incoming.length);
        }
        await ImportPlanner.pause();
      }
    }

    // 第二遍：全局改写引用（含 merge 到本机、new 新编号、指向文件外/本机外的引用）
    const plannedList: Person[] = [];
    planned.forEach((p: Person): void => {
      plannedList.push(p);
    });
    for (let i: number = 0; i < plannedList.length; i++) {
      const p: Person = plannedList[i];
      ImportPlanner.applyRemap(p, remap, localSet, plan);
      plan.people.push(p);
      if (i % 100 === 99) {
        await ImportPlanner.pause();
      }
    }

    // 导出重映射表（便于排查）
    remap.forEach((newUid: string, oldUid: string): void => {
      if (oldUid !== newUid) {
        const item: UidRemap = new UidRemap();
        item.oldUid = oldUid;
        item.newUid = newUid;
        plan.remaps.push(item);
      }
    });

    plan.matches = matched;
    return plan;
  }

  /** 扫描一桶候选并维护最高分；每 500 人让出一次主线程 */
  private static async scanBucket(cands: Person[], pUid: string, fp: PersonFingerprint,
    localFp: Map<string, PersonFingerprint>, names: Map<string, string>,
    best: BestMatch): Promise<void> {
    let scanned: number = 0;
    for (let k: number = 0; k < cands.length; k++) {
      const c: Person = cands[k];
      const cKey: string = ImportPlanner.up(c.uid);
      if (cKey === pUid) {
        continue;
      }
      const cached: PersonFingerprint | undefined = localFp.get(cKey);
      const cfp: PersonFingerprint = cached === undefined ? IdentityMatcher.fingerprint(c, names) : cached;
      if (cached === undefined) {
        localFp.set(cKey, cfp);
      }
      const s: number = IdentityMatcher.score(fp, cfp);
      if (s > best.score) {
        best.score = s;
        best.person = c;
      }
      scanned++;
      if (scanned >= 500) {
        scanned = 0;
        await ImportPlanner.pause();
      }
    }
  }

  /** 让出主线程，给界面刷新与 GC 留出时间（数万条导入时避免 THREAD_BLOCK_6S） */
  private static pause(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, 0);
    });
  }

  /** 被引用但本机已不存在的人物编号 → 视为已占用，不允许新人复用 */
  private static reserveRef(ref: string, localSet: Set<string>, used: Set<string>): void {
    const u: string = ImportPlanner.up(ref);
    if (u.length > 0 && !localSet.has(u)) {
      used.add(u);
    }
  }

  /** 分配一个新编号（跳过本机、已删除黑名单与已分配编号；allocator 已含全部已占用编号） */
  private static alloc(gender: string, allocator: UidAllocator, used: Set<string>): string {
    const uid: string = allocator.take(gender);
    used.add(uid);
    return uid;
  }

  /** 统一改写一条人员的全部关系引用，引用不在导入范围又不在本机时清空 */
  private static applyRemap(p: Person, remap: Map<string, string>, localSet: Set<string>,
    plan: ImportPlan): void {
    p.fatherId = ImportPlanner.mapRef(p.fatherId, '父亲', remap, localSet, plan);
    p.motherId = ImportPlanner.mapRef(p.motherId, '母亲', remap, localSet, plan);
    // 自引用是脏数据：自己不能是自己的父/母，否则树会成环
    if (p.fatherId.length > 0 && p.fatherId === p.uid) {
      p.fatherId = '';
      plan.warnings.push('「' + p.name + '」父亲指向自己，已清空');
    }
    if (p.motherId.length > 0 && p.motherId === p.uid) {
      p.motherId = '';
      plan.warnings.push('「' + p.name + '」母亲指向自己，已清空');
    }
    p.spouseId = ImportPlanner.mapRef(p.spouseId, '主配偶', remap, localSet, plan);
    const list: SpouseRelation[] = [];
    p.spouses.forEach((r: SpouseRelation): void => {
      const id: string = ImportPlanner.mapRef(r.uid, '配偶', remap, localSet, plan);
      if (id.length === 0) {
        return;
      }
      const nr: SpouseRelation = new SpouseRelation();
      nr.uid = id;
      nr.relation = r.relation;
      nr.level = spouseRelationLevel(r.relation);
      nr.order = r.order;
      list.push(nr);
    });
    p.spouses = list;
    p.spouseId = p.spouses.length > 0 ? p.spouses[0].uid : '';
  }

  /** 单个引用重映射：优先用计划映射，其次保留本机已有，否则清空并记提示 */
  private static mapRef(uid: string, label: string, remap: Map<string, string>, localSet: Set<string>,
    plan: ImportPlan): string {
    const u: string = ImportPlanner.up(uid);
    if (u.length === 0) {
      return '';
    }
    const mapped: string | undefined = remap.get(u);
    if (mapped !== undefined) {
      return mapped;
    }
    if (localSet.has(u)) {
      return u;
    }
    const note: string = label + '引用 ' + u + ' 既不在导入文件也不在本谱，已清空（避免错挂）';
    if (plan.warnings.indexOf(note) < 0) {
      plan.warnings.push(note);
    }
    return '';
  }

  /** 字段级合并：默认本机非空优先，可切换为导入值优先 */
  private static mergePerson(local: Person, incoming: Person, localFirst: boolean,
    warnings: string[]): Person {
    const out: Person = clonePerson(local);
    out.uid = ImportPlanner.up(local.uid);
    out.generation = ImportPlanner.pickNumber(local.generation, incoming.generation, localFirst);
    out.name = ImportPlanner.pickText(local.name, incoming.name, localFirst);
    out.alias = ImportPlanner.pickText(local.alias, incoming.alias, localFirst);
    out.gender = ImportPlanner.pickText(local.gender, incoming.gender, localFirst);
    out.generationChar = ImportPlanner.pickText(local.generationChar, incoming.generationChar, localFirst);
    out.lifeStatus = ImportPlanner.pickText(local.lifeStatus, incoming.lifeStatus, localFirst);
    out.childStatus = ImportPlanner.pickText(local.childStatus, incoming.childStatus, localFirst);
    out.birthDate = ImportPlanner.pickText(local.birthDate, incoming.birthDate, localFirst);
    out.birthCalendar = ImportPlanner.pickText(local.birthCalendar, incoming.birthCalendar, localFirst);
    out.deathDate = ImportPlanner.pickText(local.deathDate, incoming.deathDate, localFirst);
    out.deathCalendar = ImportPlanner.pickText(local.deathCalendar, incoming.deathCalendar, localFirst);
    out.birthPlace = ImportPlanner.pickText(local.birthPlace, incoming.birthPlace, localFirst);
    out.residence = ImportPlanner.pickText(local.residence, incoming.residence, localFirst);
    out.rank = ImportPlanner.pickText(local.rank, incoming.rank, localFirst);
    out.adoption = ImportPlanner.pickText(local.adoption, incoming.adoption, localFirst);
    out.education = ImportPlanner.pickText(local.education, incoming.education, localFirst);
    out.occupation = ImportPlanner.pickText(local.occupation, incoming.occupation, localFirst);
    out.biography = ImportPlanner.pickText(local.biography, incoming.biography, localFirst);
    out.graveInfo = ImportPlanner.pickText(local.graveInfo, incoming.graveInfo, localFirst);
    out.graveLng = ImportPlanner.pickNumber(local.graveLng, incoming.graveLng, localFirst);
    out.graveLat = ImportPlanner.pickNumber(local.graveLat, incoming.graveLat, localFirst);
    out.graveAltitude = ImportPlanner.pickNumber(local.graveAltitude, incoming.graveAltitude, localFirst);
    out.phone = ImportPlanner.pickText(local.phone, incoming.phone, localFirst);
    out.wechat = ImportPlanner.pickText(local.wechat, incoming.wechat, localFirst);
    out.avatar = ImportPlanner.pickText(local.avatar, incoming.avatar, localFirst);
    out.videos = ImportPlanner.pickText(local.videos, incoming.videos, localFirst);
    out.photos = ImportPlanner.pickText(local.photos, incoming.photos, localFirst);
    // 关系字段：本地非空优先；两边都不同则保留本地并记提示
    out.fatherId = ImportPlanner.pickText(local.fatherId, incoming.fatherId, localFirst);
    out.motherId = ImportPlanner.pickText(local.motherId, incoming.motherId, localFirst);
    if (local.fatherId.trim().length > 0 && incoming.fatherId.trim().length > 0 &&
      ImportPlanner.up(local.fatherId) !== ImportPlanner.up(incoming.fatherId)) {
      warnings.push('「' + local.name + '」父亲不一致（本机 ' + local.fatherId + '，导入 ' +
        incoming.fatherId + '），已按本机保留');
    }
    if (local.motherId.trim().length > 0 && incoming.motherId.trim().length > 0 &&
      ImportPlanner.up(local.motherId) !== ImportPlanner.up(incoming.motherId)) {
      warnings.push('「' + local.name + '」母亲不一致（本机 ' + local.motherId + '，导入 ' +
        incoming.motherId + '），已按本机保留');
    }
    const keptSpouses: SpouseRelation[] = [];
    if (local.spouses.length > 0 && localFirst) {
      local.spouses.forEach((r: SpouseRelation): void => {
        keptSpouses.push(cloneSpouseRelation(r));
      });
    } else if (incoming.spouses.length > 0) {
      incoming.spouses.forEach((r: SpouseRelation): void => {
        const nr: SpouseRelation = new SpouseRelation();
        nr.uid = r.uid;
        nr.relation = r.relation;
        nr.level = r.level;
        nr.order = r.order;
        keptSpouses.push(nr);
      });
    } else {
      local.spouses.forEach((r: SpouseRelation): void => {
        keptSpouses.push(cloneSpouseRelation(r));
      });
    }
    out.spouses = keptSpouses;
    out.spouseId = out.spouses.length > 0 ? out.spouses[0].uid : '';
    return out;
  }

  private static pickText(a: string, b: string, localFirst: boolean): string {
    const av: string = a.trim().length > 0 ? a : '';
    const bv: string = b.trim().length > 0 ? b : '';
    if (localFirst) {
      return av.length > 0 ? av : bv;
    }
    return bv.length > 0 ? bv : av;
  }

  private static pickNumber(a: number, b: number, localFirst: boolean): number {
    if (localFirst) {
      return a !== 0 ? a : b;
    }
    return b !== 0 ? b : a;
  }

  private static up(uid: string): string {
    return uid.trim().toUpperCase();
  }
}
