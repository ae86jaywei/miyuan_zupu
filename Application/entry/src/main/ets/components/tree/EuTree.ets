import { hilog } from '@kit.PerformanceAnalysisKit';
import { PersonNode } from '../../model/PersonNode';
import { EuBox, EuCanvas, EuLayout, LineSeg } from '../../service/TreeLayout';
import { TreeMiniCard } from './TreeMiniCard';
import { Theme } from '../../theme/Theme';

/**
 * 欧式谱（横轴世系图）画布。
 * 位置由 EuLayout 预计算，卡片与连线按坐标绝对定位；
 * 画布可自由拖动平移（水平 + 垂直），松手后停在原处。
 */
@Component
export struct EuTree {
  /**
   * 谱树为大对象图，不能用 @Prop（会深拷贝整棵树导致主线程卡死）。
   * 普通成员按引用传入，父组件版本变化时重建本组件即可刷新。
   */
  roots: PersonNode[] = [];
  @Prop @Watch('clearCanvas') cardWidth: number = 112;
  @Prop highlightUid: string = '';
  @Prop @Watch('clearCanvas') dense: boolean = false;
  @Prop @Watch('clearCanvas') showSpouse: boolean = true;
  @Link offsetX: number;
  @Link offsetY: number;
  /** 可视区宽度/高度（由父容器传入，用于裁剪渲染与撑开可平移范围） */
  @Prop viewWidth: number = 0;
  @Prop viewHeight: number = 0;
  @Prop zoom: number = 1;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  onSize: (w: number, h: number) => void = (w: number, h: number): void => {};

  /** 布局计算结果缓存：build 中多处引用，O(n) 计算只做一次 */
  private cachedCanvas: EuCanvas | null = null;

  private rowHeight(): number {
    return this.dense ? 66 : 78;
  }

  /** 布局参数变化时丢弃缓存 */
  clearCanvas(): void {
    this.cachedCanvas = null;
  }

  private canvas(): EuCanvas {
    const cached: EuCanvas | null = this.cachedCanvas;
    if (cached !== null) {
      return cached;
    }
    const t0: number = Date.now();
    const computed: EuCanvas = EuLayout.computeCached(this.roots, this.cardWidth, this.rowHeight(), 30,
      this.showSpouse, 6);
    hilog.info(0x0000, '[Tree][Eu]',
      'layout roots=%{public}d boxes=%{public}d cost=%{public}dms view=%{public}dx%{public}d',
      this.roots.length, computed.boxes.length, Date.now() - t0, this.viewWidth, this.viewHeight);
    this.cachedCanvas = computed;
    return computed;
  }

  /** 只保留与视口相交的卡片：人数上万时全量创建组件会长时间阻塞主线程 */
  private visibleBoxes(canvas: EuCanvas): EuBox[] {
    const z: number = this.zoom > 0 ? this.zoom : 1;
    const margin: number = 200 / z;
    const left: number = -this.offsetX - margin;
    const top: number = -this.offsetY - margin;
    const right: number = left + (this.viewWidth > 0 ? this.viewWidth : 360) / z + margin * 2;
    const bottom: number = top + (this.viewHeight > 0 ? this.viewHeight : 640) / z + margin * 2;
    const out: EuBox[] = [];
    const buckets: EuBox[][] = canvas.buckets;
    if (buckets.length > 0) {
      // 只扫视口覆盖的纵向条带：4 万人全量遍历每帧要几十毫秒，拖动会明显掉帧
      const bh: number = canvas.bucketH > 0 ? canvas.bucketH : 600;
      let k0: number = Math.floor(top / bh);
      let k1: number = Math.floor(bottom / bh);
      if (k0 < 0) {
        k0 = 0;
      }
      if (k1 >= buckets.length) {
        k1 = buckets.length - 1;
      }
      for (let k: number = k0; k <= k1; k = k + 1) {
        const arr: EuBox[] = buckets[k];
        for (let i: number = 0; i < arr.length; i = i + 1) {
          const b: EuBox = arr[i];
          if (b.x + b.w >= left && b.x <= right && b.y + b.h >= top && b.y <= bottom) {
            out.push(b);
          }
        }
      }
      return out;
    }
    for (let i: number = 0; i < canvas.boxes.length; i = i + 1) {
      const b: EuBox = canvas.boxes[i];
      if (b.x + b.w >= left && b.x <= right && b.y + b.h >= top && b.y <= bottom) {
        out.push(b);
      }
    }
    return out;
  }

