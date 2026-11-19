import { PersonNode } from '../model/PersonNode';
import { EuCanvas, EuLayout, SuCanvas, SuLayout } from './TreeLayout';
import { TreeCuller } from './TreeCuller';
import { TreePerf } from '../util/TreePerf';

/**
 * 布局缓存：同一宗支 + 同一显示参数只计算一次。
 *
 * 用 Map 而不是单字段：欧式/苏式按宗支拆成多个 EuTree/SuTree 实例，
 * 每个实例有自己的 rootUid，单字段缓存会让第二支拿到第一支的坐标。
 *
 * [PERF] 单支布局包含数万到数十万个 Box/LineSeg 对象，缓存容量按内存预算收敛；
 * 超限时只淘汰最早插入的一项（LRU），不再整体清空——原先 clear() 会让
 * “刚算好的支”在切到第 N 支时全部失效，切回任何旧支都要重新全量布局。
 *
 * 数据身份（族谱ID#数据版本）由宿主通过 setScopeProvider 注入，
 * 使本类不依赖业务服务，可直接留在公共层。
 */
export class TreeLayoutCache {
  private static instance: TreeLayoutCache | null = null;
  private static readonly MAX_ENTRIES: number = 8;
  private euMap: Map<string, EuCanvas> = new Map<string, EuCanvas>();
  private suMap: Map<string, SuCanvas> = new Map<string, SuCanvas>();
  private revision: number = 0;
  /** 数据身份提供者：由业务层注入（族谱ID#数据版本） */
  private scopeProvider: (() => string) | null = null;
  /**
   * 上次使用缓存时的数据身份（族谱ID#数据版本）。
   * 不能只靠 invalidate()：删除族谱后画布组件可能已经销毁，@Watch 不会触发；
   * 重新导入的族谱又常沿用同一套 uid（备份/模板导入），只按 rootUid 命中就会
   * 把上一部族谱的布局当成新数据，表现为「删了谱欧式还显示旧谱」。
   */
  private scope: string = '';

  static getInstance(): TreeLayoutCache {
    if (TreeLayoutCache.instance === null) {
      TreeLayoutCache.instance = new TreeLayoutCache();
    }
    return TreeLayoutCache.instance;
  }

  /** 注入数据身份提供者；返回空串表示不区分身份 */
  setScopeProvider(provider: () => string): void {
    this.scopeProvider = provider;
  }

  /** 族人数据变化时调用，丢弃全部旧布局 */
  invalidate(): void {
    this.revision = this.revision + 1;
    this.euMap.clear();
    this.suMap.clear();
  }

  /**
   * 校验数据身份并返回缓存域。
   * 族谱切换、删除后重建、任何一次 reload 都会让版本号变化；身份一变就先清空，
   * 既避免命中旧谱布局，也及时释放旧布局占用的内存。
   */
  private ensureScope(): string {
    const next: string = this.scopeProvider === null ? '' : this.scopeProvider();
    if (next !== this.scope) {
      this.scope = next;
      this.revision = this.revision + 1;
      this.euMap.clear();
      this.suMap.clear();
    }
    return this.scope + '#' + this.revision.toString();
  }

  /** 淘汰最早插入的欧式布局（Map 保持插入顺序） */
  private evictOldestEu(): void {
    let oldest: string = '';
    this.euMap.forEach((_canvas: EuCanvas, key: string): void => {
      if (oldest.length === 0) {
        oldest = key;
      }
    });
    if (oldest.length > 0) {
      this.euMap.delete(oldest);
    }
  }

  /** 淘汰最早插入的苏式布局 */
  private evictOldestSu(): void {
    let oldest: string = '';
    this.suMap.forEach((_canvas: SuCanvas, key: string): void => {
      if (oldest.length === 0) {
        oldest = key;
      }
    });
    if (oldest.length > 0) {
      this.suMap.delete(oldest);
    }
  }

  eu(rootKey: string, roots: PersonNode[], cardWidth: number, rowHeight: number,
    showSpouse: boolean, startY: number): EuCanvas {
    const key: string = rootKey + '|' + this.ensureScope() + '|' +
      cardWidth.toString() + '|' + rowHeight.toString() + '|' +
      showSpouse.toString() + '|' + startY.toString();
    const hit: EuCanvas | undefined = this.euMap.get(key);
    if (hit !== undefined) {
      // 命中后移到队尾，保证常用宗支不会被新支挤出
      this.euMap.delete(key);
      this.euMap.set(key, hit);
      return hit;
    }
    TreePerf.begin('layout_eu');
    const canvas: EuCanvas = EuLayout.compute(roots, cardWidth, rowHeight, 30, showSpouse, startY);
    TreePerf.end('layout_eu', 'root=' + rootKey + ' boxes=' + canvas.boxes.length.toString());
    // 索引预热并入本次布局阻塞，避免组件首帧再出现一次 100ms 级排序长任务
    TreePerf.begin('index_eu');
    TreeCuller.warmupEu(canvas.boxes, canvas.lines);
    TreePerf.end('index_eu', 'root=' + rootKey);
    while (this.euMap.size >= TreeLayoutCache.MAX_ENTRIES) {
      this.evictOldestEu();
    }
    this.euMap.set(key, canvas);
    return canvas;
  }

  su(rootKey: string, roots: PersonNode[], cardWidth: number,
    dense: boolean, showSpouse: boolean): SuCanvas {
    const key: string = rootKey + '|' + this.ensureScope() + '|' +
      cardWidth.toString() + '|' + dense.toString() + '|' + showSpouse.toString();
    const hit: SuCanvas | undefined = this.suMap.get(key);
    if (hit !== undefined) {
      // 命中后移到队尾，保证常用宗支不会被新支挤出
      this.suMap.delete(key);
      this.suMap.set(key, hit);
      return hit;
    }
    TreePerf.begin('layout_su');
    const canvas: SuCanvas = SuLayout.compute(roots, cardWidth, dense, showSpouse);
    TreePerf.end('layout_su', 'root=' + rootKey + ' boxes=' + canvas.boxes.length.toString());
    // 索引预热并入本次布局阻塞，避免组件首帧再出现一次 100ms 级排序长任务
    TreePerf.begin('index_su');
    TreeCuller.warmupSu(canvas.boxes, canvas.lines);
    TreePerf.end('index_su', 'root=' + rootKey);
    while (this.suMap.size >= TreeLayoutCache.MAX_ENTRIES) {
      this.evictOldestSu();
    }
    this.suMap.set(key, canvas);
    return canvas;
  }
}
