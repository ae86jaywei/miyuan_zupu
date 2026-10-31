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
  @Prop roots: PersonNode[];
  @Prop cardWidth: number = 112;
  @Prop highlightUid: string = '';
  @Prop dense: boolean = false;
  @Prop showGenMark: boolean = true;
  /** 是否把配偶作为独立卡片画在男性右侧 */
  @Prop showSpouse: boolean = false;
  /** 平移偏移（由父组件持有，切换谱式/刷新后保持） */
  @Link offsetX: number;
  @Link offsetY: number;
  /** 可视区宽度（由父容器传入，用于撑开可平移范围） */
  @Prop viewWidth: number = 0;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  /** 拖动后回调，供父组件记录尺寸 */
  onSize: (w: number, h: number) => void = (w: number, h: number): void => {};

  private canvas(): SuCanvas {
    return SuLayout.compute(this.roots, this.cardWidth, this.dense, this.showSpouse);
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.canvas().lines, (seg: LineSeg, i: number) => {
          Row()
            .width(Math.max(Math.abs(seg.x2 - seg.x1), 1.5))
            .height(Math.max(Math.abs(seg.y2 - seg.y1), 1.5))
            .backgroundColor(seg.red ? Theme.primary : Theme.goldLight)
            .position({ x: Math.min(seg.x1, seg.x2), y: Math.min(seg.y1, seg.y2) })
        }, (seg: LineSeg, i: number) => 'su_ln_' + i.toString() + '_' + seg.x1.toString())

        ForEach(this.canvas().boxes, (box: SuBox) => {
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
