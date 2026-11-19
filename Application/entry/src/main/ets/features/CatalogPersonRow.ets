import { Person, Theme, Spacing, T, createEmptyPerson, generationLabel, uiFontFamily } from 'common_base';
import { lifeSpan } from 'common_dateutil';
import { PersonAvatar } from 'common_ui';

/**
 * 世系名录行。
 *
 * 长列表滚动时用 @Reusable 复用组件实例，避免反复创建头像与文本子树；
 * 选中态通过 @Prop 传入，切换选中不再重建整表。
 */
@Component
@Reusable
export struct CatalogPersonRow {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  @Prop person: Person = createEmptyPerson();
  @Prop selected: boolean = false;
  @Prop showArrow: boolean = true;
  @Prop wide: boolean = false;
  /** 同一次列表里所有行共用同一个回调，复用时不需重新赋值 */
  onOpen: (uid: string) => void = (uid: string): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.person = params['person'] as Person;
    this.selected = params['selected'] as boolean;
    this.showArrow = params['showArrow'] as boolean;
    this.wide = params['wide'] as boolean;
  }

  build() {
    Row() {
      PersonAvatar({ person: this.person, avatarSize: this.wide ? 40 : 38, showRing: false })
      Column() {
        Row() {
          Text(T(this.person.name)).fontFamily(uiFontFamily())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.person.gender === '女' ? Theme.female : Theme.ink)
          if (this.person.rank.length > 0) {
            Text(T(this.person.rank)).fontFamily(uiFontFamily())
              .fontSize(10)
              .fontColor(Theme.gold)
              .margin({ left: 4 })
          }
          if (this.person.lifeStatus === '已故') {
            Text(T('已故')).fontFamily(uiFontFamily()).fontSize(9).fontColor(Theme.deceased).margin({ left: 4 })
          }
        }
        Row() {
          Text(T(this.person.uid + ' · ' + generationLabel(this.person.generation)
            + (this.person.generationChar.length > 0 ? ' · ' + this.person.generationChar + '字' : '')))
            .fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
        }
        .margin({ top: 2 })
        if (this.wide && (this.person.occupation.length > 0 || this.person.birthPlace.length > 0)) {
          Text(T(lifeSpan(this.person.birthDate, this.person.deathDate, this.person.lifeStatus)
            + (this.person.occupation.length > 0 ? ' · ' + this.person.occupation : ''))).fontFamily(uiFontFamily())
            .fontSize(11)
            .fontColor(Theme.inkSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: Spacing.M })

      if (this.showArrow) {
        Text(T(this.selected ? '●' : '›')).fontFamily(uiFontFamily())
          .fontSize(this.selected ? 12 : 18)
          .fontColor(this.selected ? Theme.primary : Theme.inkTertiary)
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 4, right: 4 })
    .backgroundColor(this.selected ? Theme.highlightBg : Color.Transparent)
    .borderRadius(8)
    .onClick((): void => {
      this.onOpen(this.person.uid);
    })
  }
}
