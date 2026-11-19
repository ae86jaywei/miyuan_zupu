import { Person, PersonIndex } from 'common_base';

/**
 * 搜索与跳转索引域：模糊搜索、按 UID 查找与列表跳转索引。
 *
 * 从 `GenealogyService` 拆出；索引实例由服务持有并在数据重载后重建，
 * 这里只做访问门面，保证调用方不再直接操作索引细节。
 */
export class PersonSearch {
  private index: PersonIndex;
  private allPeople: () => Person[];

  constructor(index: PersonIndex, allPeople: () => Person[]) {
    this.index = index;
    this.allPeople = allPeople;
  }

  /** 模糊搜索：谱名 / 曾用名 / 唯一ID / 辈分字 / 出生地 / 职业（使用索引加速） */
  search(keyword: string): Person[] {
    const k: string = keyword.trim();
    if (k.length === 0) {
      return this.allPeople();
    }
    // 使用索引搜索，避免同步遍历全表
    return this.index.search(k);
  }

  /** 按 UID 快速查找（使用索引，O(1) 复杂度） */
  getByUid(uid: string): Person | null {
    return this.index.getByUid(uid);
  }

  /** 设置跳转索引（行号） */
  setJumpRow(uid: string, row: number): void {
    this.index.setRow(uid, row);
  }

  /** 获取跳转索引（行号） */
  getJumpRow(uid: string): number {
    return this.index.getRow(uid);
  }

  /** 设置牒记式页码 */
  setDiePage(uid: string, page: number): void {
    this.index.setDiePage(uid, page);
  }

  /** 获取牒记式页码 */
  getDiePage(uid: string): number {
    return this.index.getDiePage(uid);
  }

  /** 清空跳转索引（谱式切换时调用） */
  clearJumpIndex(): void {
    this.index.clearJumpIndex();
  }
}
