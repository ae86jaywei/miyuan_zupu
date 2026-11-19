/**
 * 人员索引：加速搜索和跳转
 *
 * 用途：
 * 1. 加速搜索：建立 uid -> Person 映射，避免同步遍历全表
 * 2. 加速跳转：建立 uid -> 行索引/页码映射，避免线性搜索
 *
 * 使用方式：
 * 1. 在 GenealogyService 初始化时调用 build()
 * 2. 人员变更时调用 update() / remove()
 * 3. 搜索时调用 search() 替代同步遍历
 * 4. 跳转时调用 getRow() / getPage() 快速定位
 */

import { Person } from './Person';

export class PersonIndex {
  // uid -> Person 映射（大写 UID 作为 key）
  private uidMap: Map<string, Person> = new Map();
  
  // 姓名首字母 -> Person[] 映射（用于快速按首字母搜索）
  private nameFirstCharMap: Map<string, Person[]> = new Map();
  
  // 跳转索引：uid -> 行索引（宝塔式/现代式）
  private uidToRow: Map<string, number> = new Map();
  
  // 跳转索引：uid -> 页码（牒记式）
  private uidToDiePage: Map<string, number> = new Map();
  
  // 索引是否已构建
  private built: boolean = false;
  
  // 人员总数
  private count: number = 0;
  
  /**
   * 构建索引
   * @param people 人员列表
   */
  build(people: Person[]): void {
    this.uidMap.clear();
    this.nameFirstCharMap.clear();
    this.uidToRow.clear();
    this.uidToDiePage.clear();
    
    this.count = people.length;
    
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      this.indexPerson(p);
    }
    
