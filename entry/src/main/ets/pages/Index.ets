import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Breakpoint } from '../common/Constants';
import { Theme, Spacing } from '../theme/Theme';
import { Layout } from '../common/Layout';
import { GenealogyService } from '../service/GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import { GenealogyScope } from '../model/Scope';
import { PersonNode } from '../model/PersonNode';
import { Person } from '../model/Person';
import { GenealogyStats } from '../model/Stats';
import { HomeView } from '../view/HomeView';
import { TreeCanvas } from '../view/TreeCanvas';
import { StyleSwitcher } from '../view/StyleSwitcher';
import { CatalogView } from '../view/CatalogView';
import { SettingsView } from '../view/SettingsView';
import { PersonDetailPanel } from '../view/PersonDetailPanel';
import { GenealogyStatsPanel } from '../view/GenealogyStatsPanel';
import { RouterUtil } from '../util/RouterUtil';
import { DeviceUtil } from '../util/DeviceUtil';
import { resourceManager } from '@kit.LocalizationKit';

const TAG: string = '[Genealogy][Index]';

interface NavItem {
  key: string;
  title: string;
  icon: string;
}

const NAV_ITEMS: NavItem[] = [
  { key: 'home', title: '概览', icon: '🏠' },
  { key: 'tree', title: '谱系', icon: '🌳' },
  { key: 'catalog', title: '名录', icon: '📖' },
  { key: 'stats', title: '统计', icon: '📊' },
  { key: 'settings', title: '设置', icon: '⚙️' }
];

/**
 * 应用主界面。
 *
 * 一多响应式策略：
 *  - XS（<600vp，手机 / 折叠态）：底部 TabBar + 全屏详情弹层
 *  - SM（600~840vp，阔屏 / 阔折叠展开）：左侧图标侧栏 + 双栏
 *  - MD（840~1200vp，平板 / 阔折叠 / 双折叠展开）：侧栏 + 主从双栏
 *  - LG/XL（≥1200vp，电脑 / 三折叠展开）：完整侧栏 + 三栏（导航·谱系·详情）
 */
@Entry
@Component
struct Index {
  @StorageProp('windowWidth') windowWidth: number = 360;
  @StorageProp('windowHeight') windowHeight: number = 780;
  @StorageProp('gpVersion') version: number = 0;
  @StorageProp('gpReady') ready: boolean = false;
  @StorageProp('gpStyle') styleName: string = 'eu';
  @StorageProp('gpTab') currentTab: number = 1;
  @StorageProp('gpSelection') selectedUid: string = '';
  @StorageProp('gpZoom') zoom: number = 1;
  @StorageProp('gpPublicMode') publicMode: boolean = false;
  @StorageProp('gpShowPrivate') showPrivate: boolean = true;
  @State showDetailSheet: boolean = false;
  /** 本地就绪标记（AppStorage 订阅作为兜底） */
  @State localReady: boolean = false;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  /** 回到前台 / 页面显示时同步一次系统配色 */
  onPageShow(): void {
    this.syncDarkMode();
  }


  /** 读取系统深浅色并广播到 AppStorage，供各页面/组件订阅 */
  private syncDarkMode(): void {
    try {
      const host: Context | undefined = this.getUIContext().getHostContext();
      if (host !== undefined && host.resourceManager !== undefined) {
        const dark: boolean = host.resourceManager.getConfigurationSync().colorMode ===
          resourceManager.ColorMode.DARK;
        AppStorage.setOrCreate<boolean>('darkMode', dark);
        this.darkMode = dark;
      }
    } catch (e) {
      AppStorage.setOrCreate<boolean>('darkMode', false);
    }
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    this.ensureStorage();
    this.syncDarkMode();
    DeviceUtil.listenBreakpoints(this.getUIContext());
    this.initData();
  }

