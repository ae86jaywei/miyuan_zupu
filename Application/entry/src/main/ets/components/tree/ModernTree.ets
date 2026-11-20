import { T, uiFontFamily } from 'common_base';
import { SR } from '../../service/ServiceRegistry';

import { Person } from 'common_base';
import { Theme, Spacing } from 'common_base';
import { PersonAvatar } from 'common_ui';
import { Tag } from 'common_ui';
import { generationLabel } from 'common_base';
import { lifeSpan } from 'common_dateutil';
import { GenealogyService } from '../../service/GenealogyService';
import { FlatListSource } from 'common_base';
import { TreePerf } from 'common_base';

class ModernRow {
  people: Person[];
  generation: number;
  label: string;
  start: number;
  count: number;
  first: boolean;
  last: boolean;
  lastOverall: boolean = false;

  constructor(people: Person[], generation: number, label: string,
    start: number, count: number, first: boolean, last: boolean) {
    this.people = people;
    this.generation = generation;
    this.label = label;
    this.start = start;
    this.count = count;
    this.first = first;
    this.last = last;
  }

  values(): Person[] {
    return this.people.slice(this.start, this.start + this.count);
  }
}

/**
 * 现代创新式：卡片时间轴。
 * 以世代为轴，世代节点纵向排列，每个世代内以横向卡片（可换行）展示族人。
 */
@Component
export struct ModernTree {
  @Prop @Watch('onDataChanged') layoutVersion: number = 0;
  @Prop @Watch('onLayoutChanged') windowWidth: number = 360;
  @Prop @Watch('onHighlightChanged') highlightUid: string = '';
  /** 查找定位请求：收到后滚动到该族人所在行 */
  @Prop @Watch('onFocusChanged') focusUid: string = '';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  @Prop @Watch('onLayoutChanged') minCardWidth: number = 150;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  private rows: ModernRow[] = [];
  private currentColumns: number = 0;
  private rowSource: FlatListSource<ModernRow> = new FlatListSource<ModernRow>();
  private scroller: Scroller = new Scroller();
  /** 跳转索引：uid -> 行号，避免跳转时线性搜索 */
  private uidToRow: Map<string, number> = new Map<string, number>();
  /** 上一次高亮人物：只刷新新旧两行，避免整表重载 */
  private lastHighlightUid: string = '';

  aboutToAppear(): void {
    this.rebuildRows();
  }

  onDataChanged(): void {
    this.rebuildRows();
  }

  /** 只刷新新旧高亮所在行；整表 setData 会让 LazyForEach 重载并丢失滚动测量，跳转明显变慢 */
  onHighlightChanged(): void {
    const prev: string = this.lastHighlightUid.length === 0
      ? '' : this.lastHighlightUid.toUpperCase();
    const cur: string = this.highlightUid.length === 0 ? '' : this.highlightUid.toUpperCase();
    this.lastHighlightUid = this.highlightUid;
    if (prev.length > 0 && prev !== cur) {
      const prevRow: number = this.uidToRow.get(prev) ?? -1;
      if (prevRow >= 0) {
        this.rowSource.notifyItemChanged(prevRow);
      }
    }
    if (cur.length > 0) {
      const curRow: number = this.uidToRow.get(cur) ?? -1;
      if (curRow >= 0) {
        this.rowSource.notifyItemChanged(curRow);
      }
    }
  }

  /** 定位到目标族人：找到包含它的行并居中滚动（使用索引加速） */
  onFocusChanged(): void {
    if (this.focusUid.length === 0) {
      return;
    }
    const target: string = this.focusUid.toUpperCase();
    // 使用索引查找
    const row: number = this.uidToRow.get(target) ?? -1;
    if (row >= 0 && row < this.rows.length) {
      // smooth=false：跨数千行做平滑动画会逐项加载中间行，是跳转卡顿的主因
      this.scroller.scrollToIndex(row, false, ScrollAlign.CENTER);
      return;
    }
    // 索引未命中，回退到线性搜索并更新索引
    for (let i: number = 0; i < this.rows.length; i = i + 1) {
      const row: ModernRow = this.rows[i];
      for (let k: number = row.start; k < row.start + row.count; k = k + 1) {
        if (row.people[k].uid.toUpperCase() === target) {
          this.uidToRow.set(target, i);
          this.scroller.scrollToIndex(i, false, ScrollAlign.CENTER);
          return;
        }
      }
    }
  }

  onLayoutChanged(): void {
    if (this.columnCount() !== this.currentColumns) {
      this.rebuildRows();
    }
  }

  onDark(): void {
    Theme.use(this.darkMode);
  }

  private columnCount(): number {
    // 可用宽度要扣除页面左右留白、时间轴与左间距，否则会把列数算多，导致一行放不下而出现空位
    const usable: number = this.windowWidth - 32 - 16 - Spacing.M;
    return Math.max(1, Math.min(4, Math.floor(usable / (this.minCardWidth + 10))));
  }

  private rebuildRows(): void {
    TreePerf.begin('modern_rows');
    const map: Map<number, Person[]> = SR.genealogy().groupByGeneration();
    const generations: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    const columns: number = this.columnCount();
    this.currentColumns = columns;
    const rows: ModernRow[] = [];
    generations.forEach((generation: number): void => {
      const people: Person[] = map.get(generation) as Person[];
      const label: string = generationLabel(generation);
      for (let start: number = 0; start < people.length; start = start + columns) {
        const count: number = Math.min(columns, people.length - start);
        rows.push(new ModernRow(people, generation, label, start, count,
          start === 0, start + count >= people.length));
      }
    });
    if (rows.length > 0) {
      rows[rows.length - 1].lastOverall = true;
    }
    this.rows = rows;
    this.rowSource.setData(rows);
    // 构建跳转索引：uid -> 行号
    this.buildUidIndex();
    this.lastHighlightUid = this.highlightUid;
    TreePerf.end('modern_rows', 'generations=' + generations.length.toString() +
      ' rows=' + rows.length.toString());
  }

