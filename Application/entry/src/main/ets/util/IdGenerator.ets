import { Person } from '../model/Person';

/**
 * 唯一ID生成器。
 *
 * 规则（可人工修改）：
 *  - 性别前缀：**男 F / 女 M**，两类各自独立编号；
 *  - **优先复用最小空号**：删掉 F004 后再新增男丁，会优先拿到 F004；
 *  - 但调用方可通过 reserved 传入「已被删除、仍可能存在于云端的编号」，
 *    生成时会跳过这些历史编号，避免同一ID先后代表两个人；
 *  - 编号默认 3 位（F001）；**只有当编号本身超过 999 时才增位**（F1000）。
 *    注意宽度只看「本次要用的编号」，不看历史最大值——否则删到只剩 F1000 时，
 *    复用空号会生成 F0001，与既有 F001 风格不一致。
 */
export class IdGenerator {
  /**
   * 根据族谱中现有 ID 生成下一个可用 ID。
   * @param people 当前可见族人
   * @param gender 性别（男/女）
   * @param reserved 需要跳过的历史编号（如已删除人员的编号）
   */
  static next(people: Person[], gender: string, reserved?: Set<string>): string {
    const prefix: string = gender === '女' ? 'M' : 'F';
    const used: Set<number> = new Set<number>();
    people.forEach((p: Person): void => {
      IdGenerator.collect(p.uid, prefix, used);
    });
    if (reserved !== undefined) {
      reserved.forEach((uid: string): void => {
        IdGenerator.collect(uid, prefix, used);
      });
    }
    let num: number = 1;
    while (used.has(num)) {
      num = num + 1;
    }
    return IdGenerator.format(prefix, num);
  }

  /** 把一个编号折算为数字并登记；前缀不符或非法编号直接忽略 */
  private static collect(uid: string, prefix: string, used: Set<number>): void {
    const id: string = uid.trim().toUpperCase();
    const m: RegExpMatchArray | null = id.match(/^([FM])([0-9]+)$/);
    if (m === null || m[1] !== prefix) {
      return;
    }
    const num: number = parseInt(m[2], 10);
    if (isNaN(num) || num <= 0) {
      return;
    }
    used.add(num);
  }

  /** 编号位数：最少 3 位，超过 999 时按实际位数 */
  static widthOf(num: number): number {
    const len: number = num.toString().length;
    return len > 3 ? len : 3;
  }

  /** 左补零到指定宽度（宽度不足时不截断） */
  static format(prefix: string, num: number): string {
    const width: number = IdGenerator.widthOf(num);
    let s: string = num.toString();
    while (s.length < width) {
      s = '0' + s;
    }
    return prefix + s;
  }

  /** 校验 ID 唯一性；excludeUid 为编辑时排除自身 */
  static isUnique(people: Person[], uid: string, excludeUid: string): boolean {
    const target: string = uid.trim().toUpperCase();
    if (target.length === 0) {
      return false;
    }
    for (let i: number = 0; i < people.length; i++) {
      const p: Person = people[i];
      const id: string = p.uid.trim().toUpperCase();
      if (id === target && id !== excludeUid.trim().toUpperCase()) {
        return false;
      }
    }
    return true;
  }
}

/**
 * 批量编号分配器。
 *
 * `IdGenerator.next()` 每次调用都要把整谱 + 黑名单重扫一遍并逐条正则匹配，
 * 单人新增时无所谓；但导入 4 万人时会被调用数万次，退化成 O(n²)，
 * 主线程连续阻塞超过 6 秒就会被系统判定 THREAD_BLOCK_6S 并强杀进程。
 *
 * 这里改为：先把所有已占用编号一次性建索引，之后按前缀维护一个只前进的游标，
 * 单次分配摊销到 O(1)。语义与原 `next()` 一致：优先复用最小空号。
 */
export class UidAllocator {
  /** 前缀（F/M） → 已占用编号 */
  private used: Map<string, Set<number>> = new Map<string, Set<number>>();
  /** 前缀（F/M） → 下一个候选编号（只会前进，不回退） */
  private cursor: Map<string, number> = new Map<string, number>();

  /** 登记一个已占用编号：本机、已删除黑名单、悬空引用、本批已分配的都要登记 */
  reserve(uid: string): void {
    const id: string = uid.trim().toUpperCase();
    const m: RegExpMatchArray | null = id.match(/^([FM])([0-9]+)$/);
    if (m === null) {
      return;
    }
    const num: number = parseInt(m[2], 10);
    if (isNaN(num) || num <= 0) {
      return;
    }
    this.setOf(m[1]).add(num);
  }

  /** 占用并返回下一个可用编号（女 M / 其余 F，与 next 规则一致） */
  take(gender: string): string {
    const prefix: string = gender === '女' ? 'M' : 'F';
    const set: Set<number> = this.setOf(prefix);
    const start: number | undefined = this.cursor.get(prefix);
    let num: number = start === undefined ? 1 : start;
    while (set.has(num)) {
      num = num + 1;
    }
    set.add(num);
    this.cursor.set(prefix, num + 1);
    return IdGenerator.format(prefix, num);
  }

  /** 取指定前缀的已占用集合，不存在则初始化（游标同时置 1） */
  private setOf(prefix: string): Set<number> {
    const found: Set<number> | undefined = this.used.get(prefix);
    if (found !== undefined) {
      return found;
    }
    const created: Set<number> = new Set<number>();
    this.used.set(prefix, created);
    this.cursor.set(prefix, 1);
    return created;
  }
}
