import { Person } from '../model/Person';
import { Genealogy } from '../model/Genealogy';
import { GenealogyStats, GenerationStat } from '../model/Stats';
import { GenealogyService } from '../service/GenealogyService';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { StatCard } from '../components/StatCard';
import { TS } from '../components/TS';
import { Breakpoint } from '../common/Constants';
import { generationLabel } from '../model/Enums';
import { RouterUtil } from '../util/RouterUtil';
import { InsightService } from '../service/InsightService';
import { IntegrityService } from '../service/IntegrityService';
import { IntegrityIssue, IntegrityReport } from '../model/Integrity';
import { BirthdayItem } from '../model/TimerSession';

/**
 * 首页 / 概览：族谱封面、统计看板、字派谱、家训、谱序与世代分布。
 */
@Component
export struct HomeView {
  @Prop @Watch('onVersionChange') version: number = 0;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  /**
   * 概览页的派生数据缓存。
   * build 内原先把 stats() 调用了 9 次、birthdays() 3 次、warnings() 3 次，
   * 8 万人时等于十几次全量遍历，同步占满主线程（THREAD_BLOCK_6S 强杀）。
   * 改为进入页面时按版本号计算一次，build 只读字段；完整性校验更慢，放到首帧之后。
   */
  @State statsView: GenealogyStats = new GenealogyStats();
  @State birthdayView: BirthdayItem[] = [];
  @State recentView: Person[] = [];
  @State warnView: string[][] = [];
  private warnVersion: number = -1;

  aboutToAppear(): void {
    this.rebuildCache();
  }

  onVersionChange(): void {
    this.rebuildCache();
  }

