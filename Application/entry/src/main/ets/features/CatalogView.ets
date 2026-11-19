import { T, uiFontFamily } from 'common_base';
import { SR } from '../service/ServiceRegistry';

import { Person } from 'common_base';
import { GenealogyService } from '../service/GenealogyService';
import { Theme, Spacing, Radius } from 'common_base';
import { EmptyHint } from 'common_ui';
import { generationLabel } from 'common_base';
import { CatalogPersonRow } from './CatalogPersonRow';
import { Breakpoint } from 'common_base';
import { RouterUtil } from 'common_base';
import { FlatListSource } from 'common_base';
import { TreePerf } from 'common_base';

/**
 * 世系名录：按搜索、世代、性别、状态筛选，以列表/表格形式浏览全部族人。
 */
@Component
export struct CatalogView {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @Prop @Watch('onFiltersChanged') version: number = 0;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }
  @Prop windowWidth: number = 360;
  @StorageProp('gpKeyword') @Watch('onFiltersChanged') keyword: string = '';
  @StorageProp('gpFilterGen') @Watch('onFiltersChanged') filterGen: number = 0;
  @StorageProp('gpFilterGender') @Watch('onFiltersChanged') filterGender: string = '';
  @StorageProp('gpFilterStatus') @Watch('onFiltersChanged') filterStatus: string = '';
  @StorageLink('gpSelection') @Watch('onSelectionChanged') selectedUid: string = '';
  @Prop isMasterDetail: boolean = false;
  @State filteredCount: number = 0;
  @State generationValues: number[] = [];
  onOpenPerson: (uid: string) => void = (uid: string): void => {};
  private listSource: FlatListSource<Person> = new FlatListSource<Person>();
  private filteredCache: Person[] = [];
  private filterCacheKey: string = '';
  private generationVersion: number = -1;
  private resettingFilters: boolean = false;
  /** 上一次高亮的行：选中变化时只刷新这两行 */
  private lastSelectedUid: string = '';

  aboutToAppear(): void {
    this.refreshFiltered();
  }

  onFiltersChanged(): void {
    if (!this.resettingFilters) {
      this.refreshFiltered();
    }
  }

  onSelectionChanged(): void {
    const prev: string = this.lastSelectedUid;
    this.lastSelectedUid = this.selectedUid;
    const oldIndex: number = this.indexOfUid(prev);
    const newIndex: number = this.indexOfUid(this.selectedUid);
    if (oldIndex >= 0) {
      this.listSource.notifyItemChanged(oldIndex);
    }
    if (newIndex >= 0 && newIndex !== oldIndex) {
      this.listSource.notifyItemChanged(newIndex);
    }
  }

  private indexOfUid(uid: string): number {
    if (uid.length === 0) {
      return -1;
    }
    for (let i: number = 0; i < this.filteredCache.length; i = i + 1) {
      if (this.filteredCache[i].uid === uid) {
        return i;
      }
    }
    return -1;
  }

  private svc(): GenealogyService {
    return SR.genealogy();
  }

  private isWide(): boolean {
    return this.windowWidth >= Breakpoint.MD;
  }

  private filterKey(): string {
    return this.version.toString() + '|' + this.keyword + '|' + this.filterGen.toString() + '|' +
      this.filterGender + '|' + this.filterStatus;
  }

  private filtered(): Person[] {
    const key: string = this.filterKey();
    if (key === this.filterCacheKey) {
      return this.filteredCache;
    }
    TreePerf.begin('catalog_filter');
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
    this.filteredCache = list;
    this.filterCacheKey = key;
    TreePerf.end('catalog_filter', 'people=' + list.length.toString());
    return list;
  }

  private refreshFiltered(): void {
    const list: Person[] = this.filtered();
    this.filteredCount = list.length;
    this.lastSelectedUid = this.selectedUid;
    this.listSource.setData(list);
    if (this.generationVersion !== this.version) {
      const set: Set<number> = new Set<number>();
      this.svc().getPeople().forEach((p: Person): void => {
        set.add(p.generation);
      });
      this.generationValues = Array.from(set).sort((a: number, b: number): number => a - b);
      this.generationVersion = this.version;
    }
  }

  private clearFilters(): void {
    this.resettingFilters = true;
    this.keyword = '';
    this.filterGen = 0;
    this.filterGender = '';
    this.filterStatus = '';
    this.resettingFilters = false;
    this.refreshFiltered();
  }

  @Builder
  FilterBar() {
    Column() {
      Row() {
        Search({ value: $$this.keyword, placeholder: T('搜索谱名 / 曾用名 / 唯一ID / 职业') })
          .layoutWeight(1)
          .height(36)
          .backgroundColor(Theme.field)
          .placeholderColor(Theme.inkTertiary)
          .textFont({ size: 13 })

        Text(T('＋ 新增')).fontFamily(uiFontFamily())
          .fontSize(13)
          .fontColor(Theme.onPrimary)
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
          ForEach(this.generationValues, (g: number) => {
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
    Text(T(label)).fontFamily(uiFontFamily())
      .fontSize(12)
      .fontColor(active ? Theme.onPrimary : Theme.inkSecondary)
      .backgroundColor(active ? Theme.primary : Theme.field)
      .borderRadius(14)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .margin({ right: 6 })
      .onClick((): void => {
        action();
      })
  }

  build() {
    Column() {
      this.FilterBar()

      Row() {
        Text(T('共 ' + this.filteredCount.toString() + ' 人')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
        Blank()
        if (this.keyword.length > 0 || this.filterGen > 0 || this.filterGender.length > 0
          || this.filterStatus.length > 0) {
          Text(T('清除筛选')).fontFamily(uiFontFamily())
            .fontSize(12)
            .fontColor(Theme.primary)
            .onClick((): void => {
              this.clearFilters();
            })
        }
      }
      .width('100%')
      .padding({ top: Spacing.S, bottom: 4, left: 4, right: 4 })

      if (this.filteredCount === 0) {
        EmptyHint({ icon: '🔍', title: T('没有符合条件的族人'), desc: '尝试调整搜索词或筛选条件' })
      } else {
        List({ space: 2 }) {
          LazyForEach(this.listSource, (p: Person) => {
            ListItem() {
              CatalogPersonRow({
                person: p,
                selected: this.selectedUid === p.uid,
                showArrow: !this.isMasterDetail,
                wide: this.isWide(),
                onOpen: (uid: string): void => {
                  this.selectedUid = uid;
                  this.onOpenPerson(uid);
                }
              })
            }
          }, (p: Person) => 'cat_' + p.uid + '_' + p.updatedAt.toString()
            + (this.selectedUid === p.uid ? '_sel' : ''))
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(TreePerf.listCacheCount(this.filteredCount))
        .divider({ strokeWidth: 0.5, color: Theme.line, startMargin: 50 })
        .contentEndOffset(16)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }
}


