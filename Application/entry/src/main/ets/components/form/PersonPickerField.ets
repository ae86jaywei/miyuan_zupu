import { T, uiFontFamily } from '../../service/ScriptService';
import { Theme, Spacing } from '../../theme/Theme';
import { Person } from '../../model/Person';
import { generationLabel } from '../../model/Enums';
import { GenealogyService } from '../../service/GenealogyService';

/** 亲属选择器最多展示的搜索结果条数（避免一次渲染数万节点导致页面卡死） */
const PICKER_MAX_RESULTS: number = 40;

/**
 * 亲属选择字段（搜索式）。
 *
 * 早先的实现把整部族谱（5 万+ 族人）一次性塞进原生 Select：
 * 打开编辑页要创建数万个 SelectOption / 文本节点，返回时又要逐个析构，
 * 真机上主线程阻塞超过 6 秒，被系统看门狗以 THREAD_BLOCK_6S 强杀。
 * 这里改为“点击 → 底部弹层 → 输入关键字 → 最多展示 40 条命中”的搜索选择，
 * 渲染量与族谱规模无关。
 */
@Component
export struct PersonPickerField {
  @Prop label: string = '';
  @Prop hint: string = '';
  @Prop value: string = '';
  /** 性别过滤：'男' / '女' / ''（不限） */
  @Prop genderFilter: string = '';
  /** 需要排除的编号（通常传本人编号，避免选到自己） */
  @Prop excludeUid: string = '';
  @Prop clearable: boolean = false;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onValue: (v: string) => void = (v: string): void => {};
  @State showSheet: boolean = false;
  @State keyword: string = '';
  /** 搜索结果（只在输入变化时算一次，build 内不做全表过滤） */
  @State results: Person[] = [];

  onDark(): void {
    Theme.use(this.darkMode);
  }

  /** 字段上显示的文字：编号能查到时显示“姓名（编号）”，否则原样显示编号 */
  private displayText(): string {
    if (this.value.length === 0) {
      return this.clearable ? '未选择' : '请选择';
    }
    const p: Person | null = GenealogyService.getInstance().getPerson(this.value);
    return p === null ? this.value : p.name + '（' + p.uid + '）';
  }

  private searchPersons(keyword: string): void {
    const k: string = keyword.trim();
    if (k.length === 0) {
      this.results = [];
      return;
    }
    const hits: Person[] = GenealogyService.getInstance().search(k);
    const exclude: string = this.excludeUid.trim().toUpperCase();
    const list: Person[] = [];
    for (let i: number = 0; i < hits.length && list.length < PICKER_MAX_RESULTS; i++) {
      const p: Person = hits[i];
      if (exclude.length > 0 && p.uid.trim().toUpperCase() === exclude) {
        continue;
      }
      if (this.genderFilter.length > 0 && p.gender !== this.genderFilter) {
        continue;
      }
      list.push(p);
    }
    this.results = list;
  }

  private openPicker(): void {
    this.keyword = '';
    this.results = [];
    this.showSheet = true;
  }

  private choose(p: Person): void {
    this.onValue(p.uid);
    this.showSheet = false;
    this.keyword = '';
    this.results = [];
  }

  @Builder
  pickerSheet() {
    Column() {
      TextInput({ text: this.keyword, placeholder: T('输入谱名 / 曾用名 / 唯一ID 搜索') }).fontFamily(uiFontFamily())
        .height(40)
        .fontSize(14)
        .fontColor(Theme.ink)
        .placeholderColor(Theme.inkTertiary)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .onChange((v: string): void => {
          this.keyword = v;
          this.searchPersons(v);
        })

      if (this.keyword.trim().length === 0) {
        Text(T('输入关键字后显示匹配的族人（最多 ' + PICKER_MAX_RESULTS.toString() + ' 条）')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: Spacing.L })
      } else if (this.results.length === 0) {
        Text(T('没有匹配的族人')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: Spacing.L })
      } else {
        List() {
          ForEach(this.results, (p: Person) => {
            ListItem() {
              Row() {
                Column() {
                  Text(T(p.name + '（' + p.uid + '）')).fontFamily(uiFontFamily())
                    .fontSize(14)
                    .fontColor(Theme.ink)
                    .fontWeight(FontWeight.Medium)
                  Text(T(generationLabel(p.generation) + ' · ' + p.gender +
                    (p.alias.length > 0 ? ' · ' + p.alias : ''))).fontFamily(uiFontFamily())
                    .fontSize(11)
                    .fontColor(Theme.inkTertiary)
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (p.uid.trim().toUpperCase() === this.value.trim().toUpperCase()) {
                  Text(T('当前')).fontFamily(uiFontFamily())
                    .fontSize(11)
                    .fontColor(Theme.primary)
                }
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)
            }
            .onClick((): void => {
              this.choose(p);
            })
          }, (p: Person) => p.uid)
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: Spacing.S })
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 0 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.S, bottom: Spacing.L })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text(T(this.label)).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        }
        .width('100%')
        if (this.hint.length > 0) {
          Text(T(this.hint)).fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .width('100%')
            .margin({ top: 1 })
        }
      }
      .width('100%')
      .margin({ bottom: 4 })

      Row() {
        Row() {
          Text(T(this.displayText())).fontFamily(uiFontFamily())
            .fontSize(14)
            .fontColor(this.value.length > 0 ? Theme.ink : Theme.inkTertiary)
            .fontWeight(this.value.length > 0 ? FontWeight.Medium : FontWeight.Normal)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(T('搜索')).fontFamily(uiFontFamily())
            .fontSize(12)
            .fontColor(Theme.primary)
        }
        .layoutWeight(1)
        .height(40)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.openPicker();
        })

        if (this.clearable && this.value.length > 0) {
          Text(T('清除')).fontFamily(uiFontFamily())
            .fontSize(12)
            .fontColor(Theme.inkTertiary)
            .padding({ left: Spacing.M, top: 10, bottom: 10 })
            .onClick((): void => {
              this.onValue('');
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
    .bindSheet($$this.showSheet, this.pickerSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: Theme.paper,
      showClose: true,
      title: { title: T('选择') + this.label }
    })
  }
}