  private rebuildCache(): void {
    const svc: GenealogyService = this.svc();
    this.statsView = svc.computeStats();
    const now: Date = new Date();
    this.birthdayView = InsightService.birthdaysOfMonth(svc.getPeople(), now.getMonth() + 1, now.getDate());
    const list: Person[] = svc.getPeople().slice();
    list.sort((a: Person, b: Person): number => b.updatedAt - a.updatedAt);
    this.recentView = list.slice(0, 6);
    // 世系与ID校验要跑三套全量检查，推迟到首帧渲染之后执行，避免进入概览时卡住
    this.warnVersion = this.version;
    setTimeout((): void => {
      if (this.warnVersion !== this.version) {
        return;
      }
      this.warnView = this.computeWarnings();
    }, 0);
  }

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }
  @Prop windowWidth: number = 360;
  @StorageProp('gpStyle') styleName: string = 'eu';
  onOpenStyle: (style: string) => void = (style: string): void => {};
  onOpenPerson: (uid: string) => void = (uid: string): void => {};

  private svc(): GenealogyService {
    return GenealogyService.getInstance();
  }

  private book(): Genealogy {
    return this.svc().getBook();
  }

  private isWide(): boolean {
    return this.windowWidth >= Breakpoint.SM;
  }

  @Builder
  Cover() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 135, colors: [[this.book().coverColor, 0.0], ['#5A1C10', 1.0]] })
      Column()
        .width('100%')
        .height('100%')
        .border({ width: 1, color: Theme.goldLight, radius: Radius.L })
        .opacity(0.35)
        .margin({ top: 8, bottom: 8, left: 8, right: 8 })
        .borderRadius(Radius.L)

      // 沉浸光感：右上角柔光晕，增加封面的纵深与材质感
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['80%', '6%'],
          radius: 260,
          colors: [[Theme.glow, 0.0], ['rgba(255,255,255,0)', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      Column() {
        Row() {
          Text('◆ ' + (this.book().junwang.length > 0 ? this.book().junwang : '宗族') +
            (this.book().hallName.length > 0 ? ' · ' + this.book().hallName : ''))
            .fontSize(11)
            .fontColor(Theme.goldLight)
          Blank()
          Text('已录 ' + this.statsView.total.toString() + ' 人')
            .fontSize(11)
            .fontColor(Theme.goldLight)
        }
        .width('100%')

        Column() {
          Text(this.book().title)
            .fontSize(this.isWide() ? 30 : 26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.highlightBg)
          Text(this.book().generationPoem.length > 0 ? '字派 · ' + this.book().generationPoem : '')
            .fontSize(12)
            .fontColor(Theme.goldLight)
            .margin({ top: 6 })
          Text((this.book().ancestorName.length > 0 ? '始迁祖 ' + this.book().ancestorName + ' 公' : '') +
            ' · 历 ' + this.statsView.maxGeneration.toString() + ' 世')
            .fontSize(12)
            .fontColor('#E9D6B4')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 18, bottom: 10 })
      }
      .width('100%')
      .padding(Spacing.XL)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(this.isWide() ? 200 : 176)
    .borderRadius(Radius.XL)
    .clip(true)
    .shadow({ radius: 16, color: 'rgba(90,28,16,0.25)', offsetY: 6 })
  }

  @Builder
  StatsGrid() {
    Grid() {
      GridItem() {
        StatCard({ label: '族众总人数', value: this.statsView.total.toString(), unit: '人', icon: '👥' })
      }
      GridItem() {
        StatCard({ label: '男子', value: this.statsView.male.toString(), unit: '人', icon: '♂', accent: Theme.male })
      }
      GridItem() {
        StatCard({ label: '女子', value: this.statsView.female.toString(), unit: '人', icon: '♀', accent: Theme.female })
      }
      GridItem() {
        StatCard({ label: '在世', value: this.statsView.alive.toString(), unit: '人', icon: '🌱', accent: Theme.alive })
      }
      GridItem() {
        StatCard({ label: '已故', value: this.statsView.deceased.toString(), unit: '人', icon: '🕯', accent: Theme.deceased })
      }
      GridItem() {
        StatCard({ label: '世数', value: this.statsView.maxGeneration.toString(), unit: '世', icon: '🪜', accent: Theme.gold })
      }
    }
    .columnsTemplate(this.windowWidth >= Breakpoint.LG ? '1fr 1fr 1fr 1fr 1fr 1fr' :
      (this.windowWidth >= Breakpoint.MD ? '1fr 1fr 1fr' : '1fr 1fr 1fr'))
    .columnsGap(Spacing.S)
    .rowsGap(Spacing.S)
    .height(this.windowWidth >= Breakpoint.LG ? 84 : 176)
    .width('100%')
  }

  @Builder
  GenerationChart() {
    Column() {
      ForEach(this.statsView.generations, (g: GenerationStat) => {
        Row() {
          Text(g.label)
            .fontSize(11)
            .fontColor(Theme.inkSecondary)
            .width(52)
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(16)
              .backgroundColor(Theme.field)
              .borderRadius(8)
            Row()
              .width(Math.max(g.ratio * 100, 4).toString() + '%')
              .height(16)
              .borderRadius(8)
              .linearGradient({ angle: 90, colors: [[Theme.gold, 0.0], [Theme.primary, 1.0]] })
            Row() {
              Text(g.total.toString() + ' 人').fontSize(10).fontColor('#FFFFFF').margin({ left: 6 })
            }
            .width('100%')
            .height(16)
            .justifyContent(FlexAlign.Start)
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .height(16)
        }
        .width('100%')
        .margin({ bottom: 6 })
      }, (g: GenerationStat) => 'gen_' + g.generation.toString())
    }
    .width('100%')
  }

  @Builder
  StyleShortcuts() {
    Column() {
      ForEach([['eu', '欧式', '横轴世系'], ['su', '苏式', '竖式吊线'], ['pagoda', '宝塔', '金字塔'],
        ['die', '牒记', '文字编年'], ['modern', '现代', '卡片时间轴']], (item: string[], idx: number) => {
        Row() {
          Text(item[0].toUpperCase())
            .fontSize(11)
            .fontColor(Theme.primary)
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor(Theme.highlightBg)
            .borderRadius(13)
          Column() {
            Text(item[1] + '谱')
              .fontSize(13.5)
              .fontColor(Theme.ink)
            Text(item[2])
              .fontSize(10)
              .fontColor(Theme.inkTertiary)
              .margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 8 })
          Text('›').fontSize(16).fontColor(Theme.inkTertiary)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .onClick((): void => {
          this.onOpenStyle(item[0]);
        })
      }, (item: string[]) => 'sc_' + item[0])
    }
    .width('100%')
  }

  @Builder
  RecentList() {
    Column() {
      ForEach(this.recentView, (p: Person) => {
        Row() {
          Text(p.name.substring(0, 1))
            .fontSize(13)
            .fontColor(p.gender === '女' ? Theme.female : Theme.primary)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .backgroundColor(Theme.field)
            .borderRadius(15)
          Column() {
            Text(p.name + (p.generationChar.length > 0 ? '（' + p.generationChar + '字）' : ''))
              .fontSize(13.5)
              .fontColor(Theme.ink)
            Text(generationLabel(p.generation) + ' · ' + p.uid)
              .fontSize(10)
              .fontColor(Theme.inkTertiary)
              .margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 8 })
          Text(p.lifeStatus)
            .fontSize(11)
            .fontColor(p.lifeStatus === '已故' ? Theme.deceased : Theme.alive)
        }
        .width('100%')
        .padding({ top: 7, bottom: 7 })
        .onClick((): void => {
          this.onOpenPerson(p.uid);
        })
      }, (p: Person) => 'recent_' + p.uid + p.updatedAt.toString())
    }
    .width('100%')
  }

  private computeWarnings(): string[][] {
    const report: IntegrityReport = IntegrityService.check(this.svc().getPeople());
    report.merge(IntegrityService.reused(this.svc().getPeople(), this.svc().getRetiredMap()));
    report.merge(IntegrityService.reusedReferences(this.svc().getPeople(), this.svc().getRetiredMap()));
    const rows: string[][] = [];
    report.issues.forEach((issue: IntegrityIssue): void => {
      const name: string = issue.name.length > 0 ? issue.name : issue.uid;
      rows.push([name, issue.uid, issue.message]);
    });
    return rows;
  }

  @Builder
  BirthdayStrip() {
    Column() {
      Row() {
        Text('🎂 本月寿辰').fontSize(14).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
        Blank()
        Text(this.birthdayView.length.toString() + ' 人')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
      }
      .width('100%')

      if (this.birthdayView.length === 0) {
        Text('本月暂无在世族人寿辰记录')
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 8 })
      } else {
        ForEach(this.birthdayView.slice(0, 5), (b: BirthdayItem) => {
          Row() {
            Text(b.day.toString() + '日')
              .fontSize(11)
              .fontColor(Theme.primary)
              .width(40)
            Text(b.name)
              .fontSize(13)
              .fontColor(Theme.ink)
              .layoutWeight(1)
            Text(b.isToday ? '今日 · 满 ' + b.turningAge.toString() + ' 岁' : '满 ' + b.turningAge.toString() + ' 岁')
              .fontSize(11)
              .fontColor(b.isToday ? Theme.alive : Theme.inkTertiary)
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick((): void => {
            this.onOpenPerson(b.uid);
          })
        }, (b: BirthdayItem) => 'bd_' + b.uid)
      }
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(16)
    .border({ width: 0.5, color: Theme.line })
    .margin({ bottom: Spacing.M })
  }

  @Builder
  WarningStrip() {
    if (this.warnView.length > 0) {
      Column() {
        Text('⚠ 世系与ID校验提示（' + this.warnView.length.toString() + ' 条）')
          .fontSize(13)
          .fontColor(Theme.lost)
          .width('100%')
        ForEach(this.warnView.slice(0, 4), (w: string[]) => {
          Text(w[0] + '（' + w[1] + '）：' + w[2])
            .fontSize(11.5)
            .fontColor(Theme.inkSecondary)
            .margin({ top: 4 })
            .width('100%')
        }, (w: string[]) => 'wn_' + w[0] + w[2])
      }
      .width('100%')
      .padding(Spacing.L)
      .backgroundColor(Theme.highlightBg)
      .borderRadius(16)
      .margin({ bottom: Spacing.M })
    }
  }

  build() {
    Scroll() {
      Column() {
        this.Cover()

        Column() {
          this.StatsGrid()
        }
        .width('100%')
        .margin({ top: Spacing.M })

        this.BirthdayStrip()
        this.WarningStrip()
        if (this.isWide()) {
          Row() {
            Column() {
              TS({ title: '世代分布', subtitle: '各世人数与占比', icon: '📊' })
              Column() {
                this.GenerationChart()
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)

              TS({ title: '五种谱式', subtitle: '一键切换展示方式', icon: '📜' })
              Column() {
                this.StyleShortcuts()
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
              TS({ title: '最近更新', subtitle: '按修改时间排序', icon: '🕘' })
              Column() {
                this.RecentList()
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)

              TS({ title: '家训', subtitle: this.book().hallName, icon: '🏮' })
              Column() {
                Text(this.book().familyRules)
                  .fontSize(13)
                  .lineHeight(24)
                  .fontColor(Theme.inkSecondary)
                  .width('100%')
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
              .backgroundColor(Theme.card)
              .borderRadius(16)
              .border({ width: 0.5, color: Theme.line })
              .margin({ bottom: Spacing.M })
              .clip(true)

              TS({ title: '谱序', icon: '✍️' })
              Column() {
                Text(this.book().preface)
                  .fontSize(13)
                  .lineHeight(24)
                  .fontColor(Theme.inkSecondary)
                  .width('100%')
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
          .margin({ top: Spacing.M })
          .alignItems(VerticalAlign.Top)
        } else {
          TS({ title: '世代分布', subtitle: '各世人数与占比', icon: '📊' })
          Column() {
            this.GenerationChart()
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '五种谱式', subtitle: '一键切换展示方式', icon: '📜' })
          Column() {
            this.StyleShortcuts()
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '最近更新', subtitle: '按修改时间排序', icon: '🕘' })
          Column() {
            this.RecentList()
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '家训', subtitle: this.book().hallName, icon: '🏮' })
          Column() {
            Text(this.book().familyRules)
              .fontSize(13)
              .lineHeight(24)
              .fontColor(Theme.inkSecondary)
              .width('100%')
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '谱序', icon: '✍️' })
          Column() {
            Text(this.book().preface)
              .fontSize(13)
              .lineHeight(24)
              .fontColor(Theme.inkSecondary)
              .width('100%')
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
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }
}