import { T, uiFontFamily } from '../../service/ScriptService';
import { Person } from 'common_base';
import { Theme } from 'common_base';
import { generationLabel } from 'common_base';
import { compactUid } from 'common_base';

/**
 * 欧式 / 苏式 / 宝塔式谱系图中的人物小卡片。
 *
 * 只接收扁平的 Person 与预先算好的展示字段，不接收 PersonNode：
 * PersonNode 的 father/mother/spouse/children 互为引用，作为 @Prop 会被深拷贝并递归爆栈。
 */
@Component
export struct TreeMiniCard {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
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
  /** 长按卡片：打开族人详情（点击只做选中高亮） */
  onLongPressPerson: (uid: string) => void = (uid: string): void => {};
  /** 鼠标悬浮提示：桌面/2in1 上显示「长按显示族人详情」 */
  @State tipVisible: boolean = false;

  private genChar(): string {
    return this.person.generationChar.length > 0 ? this.person.generationChar + '字' : '';
  }

  /** 角标文案：已故→故，失联/不详照原样显示，便于一眼区分在世状态 */
  private statusText(): string {
    if (this.person.lifeStatus === '已故') {
      return '故';
    }
    if (this.person.lifeStatus === '失联') {
      return '失联';
    }
    if (this.person.lifeStatus === '不详') {
      return '不详';
    }
    return '';
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
        Text(T(this.person.name)).fontFamily(uiFontFamily())
          .fontSize(this.dense ? 13 : 14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.person.gender === '女' ? Theme.female : Theme.ink)
          .lineHeight(this.nameLineHeight())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.genChar().length > 0) {
          Text(T(this.genChar())).fontFamily(uiFontFamily())
            .fontSize(9)
            .lineHeight(this.infoLineHeight())
            .fontColor(Theme.gold)
            .margin({ left: 2 })
            .maxLines(1)
            .flexShrink(0)
        }
        if (this.statusText().length > 0) {
          Text(T(this.statusText())).fontFamily(uiFontFamily())
            .fontSize(9)
            .lineHeight(this.infoLineHeight())
            .fontColor(this.person.lifeStatus === '已故' ? Theme.deceased : Theme.lost)
            .backgroundColor(this.person.lifeStatus === '已故' ? Theme.field : Color.Transparent)
            .borderRadius(3)
            .padding({ left: this.person.lifeStatus === '已故' ? 3 : 0, right: 3 })
            .margin({ left: 2 })
            .flexShrink(0)
        }
      }
      .width('100%')
      .height(this.nameLineHeight())

      // 世代 + 唯一ID + 字派
      Row() {
        Text(T(generationLabel(this.person.generation))).fontFamily(uiFontFamily())
          .fontSize(9)
          .lineHeight(this.infoLineHeight())
          .fontColor(Theme.onPrimary)
          .backgroundColor(Theme.primaryLight)
          .borderRadius(4)
          .padding({ left: 4, right: 4 })
          .flexShrink(0)
        Text(T(compactUid(this.person.uid))).fontFamily(uiFontFamily())
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
        Text(T(this.spouseText)).fontFamily(uiFontFamily())
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
        Text(T(this.childCount.toString() + '子 · 后代' + this.descendants.toString() + '人')).fontFamily(uiFontFamily())
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
      color: this.highlight ? Theme.gold : (this.person.gender === '女' ? Theme.femaleLine : Theme.maleLine)
    })
    // 兜底：卡片高度由谱式布局固定，任何一行都不允许画到卡片外
    .clip(true)
    .shadow({ radius: 6, color: Theme.shadow, offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTapPerson(this.person.uid);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction((): void => {
          this.onLongPressPerson(this.person.uid);
        })
    )
    .onHover((isHover: boolean): void => {
      this.tipVisible = isHover;
    })
    .bindPopup(this.tipVisible, {
      message: T('长按显示族人详情'),
      placement: Placement.Top,
      enableArrow: true,
      autoCancel: false
    })
  }
}
