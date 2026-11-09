import { PersonNode } from '../../model/PersonNode';
import { LineSeg, SuBox, SuCanvas } from '../../service/TreeLayout';
import { TreeLayoutCache } from '../../service/TreeLayoutCache';
import { TreeCuller } from '../../service/TreeCuller';
import { ViewRect } from '../../service/TreeViewport';
import { TreeMiniCard } from './TreeMiniCard';
import { Theme } from '../../theme/Theme';
import { TreePerf } from '../../util/TreePerf';
import { contentViewRect, findRootNode, isHorizontalSeg, lineThicknessOf, TreeViewportKeyInput,
  treeViewKey, Bubble, DETAIL_BUBBLE, DETAIL_FULL, aggregateSu, detailLevelOf }
  from './TreeCanvasShared';

/**
 * 苏式谱（竖式吊线图）画布。
 * 变换约定：屏幕 = 内容 × zoom + offset（外层 translate，内层 scale）。
 * 布局由 TreeLayoutCache 缓存，只渲染视口内（含 1 屏缓冲）的卡片与连线。
 */
@Component
export struct SuTree {
  @Prop @Watch('onViewportChanged') rootUid: string = '';
  @Prop @Watch('onViewportChanged') layoutVersion: number = 0;
  @Prop @Watch('onViewportChanged') cardWidth: number = 112;
  @Prop highlightUid: string = '';
  @Prop @Watch('onViewportChanged') dense: boolean = false;
  @Prop showGenMark: boolean = true;
  @Prop @Watch('onViewportChanged') showSpouse: boolean = true;
  @Prop @Watch('onViewportChanged') viewWidth: number = 0;
  @Prop @Watch('onViewportChanged') viewHeight: number = 0;
  @Prop @Watch('onViewportChanged') zoom: number = 1;
  /** 本宗支在“全部宗支堆叠画布”中的屏幕起点（已含 zoom，不含平移） */
  @Prop @Watch('onViewportChanged') contentTop: number = 0;
  /** 手势进行中：主动降一级渲染，抬手后再恢复 */
  @Prop @Watch('onViewportChanged') interacting: boolean = false;
  @Link @Watch('onViewportChanged') offsetX: number;
  @Link @Watch('onViewportChanged') offsetY: number;
  @State visibleBoxes: SuBox[] = [];
  @State visibleLines: LineSeg[] = [];
  /** 当前细节层次：2 完整卡片 / 1 姓名骨架 / 0 聚合气泡 */
  @State lodLevel: number = DETAIL_FULL;
  @State bubbles: Bubble[] = [];
  @State contentW: number = 0;
  @State contentH: number = 0;
  private lastViewKey: string = '';
  /** 布局参数未变时复用 canvas 引用，避免拖拽/缩放每帧都重新拼 key 查缓存 */
  private cachedCanvas: SuCanvas | null = null;
  private cachedCanvasKey: string = '';
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  onSize: (w: number, h: number) => void = (w: number, h: number): void => {};
  /** 点击聚合气泡：请求画布以该内容点为中心放大 */
  onZoomAt: (contentX: number, contentY: number, contentTop: number) => void =
    (contentX: number, contentY: number, contentTop: number): void => {};

  aboutToAppear(): void {
    this.refresh();
  }

  private lineThickness(): number {
    return lineThicknessOf(this.zoom);
  }

  private isHorizontal(seg: LineSeg): boolean {
    return isHorizontalSeg(seg);
  }

  /** 骨架模式显示“姓 + 名首字”，避免低缩放下文字糊成一团 */
  private shortName(name: string): string {
    if (name.length <= 2) {
      return name;
    }
    return name.substring(0, 2);
  }

  private safeZoom(): number {
    return this.zoom > 0.01 ? this.zoom : 0.01;
  }

  private root(): PersonNode | null {
    return findRootNode(this.rootUid);
  }

