import { T, uiFontFamily } from 'common_base';
import { Theme, Spacing, Radius } from 'common_base';
import { GraveEntry, generationLabel } from 'common_base';
import { RouterUtil } from 'common_base';

/**
 * 公开墓葬卡片：在 LazyForEach 中复用，
 * 滚动时只更新数据、不重复创建整棵文本子树。
 */
@Reusable
@Component
export struct GraveCardView {
  @State g: GraveEntry = new GraveEntry();

  aboutToReuse(params: Record<string, Object>): void {
    this.g = params.g as GraveEntry;
  }

  build() {
    Column() {
      Row() {
        Text(T(this.g.personName.length > 0 ? this.g.personName : this.g.uid)).fontFamily(uiFontFamily())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text(T(this.g.generation > 0 ? generationLabel(this.g.generation) : '')).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.gold)
      }
      .width('100%')
      if (this.g.bookTitle.length > 0) {
        Text(T('《' + this.g.bookTitle + '》')).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 2 })
          .width('100%')
      }
      if (this.g.graveName.length > 0) {
        Text(T('墓地：' + this.g.graveName)).fontFamily(uiFontFamily())
          .fontSize(12.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 4 })
          .width('100%')
      }
      Text(T('坐标：' + this.g.locationText() +
        (this.g.altitude !== 0 ? ' · 海拔 ' + Math.round(this.g.altitude).toString() + ' 米' : '') +
        (this.g.precision === 'BLURRED' ? '（已模糊至约30米）' : ''))).fontFamily(uiFontFamily())
        .fontSize(11.5)
        .fontColor(Theme.inkSecondary)
        .margin({ top: 3 })
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
      if (this.g.facing.length > 0) {
        Text(T('朝向：' + this.g.facing)).fontFamily(uiFontFamily())
          .fontSize(11.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 2 })
          .width('100%')
      }
      if (this.g.routeNote.length > 0) {
        Text(T('寻墓路线：' + this.g.routeNote)).fontFamily(uiFontFamily())
          .fontSize(11.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 2 })
          .width('100%')
      }
      Row() {
        if (this.g.hasLocation()) {
          Button(T('导航前往')).fontFamily(uiFontFamily())
            .fontSize(12.5)
            .height(32)
            .backgroundColor(Theme.primary)
            .fontColor(Theme.onPrimary)
            .onClick((): void => {
              RouterUtil.openMap(this.g.lng, this.g.lat, this.g.personName + ' 墓');
            })
        }
        Blank()
        Text(T('公开墓葬表 · 更新于 ' + new Date(this.g.updatedAt).toLocaleDateString())).fontFamily(uiFontFamily())
          .fontSize(9.5)
          .fontColor(Theme.inkTertiary)
      }
      .width('100%')
      .margin({ top: Spacing.S })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ bottom: Spacing.M })
  }
}
