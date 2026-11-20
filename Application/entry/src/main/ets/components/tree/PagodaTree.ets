import { T, uiFontFamily } from 'common_base';
import { SR } from '../../service/ServiceRegistry';

import { PersonNode } from 'common_base';
import { Theme } from 'common_base';
import { PersonAvatar } from 'common_ui';
import { generationLabel } from 'common_base';
import { GenealogyService } from '../../service/GenealogyService';
import { FlatListSource } from 'common_base';
import { TreePerf } from 'common_base';

class PagodaRow {
  nodes: PersonNode[];
  generation: number;
  generationIndex: number;
  start: number;
  count: number;
  first: boolean;
  last: boolean;

  constructor(nodes: PersonNode[], generation: number, generationIndex: number,
    start: number, count: number, first: boolean, last: boolean) {
    this.nodes = nodes;
    this.generation = generation;
    this.generationIndex = generationIndex;
    this.start = start;
    this.count = count;
    this.first = first;
    this.last = last;
  }

  values(): PersonNode[] {
    return this.nodes.slice(this.start, this.start + this.count);
  }
}

/**
 * 宝塔式谱：上窄下宽，始祖居塔尖，子孙逐代向两侧对称展开。
 * 每一代为一个“层”，层内成员平均分布，层与层之间以金色腰线分割。
 *
 * 不接收 PersonNode[][] 作为 @Prop（环状结构会被深拷贝），
 * 改为接收宗支 uid 列表，在组件内按 version 重建分层数据。
 */
@Component
export struct PagodaTree {
  @Prop @Watch('onChanged') rootUids: string[] = [];
  @Prop @Watch('onChanged') layoutVersion: number = 0;
  @Prop @Watch('onHighlightChanged') highlightUid: string = '';
  /** 查找定位请求：收到后滚动到该族人所在行 */
  @Prop @Watch('onFocusChanged') focusUid: string = '';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  @Prop @Watch('onChanged') compact: boolean = true;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  private rows: PagodaRow[] = [];
  private rowSource: FlatListSource<PagodaRow> = new FlatListSource<PagodaRow>();
  private scroller: Scroller = new Scroller();
  /** 跳转索引：uid -> 行号，避免跳转时线性搜索 */
  private uidToRow: Map<string, number> = new Map<string, number>();
  /** 上一次高亮人物：只刷新新旧两行，避免整表重载 */
  private lastHighlightUid: string = '';

  aboutToAppear(): void {
    this.rebuildRows();
  }

  onDark(): void {
    Theme.use(this.darkMode);
  }