    this.built = true;
  }
  
  /**
   * 索引单个人员
   */
  private indexPerson(p: Person): void {
    if (p === null || p === undefined || p.uid.length === 0) {
      return;
    }
    
    // uid 索引（大写，便于不区分大小写查找）
    const uidKey: string = p.uid.trim().toUpperCase();
    this.uidMap.set(uidKey, p);
    
    // 姓名首字母索引
    if (p.name.length > 0) {
      const firstChar: string = p.name.charAt(0).toUpperCase();
      if (!this.nameFirstCharMap.has(firstChar)) {
        this.nameFirstCharMap.set(firstChar, []);
      }
      this.nameFirstCharMap.get(firstChar)!.push(p);
    }
  }
  
  /**
   * 添加人员到索引
   */
  add(p: Person): void {
    this.indexPerson(p);
    this.count = this.uidMap.size;
  }
  
  /**
   * 从索引中移除人员
   */
  remove(uid: string): void {
    const key: string = uid.trim().toUpperCase();
    const p: Person | undefined = this.uidMap.get(key);
    if (p !== undefined) {
      this.uidMap.delete(key);
      
      // 从首字母索引中移除
      if (p.name.length > 0) {
        const firstChar: string = p.name.charAt(0).toUpperCase();
        const list: Person[] | undefined = this.nameFirstCharMap.get(firstChar);
        if (list !== undefined) {
          const idx: number = list.findIndex((item: Person): boolean => item.uid === p.uid);
          if (idx >= 0) {
            list.splice(idx, 1);
          }
        }
      }
    }
    this.count = this.uidMap.size;
  }
  
  /**
   * 更新人员索引（先删后加）
   */
  update(p: Person): void {
    this.remove(p.uid);
    this.add(p);
  }
  
  /**
   * 按 UID 快速查找
   * @param uid 人员唯一ID
   * @returns 人员对象，未找到返回 null
   */
  getByUid(uid: string): Person | null {
    if (!this.built) {
      return null;
    }
    const key: string = uid.trim().toUpperCase();
    return this.uidMap.get(key) ?? null;
  }
  
  /**
   * 模糊搜索
   * @param keyword 关键词（姓名、曾用名、UID、辈分字等）
   * @returns 匹配的人员列表，最多 40 条
   */
  search(keyword: string): Person[] {
    if (!this.built) {
      return [];
    }
    
    const k: string = keyword.trim();
    if (k.length === 0) {
      return [];
    }
    
    const keyLower: string = k.toLowerCase();
    const keyUpper: string = k.toUpperCase();
    const out: Person[] = [];
    
    // 单字符搜索：优先按首字母查找
    if (k.length === 1) {
      const hits: Person[] | undefined = this.nameFirstCharMap.get(keyUpper);
      if (hits !== undefined && hits.length > 0) {
        return hits.slice(0, 40);
      }
    }
    
    // 遍历所有人员（使用 for...of 比 filter 更高效）
    for (const p of this.uidMap.values()) {
      if (this.matchPerson(p, keyLower, keyUpper)) {
        out.push(p);
        if (out.length >= 40) {
          break;
        }
      }
    }
    
    return out;
  }
  
  /**
   * 判断人员是否匹配关键词
   */
  private matchPerson(p: Person, keyLower: string, keyUpper: string): boolean {
    // 谱名
    if (p.name.toLowerCase().includes(keyLower)) {
      return true;
    }
    // 曾用名/小名
    if (p.alias.length > 0 && p.alias.toLowerCase().includes(keyLower)) {
      return true;
    }
    // 唯一ID
    if (p.uid.toUpperCase().includes(keyUpper)) {
      return true;
    }
    // 辈分/字派
    if (p.generationChar.toLowerCase().includes(keyLower)) {
      return true;
    }
    // 字
    if (p.courtesyName.length > 0 && p.courtesyName.toLowerCase().includes(keyLower)) {
      return true;
    }
    // 号
    if (p.artName.length > 0 && p.artName.toLowerCase().includes(keyLower)) {
      return true;
    }
    // 出生地
    if (p.birthPlace.length > 0 && p.birthPlace.toLowerCase().includes(keyLower)) {
      return true;
    }
    // 现居地
    if (p.residence.length > 0 && p.residence.toLowerCase().includes(keyLower)) {
      return true;
    }
    // 职业
    if (p.occupation.length > 0 && p.occupation.toLowerCase().includes(keyLower)) {
      return true;
    }
    
    return false;
  }
  
  /**
   * 设置跳转索引（行号）
   * @param uid 人员唯一ID
   * @param row 行索引
   */
  setRow(uid: string, row: number): void {
    const key: string = uid.trim().toUpperCase();
    this.uidToRow.set(key, row);
  }
  
  /**
   * 获取跳转索引（行号）
   * @param uid 人员唯一ID
   * @returns 行索引，未找到返回 -1
   */
  getRow(uid: string): number {
    const key: string = uid.trim().toUpperCase();
    return this.uidToRow.get(key) ?? -1;
  }
  
  /**
   * 设置牒记式页码
   * @param uid 人员唯一ID
   * @param page 页码（0-based）
   */
  setDiePage(uid: string, page: number): void {
    const key: string = uid.trim().toUpperCase();
    this.uidToDiePage.set(key, page);
  }
  
  /**
   * 获取牒记式页码
   * @param uid 人员唯一ID
   * @returns 页码，未找到返回 -1
   */
  getDiePage(uid: string): number {
    const key: string = uid.trim().toUpperCase();
    return this.uidToDiePage.get(key) ?? -1;
  }
  
  /**
   * 清空跳转索引（谱式切换时调用）
   */
  clearJumpIndex(): void {
    this.uidToRow.clear();
    this.uidToDiePage.clear();
  }
  
  /**
   * 获取人员总数
   */
  size(): number {
    return this.count;
  }
  
  /**
   * 检查索引是否已构建
   */
  isBuilt(): boolean {
    return this.built;
  }
  
  /**
   * 重置索引
   */
  reset(): void {
    this.uidMap.clear();
    this.nameFirstCharMap.clear();
    this.uidToRow.clear();
    this.uidToDiePage.clear();
    this.built = false;
    this.count = 0;
  }
}

// 导出单例（可选，便于全局访问）
// export const personIndex: PersonIndex = new PersonIndex();
