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

/**
 * 谱式画布：按所选谱式渲染整部族谱。
 * 内含“世系总表”索引，便于在大屏上快速跳转。
 */
@Component
export struct TreeCanvas {
  @Prop style: string = TreeStyle.EU;
  @Prop roots: PersonNode[] = [];
  @Prop people: Person[] = [];
  @Prop highlightUid: string = '';
  @Prop showPrivate: boolean = true;
  @Prop windowWidth: number = 360;
  @Prop zoom: number = 1;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  /** 欧式/苏式画布平移偏移（拖到哪停到哪） */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 画布内容尺寸（用于限制平移范围） */
  @State canvasW: number = 0;
  @State canvasH: number = 0;
  /** 手势起点 */
  private startX: number = 0;
  private startY: number = 0;
  /** 容器可视区尺寸 */
  @State viewW: number = 0;
  @State viewH: number = 0;

  private isNarrow(): boolean {
    return this.windowWidth < Breakpoint.SM;
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
                          this.canvasW = w;
                          this.canvasH = h;
                        }
                      })
                    } else {
                      SuTree({
                        roots: [root],
                        highlightUid: this.highlightUid,
                        cardWidth: this.cardWidth(),
                        dense: this.isNarrow(),
                        showGenMark: true,
                        offsetX: $offsetX,
                        offsetY: $offsetY,
                        onTapPerson: (uid: string): void => {
                          this.onTapPerson(uid);
                        },
                        onSize: (w: number, h: number): void => {
                          this.canvasW = w;
                          this.canvasH = h;
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

  /** 水平平移边界：内容两侧各留 60vp 余量，保证可自由左右拖动查看 */
  private clampX(v: number): number {
    const max: number = Math.max(this.canvasW - this.viewW + 120, 160);
    return Math.min(Math.max(v, -max), 320);
  }

  /** 垂直平移边界 */
  private clampY(v: number): number {
    const max: number = Math.max(this.canvasH - this.viewH + 120, 160);
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