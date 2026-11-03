import { PersonNode } from '../../model/PersonNode';
import { Theme } from '../../theme/Theme';
import { PersonAvatar } from '../PersonAvatar';
import { generationLabel } from '../../model/Enums';
import { GenealogyService } from '../../service/GenealogyService';
import { FlatListSource } from '../../util/FlatListSource';
import { TreePerf } from '../../util/TreePerf';

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
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  @Prop @Watch('onChanged') compact: boolean = true;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  private rows: PagodaRow[] = [];
  private rowSource: FlatListSource<PagodaRow> = new FlatListSource<PagodaRow>();

  aboutToAppear(): void {
    this.rebuildRows();
  }

  onDark(): void {
    Theme.use(this.darkMode);
  }

  onChanged(): void {
    this.rebuildRows();
  }

  onHighlightChanged(): void {
    this.rowSource.setData(this.rows);
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
    GenealogyService.getInstance().getRoots().forEach((root: PersonNode): void => {
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
    TreePerf.end('pagoda_rows', 'people=' + count.toString() +
      ' generations=' + generations.length.toString() + ' rows=' + rows.length.toString());
  }

  build() {
    List() {
      LazyForEach(this.rowSource, (row: PagodaRow) => {
        ListItem() {
          Column() {
            if (row.first) {
              Row() {
                Text(generationLabel(row.generation) + ' · ' + row.nodes.length.toString() + '人')
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

                  Text(node.person.name)
                    .fontSize(this.compact ? 11 : 12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(node.person.gender === '女' ? Theme.female : Theme.ink)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                    .width(this.compact ? 56 : 68)
                    .textAlign(TextAlign.Center)

                  Text(generationLabel(node.person.generation))
                    .fontSize(8)
                    .fontColor('#FFFFFF')
                    .backgroundColor(node.person.gender === '女' ? Theme.female : Theme.primaryLight)
                    .borderRadius(3)
                    .padding({ left: 3, right: 3 })
                    .margin({ top: 1 })

                  if (node.spouseText().length > 0) {
                    Text(node.spouseText())
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
      }, (row: PagodaRow) => 'gen_' + this.layoutVersion.toString() + '_' + this.highlightUid + '_' +
        row.generation.toString() + '_' + row.start.toString() + '_' + row.count.toString())
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .cachedCount(this.rows.length > 20 ? 2 : 3)
    .contentEndOffset(16)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.None)
  }
}
