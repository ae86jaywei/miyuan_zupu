import { T, uiFontFamily } from '../../service/ScriptService';
import { Person } from '../../model/Person';
import { Theme, Spacing } from '../../theme/Theme';
import { generationLabel } from '../../model/Enums';
import { Tag } from '../Tag';
import { DieJiIndex, DieJiText, DieJiNameRange } from '../../service/DieJiText';

/** 正文分段：姓名段用 30 号加粗，其余保持 14 号 */
class DieJiSpan {
  text: string = '';
  name: boolean = false;
}

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
  private cachedText: string = '';
  private cachedSpans: DieJiSpan[] = [];
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

  /** 把文言正文拆成普通段与姓名段，姓名段加粗放大 */
  private spans(): DieJiSpan[] {
    const text: string = this.dieText();
    if (text === this.cachedText && this.cachedSpans.length > 0) {
      return this.cachedSpans;
    }
    const ranges: DieJiNameRange[] = DieJiText.nameRanges(this.person, text);
    const out: DieJiSpan[] = [];
    let pos: number = 0;
    for (let i: number = 0; i < ranges.length; i++) {
      const r: DieJiNameRange = ranges[i];
      if (r.start > pos) {
        const plain: DieJiSpan = new DieJiSpan();
        plain.text = text.substring(pos, r.start);
        out.push(plain);
      }
      const name: DieJiSpan = new DieJiSpan();
      name.text = text.substring(r.start, r.end);
      name.name = true;
      out.push(name);
      pos = r.end;
    }
    if (pos < text.length) {
      const tail: DieJiSpan = new DieJiSpan();
      tail.text = text.substring(pos);
      out.push(tail);
    }
    this.cachedText = text;
    this.cachedSpans = out;
    return out;
  }

  private spanAt(i: number): DieJiSpan {
    const arr: DieJiSpan[] = this.spans();
    return i < arr.length ? arr[i] : new DieJiSpan();
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

      Text() {
        if (this.spanAt(0).text.length > 0) {
          Span(T(this.spanAt(0).text)).fontFamily(uiFontFamily())
            .fontSize(this.spanAt(0).name ? 30 : 14)
            .fontWeight(this.spanAt(0).name ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.spanAt(0).name ?
              (this.person.gender === '女' ? Theme.female : Theme.primary) : Theme.ink)
        }
        if (this.spanAt(1).text.length > 0) {
          Span(T(this.spanAt(1).text)).fontFamily(uiFontFamily())
            .fontSize(this.spanAt(1).name ? 30 : 14)
            .fontWeight(this.spanAt(1).name ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.spanAt(1).name ?
              (this.person.gender === '女' ? Theme.female : Theme.primary) : Theme.ink)
        }
        if (this.spanAt(2).text.length > 0) {
          Span(T(this.spanAt(2).text)).fontFamily(uiFontFamily())
            .fontSize(this.spanAt(2).name ? 30 : 14)
            .fontWeight(this.spanAt(2).name ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.spanAt(2).name ?
              (this.person.gender === '女' ? Theme.female : Theme.primary) : Theme.ink)
        }
        if (this.spanAt(3).text.length > 0) {
          Span(T(this.spanAt(3).text)).fontFamily(uiFontFamily())
            .fontSize(this.spanAt(3).name ? 30 : 14)
            .fontWeight(this.spanAt(3).name ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.spanAt(3).name ?
              (this.person.gender === '女' ? Theme.female : Theme.primary) : Theme.ink)
        }
        if (this.spanAt(4).text.length > 0) {
          Span(T(this.spanAt(4).text)).fontFamily(uiFontFamily())
            .fontSize(this.spanAt(4).name ? 30 : 14)
            .fontWeight(this.spanAt(4).name ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.spanAt(4).name ?
              (this.person.gender === '女' ? Theme.female : Theme.primary) : Theme.ink)
        }
      }
      .fontFamily(uiFontFamily())
      .fontSize(14)
      .lineHeight(34)
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