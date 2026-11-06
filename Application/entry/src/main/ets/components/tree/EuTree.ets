import { PersonNode } from '../../model/PersonNode';
import { EuBox, EuCanvas, LineSeg } from '../../service/TreeLayout';
import { TreeLayoutCache } from '../../service/TreeLayoutCache';
import { TreeCuller } from '../../service/TreeCuller';
import { ViewRect } from '../../service/TreeViewport';
import { TreeMiniCard } from './TreeMiniCard';
import { Theme } from '../../theme/Theme';
import { TreePerf } from '../../util/TreePerf';
import { contentViewRect, findRootNode, isHorizontalSeg, lineThicknessOf, TreeViewportKeyInput,
  treeViewKey } from './TreeCanvasShared';

/**
 * 欧式谱（横轴世系图）画布。
 * 变换约定：屏幕 = 内容 × zoom + offset（外层 translate，内层 scale）。
 * 布局由 TreeLayoutCache 缓存，只渲染视口内（含 1 屏缓冲）的卡片与连线。
 */
@Component
export struct EuTree {
  @Prop @Watch('onViewportChanged') rootUid: string = '';
  @Prop @Watch('onViewportChanged') layoutVersion: number = 0;
  @Prop @Watch('onViewportChanged') cardWidth: number = 112;
  @Prop highlightUid: string = '';
  @Prop @Watch('onViewportChanged') dense: boolean = false;
  @Prop @Watch('onViewportChanged') showSpouse: boolean = true;
  @Prop @Watch('onViewportChanged') viewWidth: number = 0;
  @Prop @Watch('onViewportChanged') viewHeight: number = 0;
  @Prop @Watch('onViewportChanged') zoom: number = 1;
  /** 本宗支在“全部宗支堆叠画布”中的屏幕起点（已含 zoom，不含平移） */
  @Prop @Watch('onViewportChanged') contentTop: number = 0;
  @Link @Watch('onViewportChanged') offsetX: number;
  @Link @Watch('onViewportChanged') offsetY: number;
  @State visibleBoxes: EuBox[] = [];
  @State visibleLines: LineSeg[] = [];
  @State contentW: number = 0;
  @State contentH: number = 0;
  private lastViewKey: string = '';
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  onSize: (w: number, h: number) => void = (w: number, h: number): void => {};

  aboutToAppear(): void {
    this.refresh();
  }

  private rowHeight(): number {
    return this.dense ? 66 : 78;
  }

  private lineThickness(): number {
    return lineThicknessOf(this.zoom);
  }

  private isHorizontal(seg: LineSeg): boolean {
    return isHorizontalSeg(seg);
  }

  private root(): PersonNode | null {
    return findRootNode(this.rootUid);
  }

  private canvas(): EuCanvas {
    const r: PersonNode | null = this.root();
    const roots: PersonNode[] = r === null ? [] : [r];
    return TreeLayoutCache.getInstance().eu(this.rootUid, roots, this.cardWidth, this.rowHeight(),
      this.showSpouse, 6);
  }

  private viewKey(): string {
    const input: TreeViewportKeyInput = {
      rootUid: this.rootUid,
      offsetX: this.offsetX,
      offsetY: this.offsetY,
      viewWidth: this.viewWidth,
      viewHeight: this.viewHeight,
      zoom: this.zoom,
      layoutVersion: this.layoutVersion,
      contentTop: this.contentTop,
      cardWidth: this.cardWidth,
      dense: this.dense,
      showSpouse: this.showSpouse
    };
    return treeViewKey(input);
  }

  /** 只做裁剪，不做布局；同一视口 key 下重复调用直接返回 */
  private refresh(): void {
    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return;
    }
    const key: string = this.viewKey();
    if (key === this.lastViewKey) {
      return;
    }
    this.lastViewKey = key;
    const canvas: EuCanvas = this.canvas();
    this.contentW = canvas.width;
    this.contentH = canvas.height;
    const view: ViewRect = contentViewRect(this.offsetX, this.offsetY, this.contentTop,
      this.viewWidth, this.viewHeight, this.zoom);
    TreePerf.begin('cull_eu');
    this.visibleBoxes = TreeCuller.euBoxes(canvas.boxes, view);
    this.visibleLines = TreeCuller.lines(canvas.lines, view);
    TreePerf.end('cull_eu', 'visible=' + this.visibleBoxes.length.toString() +
      ' degrade=' + TreePerf.shouldDegrade(this.visibleBoxes.length).toString());
    this.onSize(canvas.width, canvas.height);
  }

  onViewportChanged(): void {
    this.refresh();
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.visibleLines, (seg: LineSeg) => {
          Row()
            .width(this.isHorizontal(seg) ? Math.max(Math.abs(seg.x2 - seg.x1), 1) : this.lineThickness())
            .height(this.isHorizontal(seg) ? this.lineThickness() : Math.max(Math.abs(seg.y2 - seg.y1), 1))
            .backgroundColor(seg.red ? Theme.primary : Theme.goldLight)
            .position({ x: Math.min(seg.x1, seg.x2), y: Math.min(seg.y1, seg.y2) })
        }, (seg: LineSeg) => 'ln_' + this.rootUid + '_' + this.layoutVersion.toString() + '_' +
          this.cardWidth.toString() + '_' + this.dense.toString() + '_' + seg.id.toString())

        ForEach(this.visibleBoxes, (box: EuBox) => {
          TreeMiniCard({
            person: box.node.person,
            spouseText: box.node.spouseText(),
            spouseUid: box.node.spouse === null ? '' : box.node.spouse.uid,
            childCount: box.node.children.length,
            descendants: box.node.descendants,
            cardWidth: box.w,
            cardHeight: box.h,
            highlight: box.node.uid === this.highlightUid,
            dense: this.dense,
            onTapPerson: (uid: string): void => {
              this.onTapPerson(uid);
            }
          })
            .position({ x: box.x, y: box.y })
        }, (box: EuBox) => 'bx_' + this.rootUid + '_' + this.layoutVersion.toString() + '_' +
          this.cardWidth.toString() + '_' + this.dense.toString() + '_' + box.node.uid)
      }
      .width(this.contentW)
      .height(this.contentH)
      .scale({ x: this.zoom, y: this.zoom, centerX: 0, centerY: 0 })
    }
    .width(this.contentW * this.zoom)
    .height(this.contentH * this.zoom)
    .translate({ x: this.offsetX, y: this.offsetY })
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      this.refresh();
    })
  }
}