  onChanged(): void {
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
      const row: PagodaRow = this.rows[i];
      for (let k: number = row.start; k < row.start + row.count; k = k + 1) {
        if (row.nodes[k].uid.toUpperCase() === target) {
          this.uidToRow.set(target, i);
          this.scroller.scrollToIndex(i, false, ScrollAlign.CENTER);
          return;
        }
      }
    }
  }

  private rebuildRows(): void {
    TreePerf.begin('pagoda_rows');
    if (this.rootUids.length === 0) {
      this.rows = [];
      this.rowSource.setData(this.rows);
      TreePerf.end('pagoda_rows', 'generations=0');
      return;
    }
    const generations: PersonNode[][] = [];
    const seen: Set<string> = new Set<string>();
    let count: number = 0;
    const walk = (node: PersonNode): void => {
      const index: number = node.person.generation - 1;
      while (generations.length <= index) {
        generations.push([]);
      }
      if (!seen.has(node.uid)) {
        seen.add(node.uid);
        generations[index].push(node);
        count = count + 1;
      }
      node.children.forEach((child: PersonNode): void => {
        walk(child);
      });
    };
    const rootUidSet: Set<string> = new Set<string>();
    this.rootUids.forEach((uid: string): void => {
      rootUidSet.add(uid);
    });
    SR.genealogy().getRoots().forEach((root: PersonNode): void => {
      if (rootUidSet.has(root.uid)) {
        walk(root);
      }
    });
    const chunkSize: number = this.compact ? 4 : 6;
    const rows: PagodaRow[] = [];
    generations.forEach((nodes: PersonNode[], generationIndex: number): void => {
      if (nodes.length === 0) {
        return;
      }
      const generation: number = nodes[0].person.generation;
      for (let start: number = 0; start < nodes.length; start = start + chunkSize) {
        const countInRow: number = Math.min(chunkSize, nodes.length - start);
        rows.push(new PagodaRow(nodes, generation, generationIndex, start, countInRow,
          start === 0, start + countInRow >= nodes.length));
      }
    });
    this.rows = rows;
    this.rowSource.setData(rows);
    // 构建跳转索引：uid -> 行号
    this.buildUidIndex();
    this.lastHighlightUid = this.highlightUid;
    TreePerf.end('pagoda_rows', 'people=' + count.toString() +
      ' generations=' + generations.length.toString() + ' rows=' + rows.length.toString());
  }

  /** 构建跳转索引：uid -> 行号 */
  private buildUidIndex(): void {
    this.uidToRow.clear();
    for (let i: number = 0; i < this.rows.length; i = i + 1) {
      const row: PagodaRow = this.rows[i];
      for (let k: number = row.start; k < row.start + row.count; k = k + 1) {
        this.uidToRow.set(row.nodes[k].uid.toUpperCase(), i);
      }
    }
  }

  /** 该行是否含当前高亮人物：只有新旧高亮行需要重建，避免点选时整树刷新 */
  private rowHighlighted(row: PagodaRow): boolean {
    if (this.highlightUid.length === 0) {
      return false;
    }
    const values: PersonNode[] = row.values();
    for (let i: number = 0; i < values.length; i = i + 1) {
      if (values[i].uid === this.highlightUid) {
        return true;
      }
    }
    return false;
  }

  build() {
    List({ scroller: this.scroller }) {
      LazyForEach(this.rowSource, (row: PagodaRow) => {
        ListItem() {
          Column() {
            if (row.first) {
              Row() {
                Text(T(generationLabel(row.generation) + ' · ' + row.nodes.length.toString() + '人')).fontFamily(uiFontFamily())
                  .fontSize(10)
                  .fontColor(Theme.primary)
                  .backgroundColor(Theme.highlightBg)
                  .borderRadius(8)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .margin({ bottom: 4 })
            }

            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
              ForEach(row.values(), (node: PersonNode) => {
                Column() {
                  Stack() {
                    PersonAvatar({
                      person: node.person,
                      avatarSize: this.compact ? 22 : 26,
                      showRing: node.uid === this.highlightUid
                    })
                  }
                  .width(this.compact ? 24 : 28)
                  .height(this.compact ? 24 : 28)

                  Text(T(node.person.name)).fontFamily(uiFontFamily())
                    .fontSize(this.compact ? 11 : 12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(node.person.gender === '女' ? Theme.female : Theme.ink)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                    .width(this.compact ? 56 : 68)
                    .textAlign(TextAlign.Center)

                  Text(T(generationLabel(node.person.generation))).fontFamily(uiFontFamily())
                    .fontSize(8)
                    .fontColor(Theme.onPrimary)
                    .backgroundColor(node.person.gender === '女' ? Theme.female : Theme.primaryLight)
                    .borderRadius(3)
                    .padding({ left: 3, right: 3 })
                    .margin({ top: 1 })

                  if (node.spouseText().length > 0) {
                    Text(T(node.spouseText())).fontFamily(uiFontFamily())
                      .fontSize(8)
                      .fontColor(Theme.female)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width(this.compact ? 56 : 68)
                      .textAlign(TextAlign.Center)
                      .margin({ top: 1 })
                      .onClick((): void => {
                        if (node.spouse !== null) {
                          this.onTapPerson((node.spouse as PersonNode).uid);
                        }
                      })
                  }
                }
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 4, bottom: 4, left: 2, right: 2 })
                .backgroundColor(node.uid === this.highlightUid ? Theme.highlightBg : Color.Transparent)
                .borderRadius(8)
                .onClick((): void => {
                  this.onTapPerson(node.uid);
                })
              }, (node: PersonNode) => 'pg_' + this.layoutVersion.toString() + '_' + node.uid)
            }
            .width('100%')

            if (row.last) {
              Row()
                .width((70 + Math.min(row.generationIndex * 6, 30)).toString() + '%')
                .height(1)
                .backgroundColor(Theme.goldLight)
                .margin({ top: 6, bottom: 6 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
      }, (row: PagodaRow) => 'gen_' + this.layoutVersion.toString() + '_' +
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
}
