import { Person } from '../model/Person';
import { IntegrityCode, IntegrityIssue, IntegrityReport } from '../model/Integrity';
import { parseDate } from '../util/DateUtil';

/**
 * 族谱数据一致性检测。
 *
 * 背景：唯一ID生成规则调整为「复用最小空号」后，删除人员再加人会重新用到
 * 被删除人员的编号；而云端与本地可能是不同时间点的数据版本。直接合并会让
 * 旧的父子/配偶关系挂到新族人身上，世系图出现重复、重叠或多出宗支。
 *
 * 本服务只做「判断」，不改数据：
 *  - check：单份数据内部自洽性（重复ID、悬空关系、成环、疑似重复…）；
 *  - compare：两份数据（本机 vs 云端）中同一ID是否代表同一人；
 *  - reused：新增人员是否沿用了已删除人员的编号；
 *  - incoming：导入合并前的综合体检。
 */
export class IntegrityService {

  /** 体检单份人物列表 */
  static check(people: Person[], source: string = ''): IntegrityReport {
    const report: IntegrityReport = new IntegrityReport();
    report.source = source;
    const map: Map<string, Person> = new Map<string, Person>();

    // 1. 唯一ID：空值 / 格式 / 重复
    for (let i: number = 0; i < people.length; i++) {
      const p: Person = people[i];
      const uid: string = p.uid.trim().toUpperCase();
      if (uid.length === 0) {
        report.add(IntegrityCode.UID_INVALID, 'error', '', p.name, '唯一ID为空，无法建立亲属关系');
        continue;
      }
      if (!IntegrityService.isStandardUid(uid)) {
        report.add(IntegrityCode.UID_INVALID, 'warning', uid, p.name,
          '唯一ID“' + uid + '”不符合 F001 / M001 编号规则');
      }
      const first: Person | undefined = map.get(uid);
      if (first !== undefined) {
        report.add(IntegrityCode.UID_DUPLICATE, 'error', uid, p.name,
          '同一编号被“' + first.name + '”与“' + p.name + '”同时使用，合并后会出现人物重叠');
        continue;
      }
      map.set(uid, p);
    }

    // 2. 亲属引用与世代
    for (let i: number = 0; i < people.length; i++) {
      IntegrityService.checkReferences(people[i], map, report);
    }

    // 3. 父母链闭环
    IntegrityService.checkCycles(people, map, report);

    // 4. 不同ID但疑似同一人（同名、同性别、同生日、同父）
    IntegrityService.checkSuspectDuplicate(people, report);

    return report;
  }