  /**
   * 只保留与视口相交的连线。
   * 竖向母线在 4 万人的谱里可能高达上百万像素，直接按原坐标建组件会生成一个超大 Row，
   * 因此这里把它裁剪到视口范围内再画；跨条带的线在多个桶里重复出现，需要去重。
   */
  private visibleLines(canvas: EuCanvas): LineSeg[] {
    const z: number = this.zoom > 0 ? this.zoom : 1;
    const margin: number = 120 / z;
    const left: number = -this.offsetX - margin;
    const top: number = -this.offsetY - margin;
    const right: number = left + (this.viewWidth > 0 ? this.viewWidth : 360) / z + margin * 2;
    const bottom: number = top + (this.viewHeight > 0 ? this.viewHeight : 640) / z + margin * 2;
    const out: LineSeg[] = [];
    const seen: Set<LineSeg> = new Set<LineSeg>();
    const buckets: LineSeg[][] = canvas.lineBuckets;
    const take = (arr: LineSeg[]): void => {
      for (let i: number = 0; i < arr.length; i = i + 1) {
        const s: LineSeg = arr[i];
        if (seen.has(s)) {
          continue;
        }
        seen.add(s);
        const x1: number = Math.min(s.x1, s.x2);
        const x2: number = Math.max(s.x1, s.x2);
        const y1: number = Math.min(s.y1, s.y2);
        const y2: number = Math.max(s.y1, s.y2);
        if (x2 < left || x1 > right || y2 < top || y1 > bottom) {
          continue;
        }
        const cx1: number = Math.min(Math.max(s.x1, left), right);
        const cx2: number = Math.min(Math.max(s.x2, left), right);
        const cy1: number = Math.min(Math.max(s.y1, top), bottom);
        const cy2: number = Math.min(Math.max(s.y2, top), bottom);
        if (cx1 === s.x1 && cx2 === s.x2 && cy1 === s.y1 && cy2 === s.y2) {
          out.push(s);
          continue;
        }
        const n: LineSeg = new LineSeg();
        n.red = s.red;
        n.x1 = cx1;
        n.y1 = cy1;
        n.x2 = cx2;
        n.y2 = cy2;
        out.push(n);
      }
    };
    if (buckets.length > 0) {
      const bh: number = canvas.bucketH > 0 ? canvas.bucketH : 600;
      let k0: number = Math.floor(top / bh);
      let k1: number = Math.floor(bottom / bh);
      if (k0 < 0) {
        k0 = 0;
      }
      if (k1 >= buckets.length) {
        k1 = buckets.length - 1;
      }
      for (let k: number = k0; k <= k1; k = k + 1) {
        take(buckets[k]);
      }
      return out;
    }
    take(canvas.lines);
    return out;
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.visibleLines(this.canvas()), (seg: LineSeg, i: number) => {
          Row()
            .width(Math.max(Math.abs(seg.x2 - seg.x1), 1.5))
            .height(Math.max(Math.abs(seg.y2 - seg.y1), 1.5))
            .backgroundColor(seg.red ? Theme.primary : Theme.goldLight)
            .position({ x: Math.min(seg.x1, seg.x2), y: Math.min(seg.y1, seg.y2) })
        }, (seg: LineSeg, i: number) => 'ln_' + seg.x1.toString() + '_' + seg.y1.toString() +
          '_' + seg.x2.toString() + '_' + seg.y2.toString() + (seg.red ? 'r' : 'g'))

        ForEach(this.visibleBoxes(this.canvas()), (box: EuBox) => {
          TreeMiniCard({
            node: box.node,
            cardWidth: box.w,
            cardHeight: box.h,
            highlight: box.node.uid === this.highlightUid,
            dense: this.dense,
            onTapPerson: (uid: string): void => {
              this.onTapPerson(uid);
            }
          })
            .position({ x: box.x, y: box.y })
        }, (box: EuBox) => 'bx_' + box.node.uid)
      }
      .width(Math.max(this.canvas().width, this.viewWidth + 600))
      .height(this.canvas().height)
      .translate({ x: this.offsetX, y: this.offsetY })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      this.onSize(this.canvas().width, this.canvas().height);
    })
  }
}