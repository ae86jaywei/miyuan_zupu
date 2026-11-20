export class TreePerf {
  private static marks: Map<string, number> = new Map<string, number>();

  static begin(name: string): void {
    TreePerf.marks.set(name, Date.now());
  }

  static end(name: string, extra: string): void {
    TreePerf.marks.delete(name);
  }

  static shouldDegrade(visibleCards: number): boolean {
    return visibleCards > 250;
  }

  static listCacheCount(totalCount: number): number {
    return totalCount > 10000 ? 2 : 6;
  }
}