  /** 校验单人的父母/配偶引用 */
  private static checkReferences(p: Person, map: Map<string, Person>, report: IntegrityReport): void {
    const uid: string = p.uid.trim().toUpperCase();
    const fId: string = p.fatherId.trim().toUpperCase();
    const mId: string = p.motherId.trim().toUpperCase();

    if (fId.length > 0) {
      if (fId === uid) {
        report.add(IntegrityCode.REF_SELF, 'error', uid, p.name, '父亲ID不能是本人');
      } else {
        const f: Person | undefined = map.get(fId);
        if (f === undefined) {
          report.add(IntegrityCode.PARENT_MISSING, 'error', uid, p.name,
            '父亲ID“' + fId + '”在本谱中不存在（可能指向了已删除族人）');
        } else {
          if (f.gender === '女') {
            report.add(IntegrityCode.PARENT_GENDER, 'warning', uid, p.name,
              '父亲“' + f.name + '”登记为女性，请核对关系');
          }
          if (f.generation > 0 && p.generation > 0 && f.generation + 1 !== p.generation) {
            report.add(IntegrityCode.GENERATION_GAP, 'warning', uid, p.name,
              '世代与父亲不连续（父第' + f.generation.toString() + '世，本第' +
                p.generation.toString() + '世）');
          }
          if (IntegrityService.bornNotBefore(f, p)) {
            report.add(IntegrityCode.PARENT_BIRTH, 'error', uid, p.name,
              '父亲“' + f.name + '”的出生日期不早于本人，关系ID可能指向了错误的人');
          }
        }
      }
    }

    if (mId.length > 0) {
      if (mId === uid) {
        report.add(IntegrityCode.REF_SELF, 'error', uid, p.name, '母亲ID不能是本人');
      } else {
        const m: Person | undefined = map.get(mId);
        if (m === undefined) {
          report.add(IntegrityCode.PARENT_MISSING, 'error', uid, p.name,
            '母亲ID“' + mId + '”在本谱中不存在（可能指向了已删除族人）');
        } else {
          if (m.gender === '男') {
            report.add(IntegrityCode.PARENT_GENDER, 'warning', uid, p.name,
              '母亲“' + m.name + '”登记为男性，请核对关系');
          }
          if (m.generation > 0 && p.generation > 0 && m.generation + 1 !== p.generation) {
            report.add(IntegrityCode.GENERATION_GAP, 'warning', uid, p.name,
              '世代与母亲不连续（母第' + m.generation.toString() + '世，本第' +
                p.generation.toString() + '世）');
          }
          if (IntegrityService.bornNotBefore(m, p)) {
            report.add(IntegrityCode.PARENT_BIRTH, 'error', uid, p.name,
              '母亲“' + m.name + '”的出生日期不早于本人，关系ID可能指向了错误的人');
          } else if (IntegrityService.tooYoungParent(m, p)) {
            report.add(IntegrityCode.PARENT_BIRTH, 'warning', uid, p.name,
              '母亲“' + m.name + '”与本人出生间隔不足 12 年，请核对关系ID');
          }
        }
      }
    }

    const spouseSeen: Set<string> = new Set<string>();
    for (let i: number = 0; i < p.spouses.length; i++) {
      const sId: string = p.spouses[i].uid.trim().toUpperCase();
      if (sId.length === 0 || spouseSeen.has(sId)) {
        continue;
      }
      spouseSeen.add(sId);
      if (sId === uid) {
        report.add(IntegrityCode.REF_SELF, 'error', uid, p.name, '配偶不能是本人');
        continue;
      }
      if (sId === fId || sId === mId) {
        report.add(IntegrityCode.SPOUSE_RELATION, 'error', uid, p.name,
          '同一人“' + sId + '”同时被登记为配偶和父母，关系ID明显错位');
      }
      const sp: Person | undefined = map.get(sId);
      if (sp === undefined) {
        report.add(IntegrityCode.SPOUSE_MISSING, 'warning', uid, p.name,
          '配偶ID“' + sId + '”在本谱中不存在（可能指向了已删除族人）');
      } else {
        if (sp.gender.length > 0 && sp.gender === p.gender) {
          report.add(IntegrityCode.SPOUSE_RELATION, 'warning', uid, p.name,
            '配偶“' + sp.name + '”与本人性别相同，请核对关系ID');
        }
        if (sp.generation > 0 && p.generation > 0 && Math.abs(sp.generation - p.generation) >= 2) {
          report.add(IntegrityCode.SPOUSE_RELATION, 'warning', uid, p.name,
            '配偶“' + sp.name + '”与本人相隔 ' + Math.abs(sp.generation - p.generation).toString() +
              ' 代，请核对关系ID是否错位');
        }
      }
    }
    const legacySpouse: string = p.spouseId.trim().toUpperCase();
    if (legacySpouse.length > 0 && !spouseSeen.has(legacySpouse)) {
      if (legacySpouse === uid) {
        report.add(IntegrityCode.REF_SELF, 'error', uid, p.name, '配偶不能是本人');
      } else if (map.get(legacySpouse) === undefined) {
        report.add(IntegrityCode.SPOUSE_MISSING, 'warning', uid, p.name,
          '配偶ID“' + legacySpouse + '”在本谱中不存在（可能指向了已删除族人）');
      }
    }
  }

  /** 沿父亲链检测闭环，每个节点只报一次（线性复杂度） */
  private static checkCycles(people: Person[], map: Map<string, Person>, report: IntegrityReport): void {
    const reported: Set<string> = new Set<string>();
    // 1 = 当前路径中，2 = 已确认不在环中
    const state: Map<string, number> = new Map<string, number>();
    for (let i: number = 0; i < people.length; i++) {
      const start: string = people[i].uid.trim().toUpperCase();
      if (start.length === 0 || state.get(start) === 2) {
        continue;
      }
      const path: string[] = [];
      let cur: string = start;
      let cycleStart: number = -1;
      let guard: number = 0;
      while (cur.length > 0 && guard <= people.length) {
        if (state.get(cur) === 1) {
          for (let j: number = 0; j < path.length; j++) {
            if (path[j] === cur) {
              cycleStart = j;
              break;
            }
          }
          break;
        }
        if (state.get(cur) === 2) {
          break;
        }
        state.set(cur, 1);
        path.push(cur);
        const node: Person | undefined = map.get(cur);
        if (node === undefined) {
          break;
        }
        cur = node.fatherId.trim().toUpperCase();
        guard = guard + 1;
      }
      if (cycleStart >= 0) {
        for (let j: number = cycleStart; j < path.length; j++) {
          const uid: string = path[j];
          if (reported.has(uid)) {
            continue;
          }
          reported.add(uid);
          const node: Person | undefined = map.get(uid);
          report.add(IntegrityCode.CYCLE, 'error', uid, node === undefined ? '' : node.name,
            '父母关系形成闭环，世系树会重复展开，请断开其中一环');
        }
      }
      for (let j: number = 0; j < path.length; j++) {
        state.set(path[j], 2);
      }
    }
  }

