import { Person } from '../model/Person';
import { GenealogyStats, GenerationStat } from '../model/Stats';
import { GenealogyService } from '../service/GenealogyService';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { StatCard } from '../components/StatCard';
import { TS } from '../components/TS';
import { Breakpoint } from '../common/Constants';

/**
 * 统计中心：人口结构、世代繁衍、世数、寿命、字派分布、资料完整度、墓葬定位。
 */
@Component
export struct GenealogyStatsPanel {
  @Prop version: number = 0;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }
  @Prop windowWidth: number = 360;

  /**
   * 统计结果按版本缓存。
   * build / 各 @Builder 里会多次调用 stats()，数万人时每次全量重算都会阻塞主线程，
   * 实测 4 万人首次渲染会把主线程卡到 THREAD_BLOCK_6S 被杀。
   */
  private cachedStats: GenealogyStats | null = null;
  private statsVersion: number = -1;
  private cachedChars: Array<string[]> = [];
  private charsVersion: number = -1;

  private stats(): GenealogyStats {
    if (this.cachedStats !== null && this.statsVersion === this.version) {
      return this.cachedStats;
    }
    const computed: GenealogyStats = GenealogyService.getInstance().computeStats();
    this.cachedStats = computed;
    this.statsVersion = this.version;
    return computed;
  }

  private charDistribution(): Array<string[]> {
    if (this.charsVersion === this.version) {
      return this.cachedChars;
    }
    const svc: GenealogyService = GenealogyService.getInstance();
    const map: Map<string, number> = new Map<string, number>();
    svc.getPeople().forEach((p: Person): void => {
      if (p.generationChar.trim().length === 0) {
        return;
      }
      const c: string = p.generationChar.trim();
      const n: number | undefined = map.get(c);
      map.set(c, n === undefined ? 1 : n + 1);
    });
    const arr: Array<string[]> = [];
    map.forEach((v: number, k: string): void => {
      arr.push([k, v.toString()]);
    });
    arr.sort((a: string[], b: string[]): number => parseInt(b[1], 10) - parseInt(a[1], 10));
    this.cachedChars = arr.slice(0, 12);
    this.charsVersion = this.version;
    return this.cachedChars;
  }

  @Builder
  RatioRow(label: string, value: number, total: number, color: string) {
    Row() {
      Text(label).fontSize(12).fontColor(Theme.inkSecondary).width(56)
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(12).backgroundColor(Theme.field).borderRadius(6)
        Row()
          .width((total === 0 ? 0 : Math.max(value / total * 100, 2)).toString() + '%')
          .height(12)
          .backgroundColor(color)
          .borderRadius(6)
      }
      .layoutWeight(1)
      .height(12)
      Text(value.toString()).fontSize(12).fontColor(Theme.ink).width(48).textAlign(TextAlign.End)
      Text(total === 0 ? '0%' : Math.round(value / total * 100).toString() + '%')
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .width(40)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  @Builder
  GenTable() {
    Column() {
      Row() {
        Text('世代').fontSize(11).fontColor(Theme.inkTertiary).width(64)
        Text('人数').fontSize(11).fontColor(Theme.inkTertiary).width(44)
        Text('男/女').fontSize(11).fontColor(Theme.inkTertiary).width(64)
        Text('在世/已故').fontSize(11).fontColor(Theme.inkTertiary).layoutWeight(1)
      }
      .width('100%')
      .padding({ bottom: 6 })

      ForEach(this.stats().generations, (g: GenerationStat) => {
        Row() {
          Text(g.label).fontSize(12.5).fontColor(Theme.primary).width(64)
          Text(g.total.toString()).fontSize(12.5).fontColor(Theme.ink).width(44)
          Text(g.male.toString() + '/' + g.female.toString()).fontSize(12).fontColor(Theme.inkSecondary).width(64)
          Text(g.alive.toString() + '/' + g.deceased.toString()).fontSize(12).fontColor(Theme.inkSecondary).layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .border({ width: { bottom: 0.5 }, color: Theme.line })
      }, (g: GenerationStat) => 'gt_' + g.generation.toString())
    }
    .width('100%')
  }

  @Builder
  CharChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.charDistribution(), (item: string[]) => {
        Row() {
          Text('“' + item[0] + '”')
            .fontSize(13)
            .fontColor(Theme.primary)
            .fontWeight(FontWeight.Medium)
          Text(item[1] + '人')
            .fontSize(10)
            .fontColor(Theme.inkTertiary)
            .margin({ left: 3 })
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Theme.highlightBg)
        .borderRadius(12)
        .margin({ right: 6, bottom: 6 })
      }, (item: string[]) => 'ch_' + item[0])
    }
    .width('100%')
  }

  @Builder
  Completeness() {
    Column() {
      this.RatioRow('出生日期', this.stats().birthdayKnown, this.stats().total, Theme.primary)
      this.RatioRow('头像相片', this.stats().avatarCount, this.stats().total, Theme.gold)
      this.RatioRow('墓葬定位', this.stats().graveWithGps, this.stats().deceased, Theme.alive)
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column() {
        Grid() {
          GridItem() {
            StatCard({ label: '族众总数', value: this.stats().total.toString(), unit: '人', icon: '👥' })
          }
          GridItem() {
            StatCard({ label: '已传世数', value: this.stats().maxGeneration.toString(), unit: '世', icon: '🪜', accent: Theme.gold })
          }
          GridItem() {
            StatCard({ label: '已故先人', value: this.stats().deceased.toString(), unit: '人', icon: '🕯',
              accent: Theme.deceased })
          }
          GridItem() {
            StatCard({
              label: '平均寿命', value: this.stats().averageLifespan.toString(), unit: '岁', icon: '⏳',
              accent: Theme.alive
            })
          }
        }
        .columnsTemplate(this.windowWidth >= Breakpoint.MD ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
        .rowsGap(Spacing.S)
        .columnsGap(Spacing.S)
        .width('100%')
        .height(this.windowWidth >= Breakpoint.MD ? 84 : 176)

        if (this.windowWidth >= Breakpoint.MD) {
          Row() {
            Column() {
              TS({ title: '性别构成', icon: '⚖️' })
              Column() {
                this.RatioRow('男', this.stats().male, this.stats().total, Theme.male)
                this.RatioRow('女', this.stats().female, this.stats().total, Theme.female)
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)

              TS({ title: '在世状况', icon: '🌿' })
              Column() {
                this.RatioRow('在世', this.stats().alive, this.stats().total, Theme.alive)
                this.RatioRow('已故', this.stats().deceased, this.stats().total, Theme.deceased)
                this.RatioRow('失联', this.stats().lost, this.stats().total, Theme.lost)
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)

              TS({ title: '资料完整度', subtitle: '推动族人补充缺失信息', icon: '📋' })
              Column() {
                this.Completeness()
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)
            }
            .layoutWeight(1)
            .margin({ right: Spacing.M })

            Column() {
              TS({ title: '世代繁衍', subtitle: '各世代人口结构', icon: '🌱' })
              Column() {
                this.GenTable()
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)

              TS({ title: '字派分布', subtitle: '按辈分/字派统计', icon: '✒️' })
              Column() {
                this.CharChips()
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: Spacing.M })
        } else {
          TS({ title: '性别与在世状况', icon: '⚖️' })
          Column() {
            this.RatioRow('男', this.stats().male, this.stats().total, Theme.male)
            this.RatioRow('女', this.stats().female, this.stats().total, Theme.female)
            this.RatioRow('在世', this.stats().alive, this.stats().total, Theme.alive)
            this.RatioRow('已故', this.stats().deceased, this.stats().total, Theme.deceased)
            this.RatioRow('失联', this.stats().lost, this.stats().total, Theme.lost)
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '世代繁衍', subtitle: '各世代人口结构', icon: '🌱' })
          Column() {
            this.GenTable()
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '字派分布', subtitle: '按辈分/字派统计', icon: '✒️' })
          Column() {
            this.CharChips()
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '资料完整度', subtitle: '推动族人补充缺失信息', icon: '📋' })
          Column() {
            this.Completeness()
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)
        }

        Column().height(100)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }
}