import { EuBox, LineSeg, SuBox } from './TreeLayout';
import { ViewRect } from './TreeViewport';

const LINE_PAD = 2;

interface EuBoxIndex { sorted: EuBox[]; maxH: number }
interface SuBoxIndex { sorted: SuBox[]; maxH: number }
interface LineIndex { sorted: LineSeg[]; maxH: number }

/**
 * 视口裁剪索引（按 y 预排序）。
 *
 * [PERF] 原实现对 boxes / lines 做全量线性扫描，视口每次变化（拖拽、缩放）
 * 都是 O(N)。大树（数万节点）下每帧成本随规模线性增长。
 * 这里以数组对象为弱引用键缓存「按 y 排序的副本 + 最大高度」，
 * 查询时先二分定位 y 下界，再只扫描纵向候选区间，复杂度降为 O(log N + K)。
 * 数组是布局缓存中的稳定对象，索引只在首次裁剪时构建一次。
 */
const euBoxCache: WeakMap<EuBox[], EuBoxIndex> = new WeakMap<EuBox[], EuBoxIndex>();
const suBoxCache: WeakMap<SuBox[], SuBoxIndex> = new WeakMap<SuBox[], SuBoxIndex>();
const lineCache: WeakMap<LineSeg[], LineIndex> = new WeakMap<LineSeg[], LineIndex>();

function euIndexOf(boxes: EuBox[]): EuBoxIndex {
  const hit: EuBoxIndex | undefined = euBoxCache.get(boxes);
  if (hit !== undefined) {
    return hit;
  }
  let maxH: number = 0;
  for (let i = 0; i < boxes.length; i++) {
    if (boxes[i].h > maxH) {
      maxH = boxes[i].h;
    }
  }
  const sorted: EuBox[] = boxes.slice().sort((a: EuBox, b: EuBox): number => a.y - b.y);
  const idx: EuBoxIndex = { sorted: sorted, maxH: maxH };
  euBoxCache.set(boxes, idx);
  return idx;
}

function suIndexOf(boxes: SuBox[]): SuBoxIndex {
  const hit: SuBoxIndex | undefined = suBoxCache.get(boxes);
  if (hit !== undefined) {
    return hit;
  }
  let maxH: number = 0;
  for (let i = 0; i < boxes.length; i++) {
    if (boxes[i].h > maxH) {
      maxH = boxes[i].h;
    }
  }
  const sorted: SuBox[] = boxes.slice().sort((a: SuBox, b: SuBox): number => a.y - b.y);
  const idx: SuBoxIndex = { sorted: sorted, maxH: maxH };
  suBoxCache.set(boxes, idx);
  return idx;
}

function lineIndexOf(lines: LineSeg[]): LineIndex {
  const hit: LineIndex | undefined = lineCache.get(lines);
  if (hit !== undefined) {
    return hit;
  }
  let maxH: number = 0;
  for (let i = 0; i < lines.length; i++) {
    const h: number = Math.abs(lines[i].y2 - lines[i].y1) + LINE_PAD * 2;
    if (h > maxH) {
      maxH = h;
    }
  }
  const sorted: LineSeg[] = lines.slice().sort((a: LineSeg, b: LineSeg): number =>
    Math.min(a.y1, a.y2) - Math.min(b.y1, b.y2));
  const idx: LineIndex = { sorted: sorted, maxH: maxH };
  lineCache.set(lines, idx);
  return idx;
}

/** 只保留与视口相交的元素；返回新数组，调用方负责缓存 */
export class TreeCuller {
  static euBoxes(boxes: EuBox[], view: ViewRect): EuBox[] {
    const idx: EuBoxIndex = euIndexOf(boxes);
    const sorted: EuBox[] = idx.sorted;
    const out: EuBox[] = [];
    const top: number = view.y;
    const bottom: number = view.y + view.h;
    const left: number = view.x;
    const right: number = view.x + view.w;
    let lo: number = 0;
    let hi: number = sorted.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (sorted[mid].y + idx.maxH < top) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (let i = lo; i < sorted.length; i++) {
      const b: EuBox = sorted[i];
      if (b.y > bottom) {
        break;
      }
      if (b.x < right && b.x + b.w > left && b.y + b.h > top) {
        out.push(b);
      }
    }
    return out;
  }

  static suBoxes(boxes: SuBox[], view: ViewRect): SuBox[] {
    const idx: SuBoxIndex = suIndexOf(boxes);
    const sorted: SuBox[] = idx.sorted;
    const out: SuBox[] = [];
    const top: number = view.y;
    const bottom: number = view.y + view.h;
    const left: number = view.x;
    const right: number = view.x + view.w;
    let lo: number = 0;
    let hi: number = sorted.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (sorted[mid].y + idx.maxH < top) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (let i = lo; i < sorted.length; i++) {
      const b: SuBox = sorted[i];
      if (b.y > bottom) {
        break;
      }
      if (b.x < right && b.x + b.w > left && b.y + b.h > top) {
        out.push(b);
      }
    }
    return out;
  }

  static lines(lines: LineSeg[], view: ViewRect): LineSeg[] {
    const idx: LineIndex = lineIndexOf(lines);
    const sorted: LineSeg[] = idx.sorted;
    const out: LineSeg[] = [];
    const top: number = view.y;
    const bottom: number = view.y + view.h;
    let lo: number = 0;
    let hi: number = sorted.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      const yMin: number = Math.min(sorted[mid].y1, sorted[mid].y2);
      if (yMin + idx.maxH < top) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (let i = lo; i < sorted.length; i++) {
      const s: LineSeg = sorted[i];
      const yMin: number = Math.min(s.y1, s.y2) - LINE_PAD;
      if (yMin > bottom) {
        break;
      }
      const x: number = Math.min(s.x1, s.x2) - LINE_PAD;
      const y: number = yMin;
      const w: number = Math.abs(s.x2 - s.x1) + LINE_PAD * 2;
      const h: number = Math.abs(s.y2 - s.y1) + LINE_PAD * 2;
      if (view.intersects(x, y, w, h)) {
        out.push(s);
      }
    }
    return out;
  }

  /**
   * [PERF] 布局完成后预热索引。
   *
   * 首次裁剪需要 box/line 全量排序（真机 8 万人约 140~190ms）。若留到组件创建后的
   * 首帧 refresh 里执行，会在“画面已经切过去”之后再造一次主线程长任务；
   * 提前到布局阶段做，切支只卡一次，组件首帧直接命中索引。
   */
  static warmupEu(boxes: EuBox[], lines: LineSeg[]): void {
    euIndexOf(boxes);
    lineIndexOf(lines);
  }

  /** 苏式谱预热（与 warmupEu 同理） */
  static warmupSu(boxes: SuBox[], lines: LineSeg[]): void {
    suIndexOf(boxes);
    lineIndexOf(lines);
  }
}