  /** 同名、同性别、同生日、同父：疑似同一人被录入了两个编号 */
  private static checkSuspectDuplicate(people: Person[], report: IntegrityReport): void {
    const seen: Map<string, Person> = new Map<string, Person>();
    for (let i: number = 0; i < people.length; i++) {
      const p: Person = people[i];
      const name: string = p.name.trim();
      const birth: string = p.birthDate.trim();
      if (name.length === 0 || birth.length === 0) {
        continue;
      }
      const key: string = name + '|' + p.gender + '|' + birth + '|' + p.fatherId.trim().toUpperCase();
      const first: Person | undefined = seen.get(key);
      if (first === undefined) {
        seen.set(key, p);
        continue;
      }
      report.add(IntegrityCode.SUSPECT_DUPLICATE, 'warning', p.uid, p.name,
        '与“' + first.name + '（' + first.uid + '）”同名、同生日且同父，疑似重复录入，会多出一宗支');
    }
  }

  /**
   * 跨版本比对：同一编号在 primary 与 incoming 中是否代表同一个人。
   * 用于本机数据与云端备份 / 导入文件之间的合并前判断。
   */
  static compare(primary: Person[], incoming: Person[], primaryLabel: string,
    incomingLabel: string): IntegrityReport {
    const report: IntegrityReport = new IntegrityReport();
    report.source = primaryLabel + ' / ' + incomingLabel;
    const map: Map<string, Person> = new Map<string, Person>();
    for (let i: number = 0; i < primary.length; i++) {
      const uid: string = primary[i].uid.trim().toUpperCase();
      if (uid.length > 0 && map.get(uid) === undefined) {
        map.set(uid, primary[i]);
      }
    }
    const reported: Set<string> = new Set<string>();
    for (let i: number = 0; i < incoming.length; i++) {
      const remote: Person = incoming[i];
      const uid: string = remote.uid.trim().toUpperCase();
      if (uid.length === 0 || reported.has(uid)) {
        continue;
      }
      const local: Person | undefined = map.get(uid);
      if (local === undefined) {
        continue;
      }
      reported.add(uid);
      IntegrityService.checkIdentity(uid, local, remote, primaryLabel, incomingLabel, report);
    }
    return report;
  }

/** 单个同编号人物的身份比对 */
  private static checkIdentity(uid: string, local: Person, remote: Person, primaryLabel: string,
    incomingLabel: string, report: IntegrityReport): void {
    const localName: string = local.name.trim();
    const remoteName: string = remote.name.trim();
    const localBirth: string = local.birthDate.trim();
    const remoteBirth: string = remote.birthDate.trim();
    const localFather: string = local.fatherId.trim().toUpperCase();
    const remoteFather: string = remote.fatherId.trim().toUpperCase();
    const nameDiff: boolean = localName.length > 0 && remoteName.length > 0 && localName !== remoteName;
    const genderDiff: boolean = local.gender.length > 0 && remote.gender.length > 0 &&
      local.gender !== remote.gender;
    const genDiff: boolean = local.generation > 0 && remote.generation > 0 &&
      local.generation !== remote.generation;
    const birthDiff: boolean = localBirth.length > 0 && remoteBirth.length > 0 && localBirth !== remoteBirth;
    const fatherDiff: boolean = localFather.length > 0 && remoteFather.length > 0 && localFather !== remoteFather;
    let diffCount: number = 0;
    if (nameDiff) {
      diffCount = diffCount + 1;
    }
    if (genderDiff) {
      diffCount = diffCount + 1;
    }
    if (genDiff) {
      diffCount = diffCount + 1;
    }
    if (birthDiff) {
      diffCount = diffCount + 1;
    }
    if (fatherDiff) {
      diffCount = diffCount + 1;
    }

    // 姓名 + 至少一项身份字段同时不一致：基本可判定编号已对应到另一个人
    if (nameDiff && diffCount >= 2) {
      report.add(IntegrityCode.IDENTITY_CONFLICT, 'error', uid, remoteName,
        '编号相同但人物不同（' + primaryLabel + '：' + localName + '；' +
          incomingLabel + '：' + remoteName + '，另有 ' + (diffCount - 1).toString() +
          ' 项身份信息不一致），合并会把旧亲属关系挂到新族人身上');
      return;
    }
    if (nameDiff) {
      report.add(IntegrityCode.IDENTITY_CONFLICT, 'warning', uid, remoteName,
        '编号相同的姓名不一致（' + primaryLabel + '：' + localName + '；' +
          incomingLabel + '：' + remoteName + '），可能是改名，也可能是编号被复用');
    }
    if (genderDiff) {
      report.add(IntegrityCode.IDENTITY_CONFLICT, 'warning', uid, remoteName,
        '编号相同的族人性别不一致（' + primaryLabel + '：' + local.gender + '；' +
          incomingLabel + '：' + remote.gender + '），请核对是否同一人');
    }
    if (genDiff) {
      report.add(IntegrityCode.IDENTITY_CONFLICT, 'warning', uid, remoteName,
        '编号相同的世代不一致（' + primaryLabel + '：第' + local.generation.toString() + '世；' +
          incomingLabel + '：第' + remote.generation.toString() + '世）');
    }
    if (birthDiff) {
      report.add(IntegrityCode.IDENTITY_CONFLICT, 'warning', uid, remoteName,
        '编号相同的出生日期不一致（' + primaryLabel + '：' + localBirth + '；' +
          incomingLabel + '：' + remoteBirth + '）');
    }
    if (fatherDiff) {
      report.add(IntegrityCode.IDENTITY_CONFLICT, 'warning', uid, remoteName,
        '编号相同的父亲不一致（' + primaryLabel + '：' + localFather + '；' +
          incomingLabel + '：' + remoteFather + '）');
    }
  }

