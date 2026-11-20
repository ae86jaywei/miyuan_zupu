import { T, uiFontFamily } from 'common_base';
import { Person } from 'common_base';
import { Theme, Spacing } from 'common_base';
import { generationLabel } from 'common_base';
import { Tag } from 'common_ui';
import { DieJiIndex, DieJiText, DieJiNameRange, DieJiRefOptions } from '../../service/DieJiText';

/** 正文分段：姓名段、括号引用段、普通段 */
class DieJiSpan {
  text: string = '';
  name: boolean = false;
  ref: boolean = false;
  /** 亲属姓名：只加粗，字号仍用正文四号 */
  relative: boolean = false;
}

/** 牒记字号：姓名 小二号 18fp 加粗，引用 五号 10.5fp，其余 四号 14fp（与 PDF 的 pt 一一对应） */
const SIZE_NAME: number = 18;
const SIZE_REF: number = 10.5;
const SIZE_TEXT: number = 14;

/** pos 落在哪个区间内；不在任何区间返回 null */
function rangeAt(list: DieJiNameRange[], pos: number): DieJiNameRange | null {
  for (let i: number = 0; i < list.length; i++) {
    if (pos >= list[i].start && pos < list[i].end) {
      return list[i];
    }
  }
  return null;
}

/**
 * 牒记式谱：按世序逐人编记，一人一条，文字为体，内容详备。
 *
 * 正文由 DieJiText 统一生成（与 PDF / Markdown 共用同一套文言句式），
 * 屏幕只负责排版与交互，避免三端各写一套字段拼接。
 * 排版口径：姓名 18fp 加粗，「（UID）」10.5fp，其余 14fp 常规，段内只用空格断句。
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
    // 屏幕没有页码概念：只写「（F001）」，与 PDF 的「（F001·第2页）」同源同格式
    const opts: DieJiRefOptions = new DieJiRefOptions();
    opts.enabled = true;
    opts.withPage = false;
    if (this.ctx === null) {
      const single: DieJiIndex = new DieJiIndex([this.person]);
      return DieJiText.paragraph(this.person, single, opts);
    }
    return DieJiText.paragraph(this.person, this.ctx, opts);
  }

  /** 把文言正文切成普通段 / 姓名段 / 引用段（段数不设上限，子女多也不会截断） */
  private spans(): DieJiSpan[] {
    const text: string = this.dieText();
    if (text === this.cachedText && this.cachedSpans.length > 0) {
      return this.cachedSpans;
    }
    // 亲属（父母/配偶/子女/岳父）姓名同样 18fp 加粗，需要全谱索引解析
    const names: DieJiNameRange[] = this.ctx === null ?
      DieJiText.nameRanges(this.person, text) : DieJiText.nameRanges(this.person, text, this.ctx);
    const refs: DieJiNameRange[] = DieJiText.refRanges(text);
    const out: DieJiSpan[] = [];
    let pos: number = 0;
    while (pos < text.length) {
      const nameRange: DieJiNameRange | null = rangeAt(names, pos);
      if (nameRange !== null) {
        const s: DieJiSpan = new DieJiSpan();
        s.text = text.substring(nameRange.start, nameRange.end);
        s.name = true;
        s.relative = nameRange.relative;
        out.push(s);
        pos = nameRange.end;
        continue;
      }
      const refRange: DieJiNameRange | null = rangeAt(refs, pos);
      if (refRange !== null) {
        const s: DieJiSpan = new DieJiSpan();
        s.text = text.substring(refRange.start, refRange.end);
        s.ref = true;
        out.push(s);
        pos = refRange.end;
        continue;
      }
      let next: number = text.length;
      for (let i: number = 0; i < names.length; i++) {
        if (names[i].start > pos && names[i].start < next) {
          next = names[i].start;
        }
      }
      for (let i: number = 0; i < refs.length; i++) {
        if (refs[i].start > pos && refs[i].start < next) {
          next = refs[i].start;
        }
      }
      const s: DieJiSpan = new DieJiSpan();
      s.text = text.substring(pos, next);
      out.push(s);
      pos = next;
    }
    this.cachedText = text;
    this.cachedSpans = out;
    return out;
  }

  build() {
    Column() {
      Row() {
        Text(T(generationLabel(this.person.generation))).fontFamily(uiFontFamily())
          .fontSize(11.5)
          .fontColor(this.highlight ? Theme.highlightAccent : Theme.gold)
        Blank()
        Tag({
          text: this.person.lifeStatus,
          color: this.person.lifeStatus === '已故' ? Theme.deceased : Theme.alive,
          bg: this.person.lifeStatus === '已故' ? Theme.field : Theme.aliveBg
        })
        if (this.person.graveLat !== 0) {
          Tag({ text: '有墓葬定位', color: Theme.alive, bg: Theme.aliveBg }).margin({ left: 6 })
        }
      }
      .width('100%')

      Text() {
        ForEach(this.spans(), (s: DieJiSpan, idx: number) => {
          Span(T(s.text)).fontFamily(uiFontFamily())
            .fontSize(s.name ? (s.relative ? SIZE_TEXT : SIZE_NAME) : (s.ref ? SIZE_REF : SIZE_TEXT))
            .fontWeight(s.name ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(s.name ?
              (s.relative ? Theme.ink :
                (this.person.gender === '女' ?
                  (this.highlight ? Theme.highlightFemale : Theme.female) :
                  (this.highlight ? Theme.highlightAccent : Theme.primary))) :
              (s.ref ? (this.highlight ? Theme.highlightMuted : Theme.inkTertiary) : Theme.ink))
        }, (s: DieJiSpan, idx: number) => idx.toString() + '_' + s.text)
      }
      .fontFamily(uiFontFamily())
      .fontSize(SIZE_TEXT)
      .lineHeight(30)
      .fontColor(Theme.ink)
      .margin({ top: 6 })
      .width('100%')
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(this.highlight ? Theme.selectedBg : Theme.card)
    .borderRadius(12)
    .border({
      width: this.highlight ? 1.5 : 0.5,
      color: this.highlight ? Theme.gold : Theme.line,
      style: BorderStyle.Dashed
    })
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTapPerson(this.person.uid);
    })
  }
}