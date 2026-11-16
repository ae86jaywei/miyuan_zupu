import { T, uiFontFamily } from '../../service/ScriptService';
import { Person } from '../../model/Person';
import { Theme, Spacing } from '../../theme/Theme';
import { generationLabel } from '../../model/Enums';
import { Tag } from '../Tag';
import { DieJiIndex, DieJiText } from '../../service/DieJiText';

/**
 * 牒记式谱：按世序逐人编记，一人一条，文字为体，内容详备。
 *
 * 正文由 DieJiText 统一生成（与 PDF / Markdown 共用同一套文言句式），
 * 屏幕只负责排版与交互，避免三端各写一套字段拼接。
 */
@Component
export struct DieRecord {
  /** 大列表场景下逐人深拷贝 Person 开销巨大，改用普通成员传引用 */
  person: Person = new Person();
  /** 全谱关系索引：由列表容器一次构建、逐条复用，避免每张卡片重建 */
  ctx: DieJiIndex | null = null;
  @Prop index: number = 0;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;

  onDark(): void {
    Theme.use(this.darkMode);
  }
  @Prop showPrivate: boolean = false;
  @Prop highlight: boolean = false;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  private dieText(): string {
    if (this.ctx === null) {
      const single: DieJiIndex = new DieJiIndex([this.person]);
      return DieJiText.paragraph(this.person, single);
    }
    return DieJiText.paragraph(this.person, this.ctx);
  }

  build() {
    Column() {
      Row() {
        Text(T(generationLabel(this.person.generation))).fontFamily(uiFontFamily())
          .fontSize(11.5)
          .fontColor(Theme.gold)
        Text(T('（' + this.person.uid + '）')).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ left: 4 })
        Blank()
        Tag({
          text: this.person.lifeStatus,
          color: this.person.lifeStatus === '已故' ? Theme.deceased : Theme.alive,
          bg: this.person.lifeStatus === '已故' ? Theme.field : '#E6F3EC'
        })
        if (this.person.graveLat !== 0) {
          Tag({ text: '有墓葬定位', color: Theme.alive, bg: '#E6F3EC' }).margin({ left: 6 })
        }
      }
      .width('100%')

      Text(T(this.dieText())).fontFamily(uiFontFamily())
        .fontSize(14)
        .lineHeight(24)
        .fontColor(Theme.ink)
        .margin({ top: 6 })
        .width('100%')
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(this.highlight ? Theme.highlightBg : Theme.card)
    .borderRadius(12)
    .border({ width: 0.5, color: Theme.line, style: BorderStyle.Dashed })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTapPerson(this.person.uid);
    })
  }
}