  /** 新增人员是否复用了已删除人员的编号 */
  static reused(people: Person[], retired: Map<string, string>): IntegrityReport {
    const report: IntegrityReport = new IntegrityReport();
    report.source = 'ID 使用历史';
    if (retired.size === 0) {
      return report;
    }
    const reported: Set<string> = new Set<string>();
    for (let i: number = 0; i < people.length; i++) {
      const uid: string = people[i].uid.trim().toUpperCase();
      if (uid.length === 0 || reported.has(uid)) {
        continue;
      }
      const retiredName: string | undefined = retired.get(uid);
      if (retiredName === undefined) {
        continue;
      }
      // 同名视为「删除后又从云端恢复同一个人」，只有异名才判定为编号被复用
      const currentName: string = people[i].name.trim();
      if (currentName.length > 0 && currentName === retiredName) {
        continue;
      }
      reported.add(uid);
      report.add(IntegrityCode.UID_REUSED, 'error', uid, people[i].name,
        '该编号曾用于已删除族人“' + retiredName + '”，现被“' + people[i].name +
          '”沿用；云端若仍有旧关系记录，合并后会挂到新族人身上');
    }
    return report;
  }

  /**
   * 检测「仍引用已删除编号」的亲属关系。
   * 删除张三（F004）后新增李四复用 F004 时，原先指向张三的父子/配偶关系
   * 会悄悄改指向李四；这里把这类关系逐条找出来提示核对。
   */
  static reusedReferences(people: Person[], retired: Map<string, string>): IntegrityReport {
    const report: IntegrityReport = new IntegrityReport();
    report.source = '亲属关系引用';
    if (retired.size === 0) {
      return report;
    }
    const map: Map<string, Person> = new Map<string, Person>();
    for (let i: number = 0; i < people.length; i++) {
      const uid: string = people[i].uid.trim().toUpperCase();
      if (uid.length > 0 && map.get(uid) === undefined) {
        map.set(uid, people[i]);
      }
    }
    const reported: Set<string> = new Set<string>();
    for (let i: number = 0; i < people.length; i++) {
      const owner: Person = people[i];
      const ownerUid: string = owner.uid.trim().toUpperCase();
      if (ownerUid.length === 0) {
        continue;
      }
      const refs: string[] = [];
      refs.push(owner.fatherId);
      refs.push(owner.motherId);
      refs.push(owner.spouseId);
      for (let s: number = 0; s < owner.spouses.length; s++) {
        refs.push(owner.spouses[s].uid);
      }
      for (let r: number = 0; r < refs.length; r++) {
        const ref: string = refs[r].trim().toUpperCase();
        if (ref.length === 0 || ref === ownerUid) {
          continue;
        }
        const oldName: string | undefined = retired.get(ref);
        if (oldName === undefined) {
          continue;
        }
        // 该编号当前不存在（悬空）时由 PARENT_MISSING / SPOUSE_MISSING 处理
        const target: Person | undefined = map.get(ref);
        if (target === undefined) {
          continue;
        }
        // 同名人从云端恢复，不算编号复用
        if (target.name.trim().length > 0 && target.name.trim() === oldName) {
          continue;
        }
        const key: string = ownerUid + '|' + ref;
        if (reported.has(key)) {
          continue;
        }
        reported.add(key);
        let label: string = '亲属';
        if (ref === owner.fatherId.trim().toUpperCase()) {
          label = '父亲';
        } else if (ref === owner.motherId.trim().toUpperCase()) {
          label = '母亲';
        } else {
          label = '配偶';
        }
        report.add(IntegrityCode.UID_REUSED, 'error', ref, target.name,
          owner.name + '（' + ownerUid + '）的' + label + 'ID“' + ref + '”曾属于已删除的“' +
            oldName + '”，现由“' + target.name + '”使用，这条亲属关系可能已指向错误的人');
      }
    }
    return report;
  }

