import { PersonNode } from '../model/PersonNode';
import { Person } from '../model/Person';
import { TreeStyle, TREE_STYLES, TreeStyleMeta, generationLabel } from '../model/Enums';
import { EuTree } from '../components/tree/EuTree';
import { SuTree } from '../components/tree/SuTree';
import { PagodaTree } from '../components/tree/PagodaTree';
import { DieRecord } from '../components/tree/DieRecord';
import { ModernTree } from '../components/tree/ModernTree';
import { EmptyHint } from '../components/EmptyHint';
import { Theme, Spacing } from '../theme/Theme';
import { GenealogyService } from '../service/GenealogyService';
import { Breakpoint } from '../common/Constants';
import { suRootCenterX } from '../service/TreeLayout';

/**
 * 谱式画布：按所选谱式渲染整部族谱。
 * 内含“世系总表”索引，便于在大屏上快速跳转。
 */
@Component
export struct TreeCanvas {
  @Prop @Watch('onStyleChanged') style: string = TreeStyle.EU;
  @Prop @Watch('onRootsChanged') roots: PersonNode[] = [];
  @Prop people: Person[] = [];
  @Prop highlightUid: string = '';
  @Prop showPrivate: boolean = true;
  @Prop windowWidth: number = 360;
  @Prop @Watch('onZoomChanged') zoom: number = 1;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  /** 欧式/苏式画布平移偏移（拖到哪停到哪） */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 画布内容尺寸（用于限制平移范围）：canvasW 取各宗支最大宽度 */
  @State canvasW: number = 0;
  /** 全部宗支堆叠后的总高度（由外层 Column 实测） */
  @State canvasH: number = 0;
  /** 手势起点 */
  private startX: number = 0;
  private startY: number = 0;
  /** 容器可视区尺寸 */
  @State viewW: number = 0;
  @State viewH: number = 0;
  /** 苏式谱切换后待把始祖居中（等可视区宽度就绪后再执行一次） */
  private pendingCenter: boolean = true;

  private isNarrow(): boolean {
    return this.windowWidth < Breakpoint.SM;
  }

  /** 切换谱式后画布尺寸与布局完全变化，平移偏移必须归零，否则内容会移出可视区 */
  onStyleChanged(): void {
    this.offsetX = 0;
    this.offsetY = 0;
    this.canvasW = 0;
    this.canvasH = 0;
    this.pendingCenter = true;
    this.centerSuIfReady();
  }

  /** 宗支数量/结构变化后画布宽度会变，需重新取最大值 */
  onRootsChanged(): void {
    this.canvasW = 0;
    this.canvasH = 0;
  }

  /** 缩放变化后可用可视范围随之改变，把平移偏移重新夹回边界内 */
  onZoomChanged(): void {
    this.offsetX = this.clampX(this.offsetX);
    this.offsetY = this.clampY(this.offsetY);
  }

  /**
   * 苏式谱的始祖居中于子孙，画布宽度远大于屏幕，默认停在 x=0 时始祖会落在屏幕外，
   * 看起来像“空白”。可视区宽度就绪后把始祖横移到屏幕中间，保证一切换就有内容。
   */
  private centerSuIfReady(): void {
    if (!this.pendingCenter || this.style !== TreeStyle.SU) {
      return;
    }
    if (this.viewW <= 0 || this.roots.length === 0) {
      return;
    }
    this.pendingCenter = false;
    const cx: number = suRootCenterX([this.roots[0]], this.cardWidth(), this.isNarrow());
    this.offsetX = this.viewW / 2 - cx;
    this.offsetY = 0;
  }

  private cardWidth(): number {
    let base: number = 104;
    if (this.windowWidth >= Breakpoint.LG) {
      base = 136;
    } else if (this.windowWidth >= Breakpoint.MD) {
      base = 124;
    } else if (this.windowWidth >= Breakpoint.SM) {
      base = 112;
    }
    return base;
  }

  private groups(): Person[][] {
    const svc: GenealogyService = GenealogyService.getInstance();
    const map: Map<number, Person[]> = svc.groupByGeneration();
    const gens: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    return gens.map((g: number): Person[] => map.get(g) as Person[]);
  }