  private ensureStorage(): void {
    if (AppStorage.get<number>('windowWidth') === undefined) {
      AppStorage.setOrCreate<number>('windowWidth', 360);
    }
    if (AppStorage.get<string>('gpStyle') === undefined) {
      AppStorage.setOrCreate<string>('gpStyle', 'eu');
    }
    if (AppStorage.get<number>('gpTab') === undefined) {
      AppStorage.setOrCreate<number>('gpTab', 1);
    }
    if (AppStorage.get<string>('gpKeyword') === undefined) {
      AppStorage.setOrCreate<string>('gpKeyword', '');
    }
    if (AppStorage.get<number>('gpFilterGen') === undefined) {
      AppStorage.setOrCreate<number>('gpFilterGen', 0);
    }
    if (AppStorage.get<string>('gpFilterGender') === undefined) {
      AppStorage.setOrCreate<string>('gpFilterGender', '');
    }
    if (AppStorage.get<string>('gpFilterStatus') === undefined) {
      AppStorage.setOrCreate<string>('gpFilterStatus', '');
    }
    if (AppStorage.get<number>('gpZoom') === undefined) {
      AppStorage.setOrCreate<number>('gpZoom', 1);
    }
    if (AppStorage.get<boolean>('gpPublicMode') === undefined) {
      AppStorage.setOrCreate<boolean>('gpPublicMode', false);
    }
    if (AppStorage.get<boolean>('gpShowPrivate') === undefined) {
      AppStorage.setOrCreate<boolean>('gpShowPrivate', true);
    }
    if (AppStorage.get<number>('gpVersion') === undefined) {
      AppStorage.setOrCreate<number>('gpVersion', 0);
    }
    if (AppStorage.get<boolean>('gpReady') === undefined) {
      AppStorage.setOrCreate<boolean>('gpReady', false);
    }
  }

  private async initData(): Promise<void> {
    try {
      if (GenealogyScope.isReady() && GenealogyService.getInstance().isReady()) {
        GenealogyStore.notifyChanged();
        this.localReady = true;
        return;
      }
      await GenealogyStore.bootstrap();
      this.localReady = true;
      hilog.info(0x0000, TAG, 'data ready, people=%{public}d',
        GenealogyService.getInstance().getPeople().length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'bootstrap failed %{public}s', err.message);
      this.getUIContext().getPromptAction().showToast({ message: '数据初始化失败：' + err.message });
    }
  }

  // ---------------------------------------------------------------- 交互

  private openPerson(uid: string): void {
    AppStorage.setOrCreate<string>('gpSelection', uid);
    if (this.windowWidth < Breakpoint.MD) {
      this.showDetailSheet = true;
    }
  }

  private openStyle(style: string): void {
    GenealogyStore.setStyle(style);
    AppStorage.setOrCreate<number>('gpTab', 1);
  }

  // ---------------------------------------------------------------- 构建

  @Builder
  NavBar(collapsed: boolean) {
    Column() {
      Row() {
        Text('谱').fontSize(collapsed ? 22 : 20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }
      .width(collapsed ? 40 : '100%')
      .height(40)
      .borderRadius(10)
      .backgroundColor(Theme.primary)
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: collapsed ? Spacing.L : Spacing.M })

      ForEach(NAV_ITEMS, (item: NavItem, idx: number) => {
        Column() {
          Text(item.icon).fontSize(collapsed ? 20 : 17)
          if (!collapsed) {
            Text(item.title)
              .fontSize(14)
              .fontColor(this.currentTab === idx ? Theme.primary : Theme.inkSecondary)
              .margin({ left: Spacing.S })
              .layoutWeight(1)
          }
        }
        .height(collapsed ? 44 : 42)
        .width(collapsed ? 44 : '100%')
        .borderRadius(10)
        .backgroundColor(this.currentTab === idx ? '#FBEFD9' : Color.Transparent)
        .justifyContent(FlexAlign.Center)
        .alignItems(collapsed ? HorizontalAlign.Center : HorizontalAlign.Start)
        .padding(collapsed ? 0 : { left: Spacing.M })
        .margin({ bottom: 4 })
        .onClick((): void => {
          AppStorage.setOrCreate<number>('gpTab', idx);
        })
      }, (item: NavItem) => 'nav_' + item.key)

      Blank()

      Text('＋')
        .fontSize(20)
        .fontColor('#FFFFFF')
        .width(collapsed ? 40 : 44)
        .height(40)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.primary)
        .borderRadius(20)
        .onClick((): void => {
          RouterUtil.editPerson(this.getUIContext(), '', 'create', '');
        })

      Text('人 ' + this.peopleCount().toString())
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .margin({ top: Spacing.S })

