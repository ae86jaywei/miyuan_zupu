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
  @Prop roots: PersonNode[];
  @Prop cardWidth: number = 112;
  @Prop highlightUid: string = '';
  @Prop dense: boolean = false;
  @Prop showSpouse: boolean = true;
  @Link offsetX: number;
  @Link offsetY: number;
  /** 可视区宽度（由父容器传入，用于撑开可平移范围） */
  @Prop viewWidth: number = 0;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  onSize: (w: number, h: number) => void = (w: number, h: number): void => {};

  private rowHeight(): number {
    return this.dense ? 66 : 78;
  }

  private canvas(): EuCanvas {
    return EuLayout.compute(this.roots, this.cardWidth, this.rowHeight(), 30, this.showSpouse, 6);
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.canvas().lines, (seg: LineSeg, i: number) => {
          Row()
            .width(Math.max(Math.abs(seg.x2 - seg.x1), 1.5))
            .height(Math.max(Math.abs(seg.y2 - seg.y1), 1.5))
            .backgroundColor(Theme.goldLight)
            .position({ x: Math.min(seg.x1, seg.x2), y: Math.min(seg.y1, seg.y2) })
        }, (seg: LineSeg, i: number) => 'ln_' + i.toString() + '_' + seg.x1.toString() + '_' + seg.y1.toString())

        ForEach(this.canvas().boxes, (box: EuBox) => {
          Column() {
            TreeMiniCard({
              node: box.node,
              cardWidth: this.cardWidth,
              highlight: box.node.uid === this.highlightUid,
              dense: this.dense,
              onTapPerson: (uid: string): void => {
                this.onTapPerson(uid);
              }
            })
            if (this.showSpouse && box.node.spouse !== null && !this.dense) {
              Text('配 ' + box.node.spouse.person.name)
                .fontSize(9)
                .fontColor(Theme.gold)
                .maxLines(1)
                .margin({ top: 2 })
                .onClick((): void => {
                  this.onTapPerson((box.node.spouse as PersonNode).uid);
                })
            }
          }
          .width(box.w)
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