  private groupLabels(): string[] {
    const svc: GenealogyService = GenealogyService.getInstance();
    const map: Map<number, Person[]> = svc.groupByGeneration();
    const gens: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    return gens.map((g: number): string => generationLabel(g));
  }

  /** 渲染上下方向谱式的世系索引 */
  @Builder
  GenerationIndex() {
    Scroll() {
      Row() {
        ForEach(this.groupLabels(), (label: string, idx: number) => {
          Text(label + ' · ' + this.groups()[idx].length + '人')
            .fontSize(11)
            .fontColor(Theme.primary)
            .backgroundColor(Theme.highlightBg)
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .margin({ right: 6 })
        }, (label: string, idx: number) => 'idx_' + label + idx.toString())
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ bottom: Spacing.M })
  }

  @Builder
  StyleHint() {
    if (this.style !== TreeStyle.DIE) {
      Row() {
        Text('📐 双指缩放 · 拖动平移 · 点击人物查看详情')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
      }
      .width('100%')
      .padding({ bottom: Spacing.S })
    }
  }

  build() {
    Column() {
      this.StyleHint()

      if (this.people.length === 0) {
        EmptyHint({ icon: '🌱', title: '族谱暂无人物', desc: '点击右下角“＋”创建始祖，开启家族记录' })
      } else {
        Scroll() {
          Column() {
            if (this.style === TreeStyle.DIE) {
              ForEach(this.groups(), (grp: Person[], gi: number) => {
                Column() {
                  Row() {
                    Text(generationLabel(grp[0].generation))
                      .fontSize(18)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Theme.primary)
                    Divider()
                      .layoutWeight(1)
                      .color(Theme.goldLight)
                      .margin({ left: Spacing.M })
                  }
                  .width('100%')
                  .margin({ top: gi === 0 ? 0 : Spacing.XL, bottom: Spacing.M })

                  ForEach(grp, (p: Person, pi: number) => {
                    Column() {
                      DieRecord({
                        person: p,
                        index: pi,
                        showPrivate: this.showPrivate,
                        highlight: p.uid === this.highlightUid,
                        onTapPerson: (uid: string): void => {
                          this.onTapPerson(uid);
                        }
                      })
                    }
                    .width('100%')
                    .margin({ bottom: Spacing.M })
                  }, (p: Person) => 'die_' + p.uid)
                }
                .width('100%')
              }, (grp: Person[], gi: number) => 'dieg_' + gi.toString())
            } else if (this.style === TreeStyle.PAGODA) {
              this.GenerationIndex()
              PagodaTree({
                rows: this.buildRows(),
                highlightUid: this.highlightUid,
                compact: this.isNarrow(),
                onTapPerson: (uid: string): void => {
                  this.onTapPerson(uid);
                }
              })
            } else if (this.style === TreeStyle.MODERN) {
              ModernTree({
                groups: this.groups(),
                groupLabels: this.groupLabels(),
                highlightUid: this.highlightUid,
                minCardWidth: this.windowWidth >= Breakpoint.MD ? 220 : (this.isNarrow() ? 150 : 180),
                onTapPerson: (uid: string): void => {
                  this.onTapPerson(uid);
                }
              })
            } else {
              // 欧式 / 苏式：坐标预计算 + 绝对定位画布（手势自由平移 + 整体缩放）
              Column() {
                ForEach(this.roots, (root: PersonNode, ri: number) => {
                  Column() {
                    if (this.roots.length > 1) {
                      Row() {
                        Text('宗支 ' + (ri + 1).toString() + '：' + root.person.name +
                          (root.spouseText().length > 0 ? ' · ' + root.spouseText() : ''))
                          .fontSize(13)
                          .fontWeight(FontWeight.Medium)
                          .fontColor(Theme.primary)
                        Text('后代 ' + root.descendants.toString() + ' 人')
                          .fontSize(11)
                          .fontColor(Theme.inkTertiary)
                          .margin({ left: 6 })
                      }
                      .width('100%')
                      .margin({ bottom: Spacing.S })
                    }
                    if (this.style === TreeStyle.EU) {
                      EuTree({
                        roots: [root],
                        highlightUid: this.highlightUid,
                        cardWidth: this.cardWidth(),
                        dense: this.isNarrow(),
                        showSpouse: true,
                        offsetX: $offsetX,
                        offsetY: $offsetY,
                        viewWidth: this.viewW,
                        onTapPerson: (uid: string): void => {
                          this.onTapPerson(uid);
                        },
                        onSize: (w: number, h: number): void => {
                          this.canvasW = Math.max(this.canvasW, w);
                        }
                      })
                    } else {
                      SuTree({
                        roots: [root],
                        highlightUid: this.highlightUid,
                        cardWidth: this.cardWidth(),
                        dense: this.isNarrow(),
                        showGenMark: true,
                        showSpouse: true,
                        offsetX: $offsetX,
                        offsetY: $offsetY,
                        onTapPerson: (uid: string): void => {
                          this.onTapPerson(uid);
                        },
                        onSize: (w: number, h: number): void => {
                          this.canvasW = Math.max(this.canvasW, w);
                        }
                      })
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .margin({ bottom: Spacing.XXL })
                }, (root: PersonNode) => 'root_' + root.uid)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              // 实测「全部宗支堆叠」后的总高度：多宗支时按各支高度累加，
              // 否则平移边界只按最后一支算，下面几支永远拖不到
              .onAreaChange((oldArea: Area, newArea: Area): void => {
                this.canvasH = Number(newArea.height);
              })
              .scale({ x: this.zoom, y: this.zoom, centerX: 0, centerY: 0 })
              .animation({ duration: 150 })
            }
          }
          .width('100%')
          .padding({ bottom: 120 })
        }
        .scrollable(this.style === TreeStyle.EU || this.style === TreeStyle.SU ?
          ScrollDirection.None : ScrollDirection.Vertical)
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          this.viewW = Number(newArea.width);
          this.viewH = Number(newArea.height);
          this.centerSuIfReady();
        })
        .parallelGesture(
          PanGesture({ fingers: 1, distance: 8, direction: PanDirection.All })
            .onActionStart((event: GestureEvent): void => {
              this.startX = this.offsetX;
              this.startY = this.offsetY;
            })
            .onActionUpdate((event: GestureEvent): void => {
              if (this.style !== TreeStyle.EU && this.style !== TreeStyle.SU) {
                return;
              }
              this.offsetX = this.clampX(this.startX + event.offsetX);
              this.offsetY = this.clampY(this.startY + event.offsetY);
            })
        )
        .scrollBar(BarState.Auto)
        // 拖动平移到哪就停在哪：不使用弹性回弹
        .edgeEffect(EdgeEffect.None)
        .enableScrollInteraction(true)
        .align(Alignment.TopStart)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 水平平移边界：按缩放后的内容宽度计算，两侧各留余量 */
  private clampX(v: number): number {
    const scaledW: number = this.canvasW * this.zoom;
    const max: number = Math.max(scaledW - this.viewW + 120, 160);
    return Math.min(Math.max(v, -max), 320);
  }

  /** 垂直平移边界：按缩放后的「全部宗支总高度」计算，保证最下面一支也能拖出来 */
  private clampY(v: number): number {
    const scaledH: number = this.canvasH * this.zoom;
    const max: number = Math.max(scaledH - this.viewH + 120, 160);
    return Math.min(Math.max(v, -max), 240);
  }

  /** 欧式/苏式画布宽度：按“世代数 × 列宽”估算，保证内容不被压缩 */
  private estimateWidth(): number {
    const svc: GenealogyService = GenealogyService.getInstance();
    let maxGen: number = 1;
    svc.getPeople().forEach((p: Person): void => {
      if (p.generation > maxGen) {
        maxGen = p.generation;
      }
    });
    if (this.style === TreeStyle.SU) {
      return this.windowWidth;
    }
    return Math.max(this.windowWidth, maxGen * (this.cardWidth() + 30) + 40);
  }

  /** 宝塔式：把树按世代扁平化为“层” */
  private buildRows(): PersonNode[][] {
    const rows: PersonNode[][] = [];
    const walk = (node: PersonNode): void => {
      const idx: number = node.person.generation - 1;
      while (rows.length <= idx) {
        rows.push([]);
      }
      const exists: boolean = rows[idx].some((n: PersonNode): boolean => n.uid === node.uid);
      if (!exists) {
        rows[idx].push(node);
      }
      node.children.forEach((c: PersonNode): void => {
        walk(c);
      });
    };
    this.roots.forEach((r: PersonNode): void => {
      walk(r);
    });
    return rows;
  }
}