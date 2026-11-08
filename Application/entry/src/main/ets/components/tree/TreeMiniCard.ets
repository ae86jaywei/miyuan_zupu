import { Person } from '../../model/Person';
import { Theme } from '../../theme/Theme';
import { generationLabel } from '../../model/Enums';

/**
 * 欧式 / 苏式 / 宝塔式谱系图中的人物小卡片。
 *
 * 只接收扁平的 Person 与预先算好的展示字段，不接收 PersonNode：
 * PersonNode 的 father/mother/spouse/children 互为引用，作为 @Prop 会被深拷贝并递归爆栈。
 */
@Component
export struct TreeMiniCard {
  @Prop person: Person = new Person();
  /** 预先格式化的配偶文案，如：“配 林氏、继室 陈氏” */
  @Prop spouseText: string = '';
  /** 第一位配偶 uid，空字符串表示无 */
  @Prop spouseUid: string = '';
  @Prop childCount: number = 0;
  @Prop descendants: number = 0;
  @Prop cardWidth: number = 116;
  @Prop highlight: boolean = false;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;

  onDark(): void {
    Theme.use(this.darkMode);
  }
  @Prop dense: boolean = false;
  /** 固定卡片高度（由谱图布局传入，保证连线与卡框精确对齐；<=0 时不约束） */
  @Prop cardHeight: number = 0;
  /** 是否在卡片内展示配偶（欧式/苏式由外层单独绘制配偶卡时传 false） */
  @Prop showSpouseInline: boolean = false;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  private genChar(): string {
    return this.person.generationChar.length > 0 ? this.person.generationChar + '字' : '';
  }

  /** 姓名行高：卡片高度固定，行高必须给定，否则文字会溢出卡片下边框 */
  private nameLineHeight(): number {
    return this.dense ? 16 : 17;
  }

  /** 次要信息行高（世代/UID/配偶/子嗣），9 号字配 12 行高保证整卡排版可算 */
  private infoLineHeight(): number {
    return 12;
  }

  build() {
    Column() {
      Row() {
        Text(this.person.name)
          .fontSize(this.dense ? 13 : 14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.person.gender === '女' ? Theme.female : Theme.ink)
          .lineHeight(this.nameLineHeight())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.genChar().length > 0) {
          Text(this.genChar())
            .fontSize(9)
            .lineHeight(this.infoLineHeight())
            .fontColor(Theme.gold)
            .margin({ left: 2 })
            .maxLines(1)
            .flexShrink(0)
        }
        if (this.person.lifeStatus === '已故') {
          Text('故')
            .fontSize(9)
            .lineHeight(this.infoLineHeight())
            .fontColor(Theme.deceased)
            .backgroundColor(Theme.field)
            .borderRadius(3)
            .padding({ left: 3, right: 3 })
            .margin({ left: 2 })
            .flexShrink(0)
        } else if (this.person.lifeStatus === '失联') {
          Text('？')
            .fontSize(9)
            .lineHeight(this.infoLineHeight())
            .fontColor(Theme.lost)
            .margin({ left: 2 })
            .flexShrink(0)
        }
      }
      .width('100%')
      .height(this.nameLineHeight())

      // 世代 + 唯一ID + 字派
      Row() {
        Text(generationLabel(this.person.generation))
          .fontSize(9)
          .lineHeight(this.infoLineHeight())
          .fontColor('#FFFFFF')
          .backgroundColor(Theme.primaryLight)
          .borderRadius(4)
          .padding({ left: 4, right: 4 })
          .flexShrink(0)
        Text(this.person.uid)
          .fontSize(9)
          .lineHeight(this.infoLineHeight())
          .fontColor(Theme.inkTertiary)
          .margin({ left: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 2 })

      // 关联配偶
      if (this.spouseText.length > 0) {
        Text(this.spouseText)
          .fontSize(9)
          .lineHeight(this.infoLineHeight())
          .fontColor(Theme.inkSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 1 })
          .onClick((): void => {
            if (this.spouseUid.length > 0) {
              this.onTapPerson(this.spouseUid);
            }
          })
      }

      if (this.childCount > 0 && !this.dense) {
        Text(this.childCount.toString() + '子 · 后代' + this.descendants.toString() + '人')
          .fontSize(9)
          .lineHeight(this.infoLineHeight())
          .fontColor(Theme.inkTertiary)
          .margin({ top: 1 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width(this.cardWidth)
    .height(this.cardHeight > 0 ? this.cardHeight : undefined)
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .backgroundColor(this.highlight ? Theme.highlightBg : Theme.card)
    .borderRadius(10)
    .border({
      width: this.highlight ? 2 : 1,
      color: this.highlight ? Theme.gold : (this.person.gender === '女' ? '#EFC9D5' : '#CFDCEA')
    })
    // 兜底：卡片高度由谱式布局固定，任何一行都不允许画到卡片外
    .clip(true)
    .shadow({ radius: 6, color: Theme.shadow, offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTapPerson(this.person.uid);
    })
  }
}
