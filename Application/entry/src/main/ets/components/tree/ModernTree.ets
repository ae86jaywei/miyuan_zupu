import { Person } from '../../model/Person';
import { Theme, Spacing } from '../../theme/Theme';
import { PersonAvatar } from '../PersonAvatar';
import { Tag } from '../Tag';
import { generationLabel } from '../../model/Enums';
import { lifeSpan } from '../../util/DateUtil';
import { GenealogyService } from '../../service/GenealogyService';
import { FlatListSource } from '../../util/FlatListSource';
import { TreePerf } from '../../util/TreePerf';

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
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  @Prop @Watch('onLayoutChanged') minCardWidth: number = 150;
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  private rows: ModernRow[] = [];
  private currentColumns: number = 0;
  private rowSource: FlatListSource<ModernRow> = new FlatListSource<ModernRow>();

  aboutToAppear(): void {
    this.rebuildRows();
  }

  onDataChanged(): void {
    this.rebuildRows();
  }

  onHighlightChanged(): void {
    this.rowSource.setData(this.rows);
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
    return Math.max(1, Math.min(4, Math.floor((this.windowWidth - 32) / (this.minCardWidth + 10))));
  }

  private rebuildRows(): void {
    TreePerf.begin('modern_rows');
    const map: Map<number, Person[]> = GenealogyService.getInstance().groupByGeneration();
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
    TreePerf.end('modern_rows', 'generations=' + generations.length.toString() +
      ' rows=' + rows.length.toString());
  }

  private spouseText(p: Person): string {
    return GenealogyService.getInstance().spouseTextOf(p.uid);
  }

  @Builder
  PersonCard(p: Person) {
    Column() {
      Row() {
        PersonAvatar({ person: p, avatarSize: 36, showRing: p.uid === this.highlightUid })
        Column() {
          Text(p.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(p.gender === '女' ? Theme.female : Theme.ink)
            .maxLines(1)
          Text(lifeSpan(p.birthDate, p.deathDate, p.lifeStatus).length > 0 ?
            lifeSpan(p.birthDate, p.deathDate, p.lifeStatus) : p.uid)
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
        Tag({ text: generationLabel(p.generation), color: '#FFFFFF', bg: Theme.primaryLight, dense: true })
        if (p.generationChar.length > 0) {
          Tag({ text: '字派 ' + p.generationChar, color: Theme.gold, bg: '#FBF4E2', dense: true }).margin({ left: 4 })
        }
        if (p.occupation.length > 0) {
          Tag({ text: p.occupation, color: Theme.inkSecondary, bg: Theme.field, dense: true }).margin({ left: 4 })
        }
      }
      .width('100%')
      .margin({ top: 6 })

      if (this.spouseText(p).length > 0) {
        Text(this.spouseText(p))
          .fontSize(10)
          .fontColor(Theme.inkSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }

      if (p.biography.length > 0) {
        Text(p.biography)
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
    .flexGrow(1)
    .flexBasis(this.minCardWidth)
    .constraintSize({ minWidth: this.minCardWidth })
    .onClick((): void => {
      this.onTapPerson(p.uid);
    })
  }

  build() {
    List() {
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
              Row()
                .width(2)
                .layoutWeight(1)
                .backgroundColor(row.lastOverall ? Color.Transparent : Theme.goldLight)
            }
            .width(16)
            .height('100%')
            .alignItems(HorizontalAlign.Center)

            Column() {
              if (row.first) {
                Row() {
                  Text(row.label)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Theme.primary)
                  Text(row.people.length.toString() + ' 人')
                    .fontSize(11)
                    .fontColor(Theme.inkTertiary)
                    .margin({ left: 6 })
                }
                .width('100%')
                .margin({ bottom: Spacing.S })
              }

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
                ForEach(row.values(), (p: Person) => {
                  Column() {
                    this.PersonCard(p)
                  }
                  .padding({ right: 10, bottom: 10 })
                }, (p: Person) => 'mc_' + this.layoutVersion.toString() + '_' + p.uid)
              }
              .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ left: Spacing.M, bottom: row.last ? Spacing.XL : 0 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
      }, (row: ModernRow) => 'mg_' + this.layoutVersion.toString() + '_' + this.highlightUid + '_' +
        row.generation.toString() + '_' + row.start.toString() + '_' + row.count.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .cachedCount(this.rows.length > 20 ? 2 : 3)
    .padding({ bottom: 120 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.None)
  }
}