  /** 构建跳转索引：uid -> 行号 */
  private buildUidIndex(): void {
    this.uidToRow.clear();
    for (let i: number = 0; i < this.rows.length; i = i + 1) {
      const row: ModernRow = this.rows[i];
      for (let k: number = row.start; k < row.start + row.count; k = k + 1) {
        this.uidToRow.set(row.people[k].uid.toUpperCase(), i);
      }
    }
  }

  private spouseText(p: Person): string {
    return SR.genealogy().spouseTextOf(p.uid);
  }

  @Builder
  PersonCard(p: Person) {
    Column() {
      Row() {
        PersonAvatar({ person: p, avatarSize: 36, showRing: p.uid === this.highlightUid })
        Column() {
          Text(T(p.name)).fontFamily(uiFontFamily())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(p.gender === '女' ? Theme.female : Theme.ink)
            .maxLines(1)
          Text(T(lifeSpan(p.birthDate, p.deathDate, p.lifeStatus).length > 0 ?
            lifeSpan(p.birthDate, p.deathDate, p.lifeStatus) : p.uid)).fontFamily(uiFontFamily())
            .fontSize(10)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: Spacing.S })
      }
      .width('100%')

      Row() {
        Tag({ text: generationLabel(p.generation), color: Theme.onPrimary, bg: Theme.primaryLight, dense: true })
        if (p.generationChar.length > 0) {
          Tag({ text: '字派 ' + p.generationChar, color: Theme.gold, bg: Theme.highlightBg, dense: true }).margin({ left: 4 })
        }
        if (p.occupation.length > 0) {
          Tag({ text: p.occupation, color: Theme.inkSecondary, bg: Theme.field, dense: true }).margin({ left: 4 })
        }
      }
      .width('100%')
      .margin({ top: 6 })

      if (this.spouseText(p).length > 0) {
        Text(T(this.spouseText(p))).fontFamily(uiFontFamily())
          .fontSize(10)
          .fontColor(Theme.inkSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }

      if (p.biography.length > 0) {
        Text(T(p.biography)).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
          .width('100%')
      }
    }
    .padding(Spacing.M)
    .backgroundColor(p.uid === this.highlightUid ? Theme.highlightBg : Theme.card)
    .borderRadius(14)
    .border({ width: 0.5, color: p.uid === this.highlightUid ? Theme.gold : Theme.line })
    .shadow({ radius: 8, color: Theme.shadow, offsetY: 2 })
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .onClick((): void => {
      this.onTapPerson(p.uid);
    })
  }

  /** 该行是否含当前高亮人物：只有新旧高亮行需要重建，避免点选时整树刷新 */
  private rowHighlighted(row: ModernRow): boolean {
    if (this.highlightUid.length === 0) {
      return false;
    }
    const values: Person[] = row.values();
    for (let i: number = 0; i < values.length; i = i + 1) {
      if (values[i].uid === this.highlightUid) {
        return true;
      }
    }
    return false;
  }

  build() {
    Stack() {
      // 贯穿时间轴只画一条竖线：不再让每个 ListItem 用 height('100%') 撑高，避免产生空位
      Column() {
        Row()
          .width(2)
          .layoutWeight(1)
          .backgroundColor(Theme.goldLight)
      }
      .width(2)
      .height('100%')
      .margin({ left: 7 })
      .padding({ top: 24, bottom: 24 })

      List({ scroller: this.scroller }) {
        LazyForEach(this.rowSource, (row: ModernRow) => {
          ListItem() {
            Row() {
              Column() {
                if (row.first) {
                  Stack() {
                    Circle({ width: 14, height: 14 }).fill(Theme.primary)
                    Circle({ width: 6, height: 6 }).fill(Color.White)
                  }
                }
              }
              .width(16)
              .alignItems(HorizontalAlign.Center)

              Column() {
                if (row.first) {
                  Row() {
                    Text(T(row.label)).fontFamily(uiFontFamily())
                      .fontSize(13)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Theme.primary)
                    Text(T(row.people.length.toString() + ' 人')).fontFamily(uiFontFamily())
                      .fontSize(11)
                      .fontColor(Theme.inkTertiary)
                      .margin({ left: 6 })
                  }
                  .width('100%')
                  .margin({ bottom: Spacing.S })
                }

                if (row.count === 1) {
                  // 单列时直接渲染，避免 Flex 换行测量在 List 中产生空位
                  Column() {
                    this.PersonCard(row.values()[0])
                  }
                  .margin({ bottom: 12 })
                } else {
                  Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
                    ForEach(row.values(), (p: Person) => {
                      Column() {
                        this.PersonCard(p)
                      }
                      .flexGrow(1)
                      .flexBasis(this.minCardWidth)
                      .constraintSize({ minWidth: this.minCardWidth })
                      .padding({ right: 10, bottom: 12 })
                    }, (p: Person) => 'mc_' + this.layoutVersion.toString() + '_' + p.uid)
                  }
                  .width('100%')
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .padding({ left: Spacing.M, bottom: row.last ? Spacing.XL : 0 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
        }, (row: ModernRow) => 'mg_' + this.layoutVersion.toString() + '_' +
          row.generation.toString() + '_' + row.start.toString() + '_' + row.count.toString() +
          (this.rowHighlighted(row) ? '_hl' : ''))
      }
      .width('100%')
      .height(LayoutPolicy.matchParent)
      .cachedCount(this.rows.length > 20 ? 2 : 3)
      .contentEndOffset(16)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .height('100%')
  }
}
