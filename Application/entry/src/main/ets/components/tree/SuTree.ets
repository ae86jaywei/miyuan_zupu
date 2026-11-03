import { PersonNode } from '../../model/PersonNode';
import { LineSeg, SuBox, SuCanvas, SuLayout } from '../../service/TreeLayout';
import { TreeMiniCard } from './TreeMiniCard';
import { Theme } from '../../theme/Theme';

/**
 * 苏式谱（竖式吊线图）画布。
 * 父子上下排列、兄弟横向排列，位置由 SuLayout 预计算，连线按坐标精确绘制。
 * 画布本身可自由拖动平移（水平 + 垂直），松手后停在原处。
 */
@Component
export struct SuTree {
  /** 谱树为大对象图，不能用 @Prop（会深拷贝整棵树导致主线程卡死） */
  roots: PersonNode[] = [];
  @Prop @Watch('clearCanvas') cardWidth: number = 112;
  @Prop highlightUid: string = '';
  @Prop @Watch('clearCanvas') dense: boolean = false;
  @Prop showGenMark: boolean = true;
  /** 是否把配偶作为独立卡片画在男性右侧 */
  @Prop @Watch('clearCanvas') showSpouse: boolean = false;
  /** 平移偏移（由父组件持有，切换谱式/刷新后保持） */
  @Link offsetX: number;
  @Link offsetY: number;
  /** 可视区宽度/高度（由父容器传入，用于裁剪渲染与撑开可平移范围） */
  @Prop viewWidth: number = 0;
  @Prop viewHeight: number = 0;
  @Prop zoom: number = 1;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  /** 拖动后回调，供父组件记录尺寸 */
  onSize: (w: number, h: number) => void = (w: number, h: number): void => {};

  /** 布局计算结果缓存：build 中多处引用，O(n) 计算只做一次 */
  private cachedCanvas: SuCanvas | null = null;

  /** 布局参数变化时丢弃缓存 */
  clearCanvas(): void {
    this.cachedCanvas = null;
  }

  private canvas(): SuCanvas {
    const cached: SuCanvas | null = this.cachedCanvas;
    if (cached !== null) {
      return cached;
    }
    const cardH: number = this.dense ? 62 : 74;
    const rowGap: number = this.dense ? 14 : 24;
    const computed: SuCanvas = SuLayout.compute(this.roots, this.cardWidth, cardH, rowGap,
      SuLayout.COL_GAP, this.showSpouse);
    this.cachedCanvas = computed;
    return computed;
  }

  /** 只保留与视口相交的卡片：人数上万时全量创建组件会长时间阻塞主线程 */
  private visibleBoxes(canvas: SuCanvas): SuBox[] {
    const z: number = this.zoom > 0 ? this.zoom : 1;
    const margin: number = 200 / z;
    const left: number = -this.offsetX - margin;
    const top: number = -this.offsetY - margin;
    const right: number = left + (this.viewWidth > 0 ? this.viewWidth : 360) / z + margin * 2;
    const bottom: number = top + (this.viewHeight > 0 ? this.viewHeight : 640) / z + margin * 2;
    const out: SuBox[] = [];
    for (let i: number = 0; i < canvas.boxes.length; i = i + 1) {
      const b: SuBox = canvas.boxes[i];
      if (b.x + b.w >= left && b.x <= right && b.y + b.h >= top && b.y <= bottom) {
        out.push(b);
      }
    }
    return out;
  }

  /** 只保留与视口相交的连线 */
  private visibleLines(canvas: SuCanvas): LineSeg[] {
    const z: number = this.zoom > 0 ? this.zoom : 1;
    const margin: number = 200 / z;
    const left: number = -this.offsetX - margin;
    const top: number = -this.offsetY - margin;
    const right: number = left + (this.viewWidth > 0 ? this.viewWidth : 360) / z + margin * 2;
    const bottom: number = top + (this.viewHeight > 0 ? this.viewHeight : 640) / z + margin * 2;
    const out: LineSeg[] = [];
    for (let i: number = 0; i < canvas.lines.length; i = i + 1) {
      const s: LineSeg = canvas.lines[i];
      const x1: number = Math.min(s.x1, s.x2);
      const x2: number = Math.max(s.x1, s.x2);
      const y1: number = Math.min(s.y1, s.y2);
      const y2: number = Math.max(s.y1, s.y2);
      if (x2 >= left && x1 <= right && y2 >= top && y1 <= bottom) {
        out.push(s);
      }
    }
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
        }, (seg: LineSeg, i: number) => 'su_ln_' + i.toString() + '_' + seg.x1.toString())

        ForEach(this.visibleBoxes(this.canvas()), (box: SuBox) => {
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
        }, (box: SuBox) => 'su_bx_' + box.node.uid)
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