      Text('v1.0.0').fontSize(10).fontColor(Theme.inkTertiary).margin({ top: 2 })
      Column().height(Spacing.M)
    }
    .width(collapsed ? 68 : 190)
    .height('100%')
    .padding({ top: Spacing.L, left: Spacing.S, right: Spacing.S })
    .backgroundColor(Theme.card)
    .border({ width: { right: 0.5 }, color: Theme.line })
  }

  @Builder
  BottomBar() {
    Row() {
      ForEach(NAV_ITEMS, (item: NavItem, idx: number) => {
        Column() {
          Text(item.icon).fontSize(19).opacity(this.currentTab === idx ? 1 : 0.55)
          Text(item.title)
            .fontSize(10)
            .fontColor(this.currentTab === idx ? Theme.primary : Theme.inkTertiary)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .onClick((): void => {
          AppStorage.setOrCreate<number>('gpTab', idx);
        })
      }, (item: NavItem) => 'bb_' + item.key)
    }
    .width('100%')
    .height(58)
    .padding({ bottom: 4 })
    .backgroundColor(Theme.card)
    .border({ width: { top: 0.5 }, color: Theme.line })
  }

  @Builder
  TreeToolbar() {
    Column() {
      Row() {
        StyleSwitcher({
          current: this.styleName,
          windowWidth: this.windowWidth,
          onSelect: (style: string): void => {
            GenealogyStore.setStyle(style);
          }
        })
      }
      .width('100%')

      Row() {
        Text('缩放 ' + Math.round(this.zoom * 100).toString() + '%')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
        Slider({ value: this.zoom * 100, min: 50, max: 150, step: 5 })
          .layoutWeight(1)
          .selectedColor(Theme.primary)
          .blockColor(Theme.primary)
          .margin({ left: Spacing.S, right: Spacing.S })
          .onChange((value: number): void => {
            AppStorage.setOrCreate<number>('gpZoom', value / 100);
          })
        Text('新增族人')
          .fontSize(12)
          .fontColor(Theme.primary)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .border({ width: 1, color: Theme.primary })
          .onClick((): void => {
            RouterUtil.editPerson(this.getUIContext(), '', 'create', '');
          })
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
  }

  @Builder
  TreePane() {
    Column() {
      this.TreeToolbar()
      TreeCanvas({
        style: this.styleName,
        roots: GenealogyService.getInstance().getRoots(),
        people: GenealogyService.getInstance().getPeople(),
        highlightUid: this.selectedUid,
        showPrivate: this.showPrivate && !this.publicMode,
        windowWidth: this.windowWidth,
        zoom: this.zoom,
        onTapPerson: (uid: string): void => {
          this.openPerson(uid);
        }
      })
    }
    .width('100%')
    .height('100%')
    .padding({ top: Spacing.M })
  }

  @Builder
  DetailPane() {
    Column() {
      PersonDetailPanel({
        uid: this.selectedUid,
        showPrivate: this.showPrivate && !this.publicMode,
        narrow: false,
        onEdit: (uid: string): void => {
          RouterUtil.editPerson(this.getUIContext(), uid, 'edit', '');
        },
        onJump: (uid: string): void => {
          this.openPerson(uid);
        },
        onAddChild: (uid: string): void => {
          RouterUtil.editPerson(this.getUIContext(), '', 'child', uid);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.card)
    .borderRadius(16)
    .shadow({ radius: 16, color: Theme.shadow, offsetY: 2 })
  }

  @Builder
  CatalogPane() {
    CatalogView({
      version: this.version,
      windowWidth: this.windowWidth,
      isMasterDetail: this.isMasterDetail(),
      onOpenPerson: (uid: string): void => {
        this.openPerson(uid);
      }
    })
  }

  @Builder
  StatsPane() {
    GenealogyStatsPanel({
      version: this.version,
      windowWidth: this.windowWidth
    })
  }

  @Builder
  ContentArea() {
    if (this.currentTab === 0) {
      HomeView({
        version: this.version,
        windowWidth: this.windowWidth,
        onOpenStyle: (style: string): void => {
          this.openStyle(style);
        },
        onOpenPerson: (uid: string): void => {
          this.openPerson(uid);
        }
      })
    } else if (this.currentTab === 1) {
      if (this.isTriplePane()) {
        Row() {
          Column() {
            this.TreePane()
          }
          .layoutWeight(2)
          Column() {
            this.DetailPane()
          }
          .width(340)
          .margin({ left: Spacing.L, top: Spacing.M })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        this.TreePane()
      }
    } else if (this.currentTab === 2) {
      if (this.isMasterDetail()) {
        Row() {
          Column() {
            this.CatalogPane()
          }
          .layoutWeight(1)
          Column() {
            this.DetailPane()
          }
          .width(Math.max(300, Math.min(380, this.windowWidth * 0.36)))
          .margin({ left: Spacing.L })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        this.CatalogPane()
      }
    } else if (this.currentTab === 3) {
      this.StatsPane()
    } else {
      SettingsView({
        version: this.version
      })
    }
  }

  private peopleCount(): number {
    return GenealogyService.getInstance().getPeople().length;
  }

  private isMasterDetail(): boolean {
    return this.windowWidth >= Breakpoint.MD;
  }

  private isTriplePane(): boolean {
    return this.windowWidth >= Breakpoint.LG;
  }

  private showSidebar(): boolean {
    return this.windowWidth >= Breakpoint.SM;
  }

  private sidebarCollapsed(): boolean {
    return this.windowWidth < Breakpoint.MD;
  }

  build() {
    Column() {
      // 顶部品牌栏（大屏显示完整标题，小屏显示精简标题）
      Row() {
        Text(GenealogyService.getInstance().getBook().title)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.ink)
        Text('· ' + GenealogyService.getInstance().getBook().hallName)
          .fontSize(12)
          .fontColor(Theme.gold)
          .margin({ left: 6 })
          .maxLines(1)
        Blank()
        Text(this.showSidebar() ? Layout.deviceLabel(this.windowWidth) : '')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
        Text('⚙')
          .fontSize(17)
          .fontColor(Theme.inkSecondary)
          .padding(6)
          .margin({ left: Spacing.S })
          .onClick((): void => {
            AppStorage.setOrCreate<number>('gpTab', 4);
          })
      }
      .width('100%')
      .height(48)
      .padding({ left: Layout.pagePadding(this.windowWidth), right: Layout.pagePadding(this.windowWidth) })
      .backgroundColor(Theme.card)
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      Row() {
        if (this.showSidebar()) {
          this.NavBar(this.sidebarCollapsed())
        }

        Column() {
          if (!this.localReady && !this.ready) {
            Column() {
              LoadingProgress().width(40).height(40).color(Theme.primary)
              Text('正在展开族谱…').fontSize(12).fontColor(Theme.inkTertiary).margin({ top: Spacing.M })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          } else {
            this.ContentArea()
          }
        }
        .layoutWeight(1)
        .height('100%')
        .padding({
          left: Layout.pagePadding(this.windowWidth),
          right: Layout.pagePadding(this.windowWidth),
          top: Spacing.S
        })
      }
      .layoutWeight(1)
      .width('100%')

      if (!this.showSidebar()) {
        this.BottomBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      // 横竖屏旋转、折叠展开、电脑窗口拖拽时都会回调，宽高需一并同步
      if (w > 0 && (Math.abs(w - this.windowWidth) > 1 || Math.abs(h - this.windowHeight) > 1)) {
        AppStorage.setOrCreate<number>('windowWidth', w);
        AppStorage.setOrCreate<number>('windowHeight', h);
      }
    })
    .bindSheet($$this.showDetailSheet, this.detailSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: Theme.paper,
      showClose: false,
      preferType: SheetType.CENTER
    })
  }

  @Builder
  detailSheet() {
    Column() {
      PersonDetailPanel({
        uid: this.selectedUid,
        showPrivate: this.showPrivate && !this.publicMode,
        narrow: true,
        onEdit: (uid: string): void => {
          this.showDetailSheet = false;
          RouterUtil.editPerson(this.getUIContext(), uid, 'edit', '');
        },
        onJump: (uid: string): void => {
          this.openPerson(uid);
        },
        onClose: (): void => {
          this.showDetailSheet = false;
        },
        onAddChild: (uid: string): void => {
          this.showDetailSheet = false;
          RouterUtil.editPerson(this.getUIContext(), '', 'child', uid);
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}