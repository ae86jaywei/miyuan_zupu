import { PersonNode } from '../../model/PersonNode';
import { Theme } from '../../theme/Theme';
import { generationLabel } from '../../model/Enums';

/**
 * 欧式 / 苏式 / 宝塔式谱系图中的人物小卡片。
 * 卡片内固定展示：谱名、世代（第几世）、唯一ID、字派、配偶。
 */
@Component
export struct TreeMiniCard {
  @Prop node: PersonNode;
  @Prop cardWidth: number = 116;
  @Prop highlight: boolean = false;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;

  onDark(): void {
    Theme.use(this.darkMode);
  }
  @Prop dense: boolean = false;
  /** 是否在卡片内展示配偶（欧式/苏式由外层单独绘制配偶卡时传 false） */
  @Prop showSpouseInline: boolean = false;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  private genChar(): string {
    return this.node.person.generationChar.length > 0 ? this.node.person.generationChar + '字' : '';
  }

  private spouseText(): string {
    return this.node.spouseText();
  }

  build() {
    Column() {
      Row() {
        Text(this.node.person.name)
          .fontSize(this.dense ? 13 : 14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.node.person.gender === '女' ? Theme.female : Theme.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.node.person.lifeStatus === '已故') {
          Text('故')
            .fontSize(9)
            .fontColor(Theme.deceased)
            .backgroundColor(Theme.field)
            .borderRadius(3)
            .padding({ left: 3, right: 3 })
            .margin({ left: 2 })
        } else if (this.node.person.lifeStatus === '失联') {
          Text('？')
            .fontSize(9)
            .fontColor(Theme.lost)
            .margin({ left: 2 })
        }
      }
      .width('100%')

      // 世代 + 唯一ID + 字派
      Row() {
        Text(generationLabel(this.node.person.generation))
          .fontSize(9)
          .fontColor('#FFFFFF')
          .backgroundColor(Theme.primaryLight)
          .borderRadius(4)
          .padding({ left: 4, right: 4 })
        Text(this.node.person.uid)
          .fontSize(9)
          .fontColor(Theme.inkTertiary)
          .margin({ left: 4 })
        if (this.genChar().length > 0) {
          Text(this.genChar())
            .fontSize(9)
            .fontColor(Theme.gold)
            .margin({ left: 4 })
            .maxLines(1)
        }
      }
      .width('100%')
      .margin({ top: 3 })

      // 关联配偶
      if (this.spouseText().length > 0) {
        Text(this.spouseText())
          .fontSize(9)
          .fontColor(Theme.inkSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
          .onClick((): void => {
            if (this.node.spouse !== null) {
              this.onTapPerson((this.node.spouse as PersonNode).uid);
            }
          })
      }

      if (this.node.children.length > 0 && !this.dense) {
        Text(this.node.children.length.toString() + '子 · 后代' + this.node.descendants.toString() + '人')
          .fontSize(9)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 2 })
          .maxLines(1)
      }
    }
    .width(this.cardWidth)
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .backgroundColor(this.highlight ? Theme.highlightBg : Theme.card)
    .borderRadius(10)
    .border({
      width: this.highlight ? 2 : 1,
      color: this.highlight ? Theme.gold : (this.node.person.gender === '女' ? '#EFC9D5' : '#CFDCEA')
    })
    .shadow({ radius: 6, color: Theme.shadow, offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTapPerson(this.node.uid);
    })
  }
}