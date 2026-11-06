import { PersonNode } from '../model/PersonNode';
import { EuCanvas, EuLayout, SuCanvas, SuLayout } from './TreeLayout';
import { TreePerf } from '../util/TreePerf';

/**
 * 布局缓存：同一宗支 + 同一显示参数只计算一次。
 *
 * 用 Map 而不是单字段：欧式/苏式按宗支拆成多个 EuTree/SuTree 实例，
 * 每个实例有自己的 rootUid，单字段缓存会让第二支拿到第一支的坐标。
 */
export class TreeLayoutCache {
  private static instance: TreeLayoutCache | null = null;
  private static readonly MAX_ENTRIES: number = 64;
  private euMap: Map<string, EuCanvas> = new Map<string, EuCanvas>();
  private suMap: Map<string, SuCanvas> = new Map<string, SuCanvas>();
  private revision: number = 0;

  static getInstance(): TreeLayoutCache {
    if (TreeLayoutCache.instance === null) {
      TreeLayoutCache.instance = new TreeLayoutCache();
    }
    return TreeLayoutCache.instance;
  }

  /** 族人数据变化时调用，丢弃全部旧布局 */
  invalidate(): void {
    this.revision = this.revision + 1;
    this.euMap.clear();
    this.suMap.clear();
  }

  eu(rootKey: string, roots: PersonNode[], cardWidth: number, rowHeight: number,
    showSpouse: boolean, startY: number): EuCanvas {
    const key: string = rootKey + '|' + this.revision.toString() + '|' +
      cardWidth.toString() + '|' + rowHeight.toString() + '|' +
      showSpouse.toString() + '|' + startY.toString();
    const hit: EuCanvas | undefined = this.euMap.get(key);
    if (hit !== undefined) {
      return hit;
    }
    TreePerf.begin('layout_eu');
    const canvas: EuCanvas = EuLayout.compute(roots, cardWidth, rowHeight, 30, showSpouse, startY);
    TreePerf.end('layout_eu', 'root=' + rootKey + ' boxes=' + canvas.boxes.length.toString());
    if (this.euMap.size >= TreeLayoutCache.MAX_ENTRIES) {
      this.euMap.clear();
    }
    this.euMap.set(key, canvas);
    return canvas;
  }

  su(rootKey: string, roots: PersonNode[], cardWidth: number,
    dense: boolean, showSpouse: boolean): SuCanvas {
    const key: string = rootKey + '|' + this.revision.toString() + '|' +
      cardWidth.toString() + '|' + dense.toString() + '|' + showSpouse.toString();
    const hit: SuCanvas | undefined = this.suMap.get(key);
    if (hit !== undefined) {
      return hit;
    }
    TreePerf.begin('layout_su');
    const canvas: SuCanvas = SuLayout.compute(roots, cardWidth, dense, showSpouse);
    TreePerf.end('layout_su', 'root=' + rootKey + ' boxes=' + canvas.boxes.length.toString());
    if (this.suMap.size >= TreeLayoutCache.MAX_ENTRIES) {
      this.suMap.clear();
    }
    this.suMap.set(key, canvas);
    return canvas;
  }
}
