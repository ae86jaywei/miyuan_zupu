import { hilog } from '@kit.PerformanceAnalysisKit';

export class TreePerf {
  private static marks: Map<string, number> = new Map<string, number>();
  private static lastLogs: Map<string, number> = new Map<string, number>();
  private static lastWarnings: Map<string, number> = new Map<string, number>();
  private static calls: Map<string, number> = new Map<string, number>();
  private static totals: Map<string, number> = new Map<string, number>();
  private static maxCosts: Map<string, number> = new Map<string, number>();

  static begin(name: string): void {
    TreePerf.marks.set(name, Date.now());
  }

  static end(name: string, extra: string): void {
    const start: number | undefined = TreePerf.marks.get(name);
    if (start === undefined) {
      return;
    }
    TreePerf.marks.delete(name);
    const now: number = Date.now();
    const cost: number = now - start;
    const calls: number = (TreePerf.calls.get(name) ?? 0) + 1;
    const total: number = (TreePerf.totals.get(name) ?? 0) + cost;
    const maxCost: number = Math.max(TreePerf.maxCosts.get(name) ?? 0, cost);
    TreePerf.calls.set(name, calls);
    TreePerf.totals.set(name, total);
    TreePerf.maxCosts.set(name, maxCost);
    const lastWarning: number = TreePerf.lastWarnings.get(name) ?? 0;
    if (cost >= 1000 && now - lastWarning >= 1000) {
      hilog.warn(0x0000, 'TreePerf', 'main thread long task %{public}s cost=%{public}dms', name, cost);
      TreePerf.lastWarnings.set(name, now);
    }
    const lastLog: number = TreePerf.lastLogs.get(name) ?? 0;
    if (now - lastLog >= 1000) {
      const average: number = Math.round(total / calls);
      hilog.info(0x0000, 'TreePerf',
        '%{public}s max=%{public}dms avg=%{public}dms calls=%{public}d %{public}s',
        name, maxCost, average, calls, extra);
      TreePerf.lastLogs.set(name, now);
      TreePerf.calls.delete(name);
      TreePerf.totals.delete(name);
      TreePerf.maxCosts.delete(name);
    }
  }

  static shouldDegrade(visibleCards: number): boolean {
    return visibleCards > 250;
  }

  static listCacheCount(totalCount: number): number {
    return totalCount > 10000 ? 2 : 6;
  }
}