  /** 导入合并前的综合体检：导入文件内部 + 与本机同编号身份 + 已删除编号复用 */
  static incoming(incoming: Person[], existing: Person[], retired: Map<string, string>): IntegrityReport {
    // 引用检查要把本机已有族人一起考虑：导入分支的父母可能本来就在本机
    const importedUids: Set<string> = new Set<string>();
    for (let i: number = 0; i < incoming.length; i++) {
      const uid: string = incoming[i].uid.trim().toUpperCase();
      if (uid.length > 0) {
        importedUids.add(uid);
      }
    }
    const merged: Person[] = [];
    for (let i: number = 0; i < incoming.length; i++) {
      merged.push(incoming[i]);
    }
    for (let i: number = 0; i < existing.length; i++) {
      const uid: string = existing[i].uid.trim().toUpperCase();
      if (uid.length > 0 && !importedUids.has(uid)) {
        merged.push(existing[i]);
      }
    }
    const full: IntegrityReport = IntegrityService.check(merged, '导入数据');
    // 只保留与导入记录相关的问题，本机自身的历史问题不在导入弹窗里重复展示
    const report: IntegrityReport = new IntegrityReport();
    report.source = full.source;
    for (let i: number = 0; i < full.issues.length; i++) {
      const issue: IntegrityIssue = full.issues[i];
      if (importedUids.has(issue.uid)) {
        report.add(issue.code, issue.level, issue.uid, issue.name, issue.message);
      }
    }
    report.merge(IntegrityService.compare(existing, incoming, '本机', '导入数据'));
    report.merge(IntegrityService.reused(incoming, retired));
    report.merge(IntegrityService.reusedReferences(merged, retired));
    return report;
  }

  /** 父母出生日期不早于子女（含同日），视为关系指向错误 */
  private static bornNotBefore(parent: Person, child: Person): boolean {
    const pb: number = parseDate(parent.birthDate);
    const cb: number = parseDate(child.birthDate);
    // 1970 年前的日期会解析为负时间戳，不能用 > 0 判断有效性
    return pb !== 0 && cb !== 0 && pb >= cb;
  }

  /** 母亲与子女出生间隔不足 12 年 */
  private static tooYoungParent(parent: Person, child: Person): boolean {
    const pb: number = parseDate(parent.birthDate);
    const cb: number = parseDate(child.birthDate);
    if (pb === 0 || cb === 0 || cb <= pb) {
      return false;
    }
    const yearMs: number = 365.25 * 24 * 60 * 60 * 1000;
    return (cb - pb) / yearMs < 12;
  }

  /** 判断唯一ID是否符合 F001 / M001 规则 */
  static isStandardUid(uid: string): boolean {
    return /^[FM][0-9]{1,}$/.test(uid) && (uid.charAt(0) === 'F' || uid.charAt(0) === 'M');
  }
}
