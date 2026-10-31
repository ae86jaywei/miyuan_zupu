/**
 * 族谱数据一致性模型。
 *
 * 用于在「云端恢复 / 家族同步 / 导入合并」等跨版本合并场景中，
 * 判断人员ID与亲属关系是否自洽，避免同一编号对应不同族人导致
 * 世系图重复、重叠或多出宗支。
 */

/** 问题类型编码 */
export class IntegrityCode {
  /** 同一族谱内唯一ID重复 */
  static readonly UID_DUPLICATE: string = 'UID_DUPLICATE';
  /** 唯一ID为空或格式异常 */
  static readonly UID_INVALID: string = 'UID_INVALID';
  /** 父亲/母亲/配偶引用自己 */
  static readonly REF_SELF: string = 'REF_SELF';
  /** 父母ID在本谱中不存在（含被删除后留下的悬空引用） */
  static readonly PARENT_MISSING: string = 'PARENT_MISSING';
  /** 配偶ID在本谱中不存在 */
  static readonly SPOUSE_MISSING: string = 'SPOUSE_MISSING';
  /** 父母性别与关系字段不符 */
  static readonly PARENT_GENDER: string = 'PARENT_GENDER';
  /** 父母出生日期晚于子女（关系指向了错误的人） */
  static readonly PARENT_BIRTH: string = 'PARENT_BIRTH';
  /** 配偶性别异常或世代相差过大 */
  static readonly SPOUSE_RELATION: string = 'SPOUSE_RELATION';
  /** 世代与父母不连续 */
  static readonly GENERATION_GAP: string = 'GENERATION_GAP';
  /** 父母关系形成闭环 */
  static readonly CYCLE: string = 'CYCLE';
  /** 不同ID但疑似同一人重复录入 */
  static readonly SUSPECT_DUPLICATE: string = 'SUSPECT_DUPLICATE';
  /** 同一ID在不同数据源中代表不同人物 */
  static readonly IDENTITY_CONFLICT: string = 'IDENTITY_CONFLICT';
  /** 新增人员复用了已删除人员的编号 */
  static readonly UID_REUSED: string = 'UID_REUSED';
}

/** 单条一致性问题 */
export class IntegrityIssue {
  code: string = '';
  /** error：会破坏世系结构；warning：需要人工核对 */
  level: string = 'warning';
  uid: string = '';
  name: string = '';
  message: string = '';

  constructor(code: string, level: string, uid: string, name: string, message: string) {
    this.code = code;
    this.level = level;
    this.uid = uid;
    this.name = name;
    this.message = message;
  }
}

/** 一致性体检报告 */
export class IntegrityReport {
  issues: IntegrityIssue[] = [];
  errorCount: number = 0;
  warningCount: number = 0;
  /** 数据来源说明，如「本机」「云端备份」 */
  source: string = '';

  add(code: string, level: string, uid: string, name: string, message: string): void {
    this.issues.push(new IntegrityIssue(code, level, uid, name, message));
    if (level === 'error') {
      this.errorCount = this.errorCount + 1;
    } else {
      this.warningCount = this.warningCount + 1;
    }
  }

  /** 合并另一份报告 */
  merge(other: IntegrityReport): void {
    other.issues.forEach((issue: IntegrityIssue): void => {
      this.issues.push(issue);
    });
    this.errorCount = this.errorCount + other.errorCount;
    this.warningCount = this.warningCount + other.warningCount;
  }

  hasIssue(): boolean {
    return this.issues.length > 0;
  }

  hasError(): boolean {
    return this.errorCount > 0;
  }

  issueCount(): number {
    return this.issues.length;
  }

  /** 一句话结论 */
  summary(): string {
    if (this.issues.length === 0) {
      return '未发现ID与亲属关系异常';
    }
    let text: string = '发现 ';
    if (this.errorCount > 0) {
      text = text + this.errorCount.toString() + ' 项严重问题';
    }
    if (this.warningCount > 0) {
      if (this.errorCount > 0) {
        text = text + '、';
      }
      text = text + this.warningCount.toString() + ' 项待核对提示';
    }
    return text;
  }

  /** 生成弹窗用的明细文本（最多 max 条） */
  detail(max: number): string {
    if (this.issues.length === 0) {
      return '';
    }
    const lines: string[] = [];
    const limit: number = this.issues.length < max ? this.issues.length : max;
    for (let i: number = 0; i < limit; i++) {
      const issue: IntegrityIssue = this.issues[i];
      const who: string = issue.name.length > 0
        ? issue.name + '（' + issue.uid + '）'
        : (issue.uid.length > 0 ? issue.uid : '族谱');
      const tag: string = issue.level === 'error' ? '[严重] ' : '[提示] ';
      lines.push((i + 1).toString() + '. ' + tag + who + '：' + issue.message);
    }
    let text: string = lines.join('\n');
    if (this.issues.length > limit) {
      text = text + '\n……另有 ' + (this.issues.length - limit).toString() + ' 项未展示';
    }
    return text;
  }
}