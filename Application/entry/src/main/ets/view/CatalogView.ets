import { Person } from '../model/Person';
import { GenealogyService } from '../service/GenealogyService';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { PersonAvatar } from '../components/PersonAvatar';
import { Tag } from '../components/Tag';
import { EmptyHint } from '../components/EmptyHint';
import { generationLabel } from '../model/Enums';
import { lifeSpan, ageOf } from '../util/DateUtil';
import { Breakpoint } from '../common/Constants';
import { RouterUtil } from '../util/RouterUtil';

/**
 * 世系名录：按搜索、世代、性别、状态筛选，以列表/表格形式浏览全部族人。
 */
@Component
export struct CatalogView {
  @Prop version: number = 0;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }
  @Prop windowWidth: number = 360;
  @StorageProp('gpKeyword') keyword: string = '';
  @StorageProp('gpFilterGen') filterGen: number = 0;
  @StorageProp('gpFilterGender') filterGender: string = '';
  @StorageProp('gpFilterStatus') filterStatus: string = '';
  @StorageLink('gpSelection') selectedUid: string = '';
  @Prop isMasterDetail: boolean = false;
  onOpenPerson: (uid: string) => void = (uid: string): void => {};

  private svc(): GenealogyService {
    return GenealogyService.getInstance();
  }

  private isWide(): boolean {
    return this.windowWidth >= Breakpoint.MD;
  }

  private filtered(): Person[] {
    let list: Person[] = this.svc().search(this.keyword);
    if (this.filterGen > 0) {
      list = list.filter((p: Person): boolean => p.generation === this.filterGen);
    }
    if (this.filterGender.length > 0) {
      list = list.filter((p: Person): boolean => p.gender === this.filterGender);
    }
    if (this.filterStatus.length > 0) {
      list = list.filter((p: Person): boolean => p.lifeStatus === this.filterStatus);
    }
    return list;
  }

  private generations(): number[] {
    const set: Set<number> = new Set<number>();
    this.svc().getPeople().forEach((p: Person): void => {
      set.add(p.generation);
    });
    return Array.from(set).sort((a: number, b: number): number => a - b);
  }

  @Builder
  FilterBar() {
    Column() {
      Row() {
        Search({ value: $$this.keyword, placeholder: '搜索谱名 / 曾用名 / 唯一ID / 职业' })
          .layoutWeight(1)
          .height(36)
          .backgroundColor(Theme.field)
          .placeholderColor(Theme.inkTertiary)
          .textFont({ size: 13 })

        Text('＋ 新增')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor(Theme.primary)
          .borderRadius(18)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .margin({ left: Spacing.S })
          .onClick((): void => {
            RouterUtil.editPerson(this.getUIContext(), '', 'create', '');
          })
      }
      .width('100%')

      Scroll() {
        Row() {
          this.FilterChip('全部世', this.filterGen === 0, (): void => {
            this.filterGen = 0;
          })
          ForEach(this.generations(), (g: number) => {
            this.FilterChip(generationLabel(g), this.filterGen === g, (): void => {
              this.filterGen = g;
            })
          }, (g: number) => 'fg_' + g.toString())
          this.FilterChip('男子', this.filterGender === '男', (): void => {
            this.filterGender = this.filterGender === '男' ? '' : '男';
          })
          this.FilterChip('女子', this.filterGender === '女', (): void => {
            this.filterGender = this.filterGender === '女' ? '' : '女';
          })
          this.FilterChip('在世', this.filterStatus === '在世', (): void => {
            this.filterStatus = this.filterStatus === '在世' ? '' : '在世';
          })
          this.FilterChip('已故', this.filterStatus === '已故', (): void => {
            this.filterStatus = this.filterStatus === '已故' ? '' : '已故';
          })
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: Spacing.S })
    }
    .width('100%')
    .padding({ left: Spacing.M, right: Spacing.M, top: Spacing.S, bottom: Spacing.M })
    .backgroundColor(Theme.card)
    .borderRadius(Radius.M)
    .border({ width: 0.5, color: Theme.line })
  }

  @Builder
  FilterChip(label: string, active: boolean, action: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(active ? '#FFFFFF' : Theme.inkSecondary)
      .backgroundColor(active ? Theme.primary : Theme.field)
      .borderRadius(14)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .margin({ right: 6 })
      .onClick((): void => {
        action();
      })
  }

  @Builder
  PersonRow(p: Person, showArrow: boolean) {
    Row() {
      PersonAvatar({ person: p, avatarSize: this.isWide() ? 40 : 38, showRing: false })
      Column() {
        Row() {
          Text(p.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(p.gender === '女' ? Theme.female : Theme.ink)
          if (p.rank.length > 0) {
            Text(p.rank)
              .fontSize(10)
              .fontColor(Theme.gold)
              .margin({ left: 4 })
          }
          if (p.lifeStatus === '已故') {
            Text('已故').fontSize(9).fontColor(Theme.deceased).margin({ left: 4 })
          }
        }
        Row() {
          Text(p.uid + ' · ' + generationLabel(p.generation)
            + (p.generationChar.length > 0 ? ' · ' + p.generationChar + '字' : ''))
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
        }
        .margin({ top: 2 })
        if (this.isWide() && (p.occupation.length > 0 || p.birthPlace.length > 0)) {
          Text(lifeSpan(p.birthDate, p.deathDate, p.lifeStatus)
            + (p.occupation.length > 0 ? ' · ' + p.occupation : ''))
            .fontSize(11)
            .fontColor(Theme.inkSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: Spacing.M })

      if (showArrow) {
        Text(this.selectedUid === p.uid ? '●' : '›')
          .fontSize(this.selectedUid === p.uid ? 12 : 18)
          .fontColor(this.selectedUid === p.uid ? Theme.primary : Theme.inkTertiary)
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 4, right: 4 })
    .backgroundColor(this.selectedUid === p.uid ? Theme.highlightBg : Color.Transparent)
    .borderRadius(8)
    .onClick((): void => {
      this.selectedUid = p.uid;
      this.onOpenPerson(p.uid);
    })
  }

  build() {
    Column() {
      this.FilterBar()

      Row() {
        Text('共 ' + this.filtered().length.toString() + ' 人')
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
        Blank()
        if (this.keyword.length > 0 || this.filterGen > 0 || this.filterGender.length > 0
          || this.filterStatus.length > 0) {
          Text('清除筛选')
            .fontSize(12)
            .fontColor(Theme.primary)
            .onClick((): void => {
              this.keyword = '';
              this.filterGen = 0;
              this.filterGender = '';
              this.filterStatus = '';
            })
        }
      }
      .width('100%')
      .padding({ top: Spacing.S, bottom: 4, left: 4, right: 4 })

      if (this.filtered().length === 0) {
        EmptyHint({ icon: '🔍', title: '没有符合条件的族人', desc: '尝试调整搜索词或筛选条件' })
      } else {
        List({ space: 2 }) {
          ForEach(this.filtered(), (p: Person) => {
            ListItem() {
              this.PersonRow(p, !this.isMasterDetail)
            }
          }, (p: Person) => 'cat_' + p.uid + p.updatedAt.toString())
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 50 })
        .padding({ bottom: 100 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }
}