  private canvas(): SuCanvas {
    const key: string = this.rootUid + '|' + this.cardWidth.toString() + '|' +
      this.dense.toString() + '|' + this.showSpouse.toString() + '|' +
      this.layoutVersion.toString();
    if (this.cachedCanvas !== null && this.cachedCanvasKey === key) {
      return this.cachedCanvas;
    }
    const r: PersonNode | null = this.root();
    const roots: PersonNode[] = r === null ? [] : [r];
    const canvas: SuCanvas = TreeLayoutCache.getInstance().su(this.rootUid, roots, this.cardWidth,
      this.dense, this.showSpouse);
    this.cachedCanvas = canvas;
    this.cachedCanvasKey = key;
    return canvas;
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
      showSpouse: this.showSpouse,
      interacting: this.interacting
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
    const canvas: SuCanvas = this.canvas();
    this.contentW = canvas.width;
    this.contentH = canvas.height;
    const view: ViewRect = contentViewRect(this.offsetX, this.offsetY, this.contentTop,
      this.viewWidth, this.viewHeight, this.zoom);
    TreePerf.begin('cull_su');
    this.visibleBoxes = TreeCuller.suBoxes(canvas.boxes, view);
    this.visibleLines = TreeCuller.lines(canvas.lines, view);
    this.lodLevel = detailLevelOf(this.zoom, this.interacting, this.visibleBoxes.length);
    if (this.lodLevel === DETAIL_BUBBLE) {
      this.bubbles = aggregateSu(this.visibleBoxes, this.zoom, this.offsetX, this.offsetY, this.contentTop);
    } else {
      this.bubbles = [];
    }
    TreePerf.end('cull_su', 'visible=' + this.visibleBoxes.length.toString() +
      ' lod=' + this.lodLevel.toString() +
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
        }, (seg: LineSeg) => 'su_ln_' + this.rootUid + '_' + this.layoutVersion.toString() + '_' +
          this.cardWidth.toString() + '_' + this.dense.toString() + '_' + seg.id.toString())

        if (this.lodLevel === DETAIL_BUBBLE) {
          ForEach(this.bubbles, (b: Bubble) => {
            Stack({ alignContent: Alignment.Center }) {
              if (b.count > 1) {
                Text(b.count.toString())
                  .fontSize(11 / this.safeZoom())
                  .fontColor('#FFFFFF')
                  .fontWeight(FontWeight.Medium)
              }
            }
            .width(b.r * 2)
            .height(b.r * 2)
            .borderRadius(b.r)
            .backgroundColor(b.femaleRatio > 0.6 ? Theme.female : Theme.male)
            .border({ width: 1.5 / this.safeZoom(), color: 'rgba(255,255,255,0.75)' })
            .position({ x: b.x - b.r, y: b.y - b.r })
            .onClick((): void => {
              this.onZoomAt(b.x, b.y, this.contentTop);
            })
          }, (b: Bubble) => 'su_bub_' + this.rootUid + '_' + this.layoutVersion.toString() + '_' + b.key)
        } else {
          ForEach(this.visibleBoxes, (box: SuBox) => {
            if (this.lodLevel >= DETAIL_FULL) {
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
            } else {
              Stack({ alignContent: Alignment.Center }) {
                Text(this.shortName(box.node.person.name))
                  .fontSize(11 / this.safeZoom())
                  .fontWeight(FontWeight.Medium)
                  .fontColor(box.node.person.gender === '女' ? Theme.female : Theme.ink)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width(box.w)
              .height(box.h)
              .backgroundColor(box.node.uid === this.highlightUid ? Theme.highlightBg : Theme.card)
              .borderRadius(8)
              .border({
                width: 1 / this.safeZoom(),
                color: box.node.person.gender === '女' ? '#EFC9D5' : '#CFDCEA'
              })
              .position({ x: box.x, y: box.y })
              .onClick((): void => {
                this.onTapPerson(box.node.uid);
              })
            }
          }, (box: SuBox) => 'su_bx_' + this.rootUid + '_' + this.layoutVersion.toString() + '_' +
            this.cardWidth.toString() + '_' + this.dense.toString() + '_' + this.lodLevel.toString() +
            '_' + box.node.uid)
        }
      }
      .width(this.contentW)
      .height(this.contentH)
      .scale({ x: this.zoom, y: this.zoom, centerX: '0%', centerY: '0%' })
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
