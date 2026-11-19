import { T, Theme, Radius, Spacing, uiFontFamily } from 'common_base';

/** 预览行：label / value，value 为空时不显示 */
export class PreviewItem {
  label: string = '';
  value: string = '';
}

/** 编辑页右侧族谱预览卡 */
@Component
export struct SidePreview {
  @Prop name: string = '';
  @Prop gender: string = '';
  @Prop subtitle: string = '';
  @Prop items: PreviewItem[] = [];
  @Prop biography: string = '';

  private lineText(item: PreviewItem): string {
    return item.value.length > 0 ? item.label + '：' + item.value : '';
  }

  build() {
    Column() {
      Text(T('族谱预览')).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.inkTertiary).width('100%')
      Column() {
        Text(T(this.name.length > 0 ? this.name : '未命名')).fontFamily(uiFontFamily())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.gender === '女' ? Theme.female : Theme.primary)
        Text(T(this.subtitle)).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 4 })
        Divider().color(Theme.line).margin({ top: 10, bottom: 10 })
        ForEach(this.items, (item: PreviewItem) => {
          if (this.lineText(item).length > 0) {
            Text(T(this.lineText(item))).fontFamily(uiFontFamily())
          }
        }, (item: PreviewItem, idx: number) => 'preview_' + idx.toString())
        if (this.biography.length > 0) {
          Text(T(this.biography)).fontFamily(uiFontFamily())
            .fontSize(12)
            .lineHeight(20)
            .fontColor(Theme.inkSecondary)
            .margin({ top: 8 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(Spacing.L)
      .backgroundColor(Theme.card)
      .borderRadius(Radius.L)
      .border({ width: 0.5, color: Theme.line })
      .margin({ top: Spacing.S })
    }
    .width('100%')
  }
}
