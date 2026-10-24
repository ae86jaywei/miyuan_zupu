import { Theme, Spacing } from '../theme/Theme';

/**
 * 上下滑动选择弹层（自定义实现，替代 TextPicker）。
 *
 * 设计要点：
 *  - 中间一条固定高亮框表示“当前选中项”；
 *  - 列表可上下拖动滚动（List + ScrollBar），停止后自动吸附到最近项；
 *  - 也支持直接点选某一项（点击即选中）；
 *  - 顶部“取消 / 确定”与底部“确定选择”双通道确认。
 */
@Component
export struct SlidePicker {
  @Prop title: string = '';
  @Prop options: string[] = [];
  /** 当前选中下标 */
  @Link selected: number;
  /** 列表可视区高度（每项 44vp） */
  @Prop itemHeight: number = 44;
  onCancel: () => void = (): void => {};
  onConfirm: (value: string, index: number) => void = (value: string, index: number): void => {};
  /** 选中项变化即回调（即时写回字段，避免确认回调丢失） */
  onSelect: (value: string, index: number) => void = (value: string, index: number): void => {};

  private scroller: Scroller = new Scroller();

  private padCount(): number {
    // 上下各留 2 个空位，使首尾项也能滚到中线
    return 2;
  }

  private totalRows(): number {
    return this.options.length + this.padCount() * 2;
  }

  private valueAt(row: number): string {
    const idx: number = row - this.padCount();
    return idx >= 0 && idx < this.options.length ? this.options[idx] : '';
  }

  private select(row: number): void {
    const idx: number = Math.min(Math.max(row - this.padCount(), 0), this.options.length - 1);
    if (this.selected !== idx) {
      this.selected = idx;
      this.onSelect(this.options[idx], idx);
    }
  }

  build() {
    Column() {
      // 顶部操作栏
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.inkTertiary)
          .layoutWeight(1)
          .height('100%')
          .textAlign(TextAlign.Start)
          .onClick((): void => {
            this.onCancel();
          })
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(2)
          .textAlign(TextAlign.Center)
        Text('确定')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.primary)
          .layoutWeight(1)
          .height('100%')
          .textAlign(TextAlign.End)
          .onClick((): void => {
            this.onConfirm(this.options[this.selected], this.selected);
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: Spacing.L, right: Spacing.L })

      // 滚轮区
      Stack() {
        // 选中框
        Row()
          .width('86%')
          .height(this.itemHeight)
          .borderRadius(10)
          .backgroundColor('#FBEFD9')
          .border({ width: 0.5, color: Theme.goldLight })

        List({ scroller: this.scroller, initialIndex: this.selected + this.padCount() }) {
          ForEach(this.buildRows(), (row: number) => {
            ListItem() {
              Row() {
                Text(this.valueAt(row))
                  .fontSize(this.valueAt(row).length > 0 &&
                    this.selected === row - this.padCount() ? 19 : 16)
                  .fontWeight(this.selected === row - this.padCount() ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.valueAt(row).length === 0 ? Color.Transparent :
                    (this.selected === row - this.padCount() ? Theme.primary : Theme.inkSecondary))
                  .maxLines(1)
                  .textAlign(TextAlign.Center)
                  .width('100%')
              }
              .width('100%')
              .height(this.itemHeight)
              .onClick((): void => {
                this.select(row);
              })
            }
          }, (row: number) => 'row_' + row.toString())
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .onScrollStop((): void => {
          // 吸附：按当前滚动偏移计算最近的一行
          const offset: number = this.scroller.currentOffset().yOffset;
          const row: number = Math.round(offset / this.itemHeight);
          this.select(row);
          this.scroller.scrollTo({ xOffset: 0, yOffset: row * this.itemHeight, animation: true });
        })
      }
      .width('100%')
      .height(this.itemHeight * 5)
      .clip(true)

      // 底部确认按钮
      Button('确定选择「' + (this.options.length > 0 ? this.options[this.selected] : '') + '」')
        .width('90%')
        .height(46)
        .margin({ top: 10, bottom: 16 })
        .backgroundColor(Theme.primary)
        .fontSize(15)
        .onClick((): void => {
          this.onConfirm(this.options[this.selected], this.selected);
        })
    }
    .width('100%')
    .backgroundColor(Theme.card)
    .borderRadius({ topLeft: 20, topRight: 20 })
  }

  private buildRows(): number[] {
    const rows: number[] = [];
    for (let i: number = 0; i < this.totalRows(); i++) {
      rows.push(i);
    }
    return rows;
  }
}