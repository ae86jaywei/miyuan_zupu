import { uiMaterial } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Breakpoint } from '../common/Constants';
import { Theme, Spacing } from '../theme/Theme';
import { Layout } from '../common/Layout';
import { GenealogyService } from '../service/GenealogyService';
import { Genealogy } from '../model/Genealogy';
import { GenealogyStore } from '../store/GenealogyStore';
import { GenealogyScope } from '../model/Scope';
import { TreeStyle } from '../model/Enums';

import { Person } from '../model/Person';

import { HomeView } from '../view/HomeView';
import { TreeCanvas } from '../view/TreeCanvas';
import { StyleSwitcher } from '../view/StyleSwitcher';
import { CatalogView } from '../view/CatalogView';
import { SettingsView } from '../view/SettingsView';
import { PersonDetailPanel } from '../view/PersonDetailPanel';
import { GenealogyStatsPanel } from '../view/GenealogyStatsPanel';
import { RouterUtil } from '../util/RouterUtil';
import { DeviceUtil } from '../util/DeviceUtil';
import { AccountService } from '../service/AccountService';
import { ConsentService } from '../service/ConsentService';
import { PrivacyConsentDialog } from '../view/PrivacyConsentDialog';
import { resourceManager } from '@kit.LocalizationKit';

const TAG: string = '[Genealogy][Index]';

/** 左侧导航栏宽度（vp）：展开态（图标 + 标题）/ 收起态（纯图标） */
const NAV_WIDTH_EXPANDED: number = 96;
const NAV_WIDTH_COLLAPSED: number = 68;

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
  @StorageProp('pagedMode') pagedMode: boolean = false;
  @StorageProp('windowHeight') windowHeight: number = 780;
  @StorageProp('gpVersion') version: number = 0;
  @StorageProp('gpReady') ready: boolean = false;
  @StorageProp('gpHasBook') hasBook: boolean = true;
  @StorageProp('gpBookId') bookId: number = 0;
  @StorageProp('gpBookTitle') bookTitle: string = '';
  @StorageProp('gpBookCount') bookCount: number = 0;
  @StorageProp('gpStyle') styleName: string = 'eu';
  @StorageProp('gpTab') currentTab: number = 1;
  @StorageProp('gpSelection') selectedUid: string = '';
  @StorageProp('gpPublicMode') publicMode: boolean = false;
  @StorageProp('gpShowPrivate') showPrivate: boolean = true;
  @StorageProp('gpLogin') loggedIn: boolean = false;
  @StorageProp('gpPendingShare') @Watch('onPendingShare') pendingShare: boolean = false;
  @StorageProp('gpSyncMode') syncMode: string = 'LOCAL';
  @StorageProp('gpFamilyRole') familyRole: string = '';
  @StorageProp('gpPendingCount') pendingCount: number = 0;
  @State showDetailSheet: boolean = false;
  /** 三栏模式下收起右侧详情，让树区占满整行；默认展开 */
  @State treeDetailCollapsed: boolean = false;
  /** 多族谱切换面板 */
  @State showBookPicker: boolean = false;
  /** 本地就绪标记（AppStorage 订阅作为兜底） */
  @State localReady: boolean = false;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  private switchingTab: boolean = false;
  private lastTabClickAt: number = 0;
  /** 隐私同意状态是否已读取完成 */
  private consentChecked: boolean = false;
  /** 隐私同意弹窗是否正在显示 */
  private consentDialogOpen: boolean = false;
  private privacyDialog: CustomDialogController | null = null;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  /** 回到前台 / 页面显示时同步一次系统配色 */
  onPageShow(): void {
    this.syncDarkMode();
    // 从协议页返回后，若仍未同意则重新弹出确认框
    if (this.consentChecked && !ConsentService.getInstance().hasAgreed()) {
      this.showPrivacyConsent();
    }
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
    this.bootstrapAfterConsent();
  }

  /** 隐私合规：未同意协议前不初始化数据、不登录账号 */
  private async bootstrapAfterConsent(): Promise<void> {
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined && ctx !== null) {
      await ConsentService.getInstance().init(ctx as common.UIAbilityContext);
    }
    this.consentChecked = true;
    if (!ConsentService.getInstance().hasAgreed()) {
      this.showPrivacyConsent();
      return;
    }
    this.startNormalFlow();
  }

  /** 已同意协议后的正常启动流程 */
  private startNormalFlow(): void {
    this.initData();
    this.initAccount();
    this.onPendingShare();
  }

  /** 首次启动 / 未同意协议时的隐私确认弹窗 */
  private showPrivacyConsent(): void {
    if (!this.consentChecked || ConsentService.getInstance().hasAgreed() || this.consentDialogOpen) {
      return;
    }
    this.consentDialogOpen = true;
    this.privacyDialog = new CustomDialogController({
      builder: PrivacyConsentDialog({
        onAgree: (): void => {
          this.handleConsentAgree();
        },
        onReject: (): void => {
          this.handleConsentReject();
        },
        onOpenDoc: (type: string): void => {
          this.handleOpenDoc(type);
        }
      }),
      autoCancel: false,
      alignment: DialogAlignment.Center
    });
    this.privacyDialog.open();
  }

  private async handleConsentAgree(): Promise<void> {
    this.consentDialogOpen = false;
    await ConsentService.getInstance().accept();
    this.startNormalFlow();
  }

  /** 不同意协议：直接退出应用，不进行任何数据处理 */
  private handleConsentReject(): void {
    this.consentDialogOpen = false;
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined && ctx !== null) {
      (ctx as common.UIAbilityContext).terminateSelf().catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'terminateSelf failed: %{public}s', err.message);
      });
    }
  }

  /** 查看协议全文：关闭弹窗并跳转协议页，返回后会自动再次弹出确认框 */
  private handleOpenDoc(type: string): void {
    this.consentDialogOpen = false;
    this.privacyDialog?.close();
    RouterUtil.agreement(this.getUIContext(), type);
  }

  /** 已有登录记录时尝试静默登录，避免每次启动都打扰用户 */
  private async initAccount(): Promise<void> {
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined || ctx === null) {
      return;
    }
    await AccountService.getInstance().init(ctx as common.UIAbilityContext);
    if (AccountService.getInstance().getUnionId().length > 0) {
      await AccountService.getInstance().trySilentLogin();
    }
  }

  /** 由 App Linking 分享链接唤起时，跳转到只读分享查看页 */
  onPendingShare(): void {
    if (!this.pendingShare) {
      return;
    }
    AppStorage.setOrCreate<boolean>('gpPendingShare', false);
    RouterUtil.sharedView(this.getUIContext());
  }

  private ensureStorage(): void {
    if (AppStorage.get<number>('windowWidth') === undefined) {
      // 首帧先用屏幕宽度兜底，窗口尺寸就绪后由根节点 onAreaChange 修正为真实宽度
      AppStorage.setOrCreate<number>('windowWidth', DeviceUtil.screenWidthVp());
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
    if (AppStorage.get<boolean>('gpPublicMode') === undefined) {
      AppStorage.setOrCreate<boolean>('gpPublicMode', false);
    }
    if (AppStorage.get<boolean>('gpShowPrivate') === undefined) {
      AppStorage.setOrCreate<boolean>('gpShowPrivate', true);
    }
    if (AppStorage.get<string>('gpOrientation') === undefined) {
      AppStorage.setOrCreate<string>('gpOrientation', 'follow_system');
    }
    if (AppStorage.get<number>('gpVersion') === undefined) {
      AppStorage.setOrCreate<number>('gpVersion', 0);
    }
    if (AppStorage.get<boolean>('gpReady') === undefined) {
      AppStorage.setOrCreate<boolean>('gpReady', false);
    }
    if (AppStorage.get<boolean>('gpHasBook') === undefined) {
      AppStorage.setOrCreate<boolean>('gpHasBook', true);
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

  private switchTab(index: number, animated: boolean): void {
    if (index === this.currentTab || this.switchingTab) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastTabClickAt < 320) {
      return;
    }
    this.lastTabClickAt = now;
    if (!animated) {
      AppStorage.setOrCreate<number>('gpTab', index);
      return;
    }
    this.switchingTab = true;
    this.getUIContext().animateTo({
      duration: 260,
      curve: Curve.FastOutSlowIn,
      onFinish: (): void => {
        this.switchingTab = false;
      }
    }, (): void => {
      AppStorage.setOrCreate<number>('gpTab', index);
    });
  }

  /**
   * 当前页面是否已有常驻的右侧详情栏。
   *
   * 只有谱系三栏（≥LG）和名录主从（≥MD）才有；其余宽度/页面必须用浮层，
   * 否则在平板、电脑窗口、折叠展开这种 MD~LG 区间里，点了人既没有浮层、
   * 也没有右侧栏，详情就完全看不到。
   */
  private hasDockedDetail(): boolean {
    if (this.currentTab === 1) {
      return this.isTriplePane() && !this.treeDetailCollapsed;
    }
    if (this.currentTab === 2) {
      return this.isMasterDetail();
    }
    return false;
  }

  private openPerson(uid: string): void {
    AppStorage.setOrCreate<string>('gpSelection', uid);
    if (!this.hasDockedDetail()) {
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
      // 横屏手机高度有限：导航项放进滚动区，底部“＋/人数/版本”始终可见，
      // 不会像原来那样被固定高度挤出屏幕、点不到新建按钮
      Scroll() {
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
              this.switchTab(idx, false);
            })
          }, (item: NavItem) => 'nav_' + item.key + '_' + (collapsed ? '1' : '0'))
        }
        .width('100%')
        .alignItems(collapsed ? HorizontalAlign.Center : HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .align(Alignment.Top)

      Text('＋')
        .fontSize(20)
        .fontColor('#FFFFFF')
        .width(collapsed ? 40 : 44)
        .height(40)
        .textAlign(TextAlign.Center)
        .backgroundColor(Theme.primary)
        .borderRadius(20)
        .onClick((): void => {
          if (!this.hasBook) {
            this.createGenealogy();
            return;
          }
          RouterUtil.editPerson(this.getUIContext(), '', 'create', '');
        })

      Text('人 ' + this.peopleCount().toString())
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .margin({ top: Spacing.S })

      Text('v1.0.0').fontSize(10).fontColor(Theme.inkTertiary).margin({ top: 2 })
      Column().height(Spacing.M)
    }
    .width(collapsed ? NAV_WIDTH_COLLAPSED : NAV_WIDTH_EXPANDED)
    .height(LayoutPolicy.matchParent)
    .padding({ top: Spacing.L, left: Spacing.S, right: Spacing.S })
    .backgroundColor(Theme.card)
    .border({ width: { right: 0.5 }, color: Theme.line })
  }

  /** 系统是否支持 HDS 沉浸材质（API 26 起），不支持时回退到毛玻璃模糊 */
  private immersiveMaterialSupported(): boolean {
    return deviceInfo.apiAvailable('26.0.0');
  }

  @Builder
  NavItems() {
    ForEach(NAV_ITEMS, (item: NavItem, idx: number) => {
      Column() {
        Text(item.icon)
          .fontSize(this.currentTab === idx ? 20 : 19)
          .opacity(this.currentTab === idx ? 1 : 0.6)
        Text(item.title)
          .fontSize(10)
          .fontColor(this.currentTab === idx ? Theme.primary : Theme.inkTertiary)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(16)
      .backgroundColor(this.currentTab === idx ? Theme.highlightBg : Color.Transparent)
      .onClick((): void => {
        this.switchTab(idx, true);
      })
    }, (item: NavItem) => 'bb_' + item.key)
  }

  /** 悬浮沉浸导航：毛玻璃材质 + 选中高亮，浮于内容之上（参考空间化自适应悬浮导航） */
  @Builder
  FloatingBottomBar() {
    Column() {
      if (this.immersiveMaterialSupported()) {
        // 新系统：HDS 沉浸光感材质，随内容与交互产生动态光效
        Row() {
          this.NavItems()
        }
        .width('100%')
        .height(56)
        .padding({ left: 5, right: 5, top: 5, bottom: 5 })
        .borderRadius(28)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          materialColor: Theme.card,
          interactive: true,
          lightEffect: { color: Theme.gold }
        }))
        .border({ width: 0.5, color: Theme.glassBorder })
        .shadow({ radius: 20, color: Theme.shadowDeep, offsetY: 6 })
      } else {
        // 旧系统：等效毛玻璃材质（半透明底 + 背景模糊）
        Row() {
          this.NavItems()
        }
        .width('100%')
        .height(56)
        .padding({ left: 5, right: 5, top: 5, bottom: 5 })
        .backgroundColor(Theme.glass)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .borderRadius(28)
        .border({ width: 0.5, color: Theme.glassBorder })
        .shadow({ radius: 20, color: Theme.shadowDeep, offsetY: 6 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 4 })
  }

  @Builder
  TreeToolbar() {
    Column() {
      // 多族谱切换入口：显示当前族谱，点击可切换或新建
      Row() {
        Text('谱')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.primary)
          .borderRadius(4)
        Text(this.bookTitle.length > 0 ? this.bookTitle : '未命名族谱')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.bookCount > 1 ? '共 ' + this.bookCount.toString() + ' 部' : '')
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
          .margin({ left: 6 })
        Text('切换 ⌄')
          .fontSize(11)
          .fontColor(Theme.primary)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(Theme.highlightBg)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor(Theme.field)
      .borderRadius(9)
      .margin({ bottom: 4 })
      .onClick((): void => {
        this.openBookPicker();
      })

      // 谱式导航栏只在「欧式/苏式 + 分页」时隐藏（版面优先），其它谱式始终显示。
      // 条件不只看 pagedMode，还要求当前是欧式/苏式：即使分页状态残留，
      // 切到宝塔/牒记/现代等谱式也一定能看到导航栏，不会再“消失”。
      if (!this.inPagedView()) {
        Row() {
          StyleSwitcher({
            current: this.styleName,
            windowWidth: this.layoutWidth(),
            onSelect: (style: string): void => {
              // 选中的就是当前谱式时什么也不做：用户只是在看导航栏，不该被踢出分页视图
              if (style === this.styleName) {
                return;
              }
              // 换谱式即退出「欧式/苏式分页」：页面导航栏是共享的，
              // 不在这里复位的话，再切回欧式/苏式时会直接落进分页视图。
              AppStorage.setOrCreate<boolean>('pagedMode', false);
              GenealogyStore.setStyle(style);
            }
          })
        }
        .width('100%')
      }

      if (!this.inPagedView()) {
        Row() {
          // 横屏手机可用高度小：这一行提示让位给树画布，只保留操作按钮
          if (this.styleName !== TreeStyle.DIE && this.windowHeight >= 560) {
            Text('📐 双指缩放 · 拖动平移 · 点击人物查看详情')
              .fontSize(11)
              .fontColor(Theme.inkTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          // 详情收起后给出恢复入口，避免用户找不到右侧卡片
          if (this.isTriplePane() && this.treeDetailCollapsed) {
            Text('详情 ›')
              .fontSize(12)
              .fontColor(Theme.primary)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .border({ width: 1, color: Theme.primary })
              .margin({ right: Spacing.S })
              .onClick((): void => {
                this.treeDetailCollapsed = false;
              })
          }
          Text('新增族人')
            .fontSize(12)
            .fontColor(Theme.primary)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .border({ width: 1, color: Theme.primary })
            .onClick((): void => {
              if (!this.hasBook) {
                this.createGenealogy();
                return;
              }
              RouterUtil.editPerson(this.getUIContext(), '', 'create', '');
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 6 })
      }
    }
    .width('100%')
  }

  @Builder
  TreePane() {
    Column() {
      this.TreeContent()
    }
    .width('100%')
    .height('100%')
    .padding({ top: 0 })
  }

  /**
   * 树区内容（工具栏 + 画布），不含外层宽度。
   *
   * 三栏布局必须由外部用 layoutWeight 分配宽度：这里再写 width('100%')
   * 会让树区占满整行，把右侧固定宽度的详情栏顶出屏幕（PC/平板/折叠展开都这样）。
   */
  @Builder
  TreeContent() {
    this.TreeToolbar()
    TreeCanvas({
      style: this.styleName,
      highlightUid: this.selectedUid,
      showPrivate: this.showPrivate && !this.publicMode,
      windowWidth: this.layoutWidth(),
      onTapPerson: (uid: string): void => {
        this.openPerson(uid);
      },
      onFocusPerson: (uid: string): void => {
        // 查找跳转：仅高亮定位，不打开人员卡片
        AppStorage.setOrCreate<string>('gpSelection', uid);
      }
    })
      .width('100%')
      .layoutWeight(1)
  }

  @Builder
  DetailPane() {
    Stack({ alignContent: Alignment.TopEnd }) {
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
        },
        onCreateBranch: (uid: string): void => {
          this.createBranch(uid);
        }
      })
      // 三栏时允许收起详情，树区可占满整行宽度
      if (this.isTriplePane() && !this.treeDetailCollapsed) {
        Text('收起 ›')
          .fontSize(11)
          .fontColor(Theme.primary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(Theme.glass)
          .borderRadius(10)
          .margin({ top: Spacing.S, right: Spacing.S })
          .zIndex(2)
          .onClick((): void => {
            this.treeDetailCollapsed = true;
          })
      }
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
      windowWidth: this.layoutWidth(),
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
      windowWidth: this.layoutWidth()
    })
  }

  /** 新增一部空族谱，并引导用户完善族谱信息 */
  private async createGenealogy(): Promise<void> {
    try {
      await GenealogyService.getInstance().createGenealogy('');
      GenealogyStore.notifyChanged();
      // 创建后直接进入族谱信息编辑态
      AppStorage.setOrCreate<boolean>(GenealogyStore.KEY_EDITING_BOOK, true);
      AppStorage.setOrCreate<number>('gpTab', 4);
      this.getUIContext().getPromptAction().showToast({ message: '已创建族谱，请填写族谱信息' });
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: '创建族谱失败：' + err.message });
    }
  }

  /** 打开族谱切换面板；无族谱时直接进入新建流程 */
  private openBookPicker(): void {
    if (!this.hasBook) {
      this.createGenealogy();
      return;
    }
    this.showBookPicker = true;
  }

  /** 切换当前族谱，概览/名录/统计会跟随刷新 */
  private async switchBook(bookKey: number): Promise<void> {
    this.showBookPicker = false;
    if (bookKey === this.bookId) {
      return;
    }
    try {
      await GenealogyService.getInstance().switchGenealogy(bookKey);
      GenealogyStore.notifyChanged();
      AppStorage.setOrCreate<string>('gpSelection', '');
      this.showDetailSheet = false;
      this.getUIContext().getPromptAction().showToast({
        message: '已切换到《' + GenealogyService.getInstance().getBook().title + '》'
      });
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: '切换族谱失败：' + err.message });
    }
  }

  /** 以某位族人为始祖另立分支族谱（复制其本人、配偶与全部后代，原族谱不受影响） */
  private createBranch(uid: string): void {
    const p: Person | null = GenealogyService.getInstance().getPerson(uid);
    if (p === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '创建分支',
      message: '将以「' + p.name + '（' + p.uid + '）」为第一世（始祖）另立分支族谱，'
        + '并复制其配偶与全部后代。分支数据独立，原族谱不受影响。确认创建？',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '创建',
        action: (): void => {
          GenealogyService.getInstance().createBranchFromPerson(uid)
            .then((book: Genealogy): void => {
              GenealogyStore.notifyChanged();
              AppStorage.setOrCreate<string>('gpSelection', '');
              this.showDetailSheet = false;
              this.showBookPicker = false;
              this.getUIContext().getPromptAction().showToast({
                message: '已创建分支《' + book.title + '》，可继续录入族人'
              });
            })
            .catch((err: BusinessError): void => {
              this.getUIContext().getPromptAction().showToast({ message: '创建分支失败：' + err.message });
            });
        }
      }
    });
  }

  /** 分支谱所属母谱的谱名 */
  private parentBookTitle(book: Genealogy): string {
    if (book.parentBookId <= 0) {
      return '';
    }
    const books: Genealogy[] = GenealogyService.getInstance().getBooks();
    for (let i: number = 0; i < books.length; i++) {
      if (books[i].key === book.parentBookId) {
        return books[i].title.length > 0 ? books[i].title : '未命名族谱';
      }
    }
    return '未知';
  }

  private noBookDesc(): string {
    if (this.currentTab === 2) {
      return '族谱尚未创建。请先到「谱系」新增族谱并录入族人，名录会自动汇总世系信息。';
    }
    if (this.currentTab === 3) {
      return '族谱尚未创建。请先到「谱系」新增族谱，统计会展示人口结构、世代繁衍与资料完整度。';
    }
    return '族谱尚未创建。请先到「谱系」新增族谱，即可在此查看族谱封面、人口与世代概览。';
  }

  /** 谱系页空状态：大号 + 号新增族谱入口 */
  @Builder
  EmptyTreePane() {
    Column() {
      Column() {
        Text('＋')
          .fontSize(40)
          .fontColor('#FFFFFF')
          .width(76)
          .height(76)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.primary)
          .borderRadius(38)
          .shadow({ radius: 12, color: Theme.shadowDeep, offsetY: 4 })
          .onClick((): void => {
            this.createGenealogy();
          })
        Text('新增族谱')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .margin({ top: Spacing.L })
          .onClick((): void => {
            this.createGenealogy();
          })
        Text('当前没有族谱，点击上方 + 号新建一部族谱')
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 6 })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding(Spacing.XXL)
      .backgroundColor(Theme.card)
      .borderRadius(16)
      .border({ width: 0.5, color: Theme.line })
      .margin({ top: Spacing.XL, left: Spacing.M, right: Spacing.M })
    }
    .width('100%')
    .height('100%')
  }

  /** 概览 / 名录 / 统计 无族谱时的引导 */
  @Builder
  NoBookGuide() {
    Column() {
      Text('📜').fontSize(46).opacity(0.65)
      Text('尚未创建族谱')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.ink)
        .margin({ top: Spacing.L })
      Text(this.noBookDesc())
        .fontSize(12.5)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)
        .padding({ left: Spacing.XL, right: Spacing.XL })
      Button('前往「谱系」新增族谱')
        .fontSize(14)
        .height(38)
        .backgroundColor(Theme.primary)
        .fontColor('#FFFFFF')
        .margin({ top: Spacing.XL })
        .onClick((): void => {
          AppStorage.setOrCreate<number>('gpTab', 1);
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Spacing.XXL)
  }

  /** 族谱切换面板：列出全部族谱，支持切换与新建 */
  @Builder
  BookPickerSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => {
          this.showBookPicker = false;
        })

      Column() {
        Row() {
          Text('切换族谱')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.ink)
          Blank()
          Text('＋ 新建族谱')
            .fontSize(12)
            .fontColor(Theme.primary)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor(Theme.highlightBg)
            .onClick((): void => {
              this.showBookPicker = false;
              this.createGenealogy();
            })
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.M })

        Scroll() {
          Column() {
            ForEach(GenealogyService.getInstance().getBooks(), (book: Genealogy) => {
              Row() {
                Column() {
                  Text(book.title.length > 0 ? book.title : '未命名族谱')
                    .fontSize(14)
                    .fontWeight(book.key === this.bookId ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(Theme.ink)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(book.parentBookId > 0
                    ? '分支 · 出自《' + this.parentBookTitle(book) + '》'
                    : (book.hallName.length > 0 ? book.hallName : '未填写堂号'))
                    .fontSize(11)
                    .fontColor(book.parentBookId > 0 ? Theme.gold : Theme.inkTertiary)
                    .margin({ top: 2 })
                    .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (book.key === this.bookId) {
                  Text('当前')
                    .fontSize(11)
                    .fontColor(Theme.primary)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(9)
                    .backgroundColor(Theme.highlightBg)
                }
              }
              .width('100%')
              .padding({ left: Spacing.L, right: Spacing.L, top: 12, bottom: 12 })
              .backgroundColor(book.key === this.bookId ? Theme.field : Color.Transparent)
              .onClick((): void => {
                this.switchBook(book.key);
              })
            }, (book: Genealogy) => 'book_' + book.key.toString())
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: 380 })
        .scrollBar(BarState.Off)

        Button('关闭')
          .fontSize(14)
          .height(38)
          .width('100%')
          .backgroundColor(Theme.field)
          .fontColor(Theme.inkSecondary)
          .margin({ top: Spacing.M, bottom: Spacing.XL })
          .onClick((): void => {
            this.showBookPicker = false;
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 520 })
      .padding({ left: Spacing.L, right: Spacing.L })
      .backgroundColor(Theme.card)
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ContentBody() {
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

  @Builder
  ContentArea() {
    if (!this.hasBook && this.currentTab !== 4) {
      if (this.currentTab === 1) {
        this.EmptyTreePane()
      } else {
        this.NoBookGuide()
      }
    } else if (this.currentTab === 0) {
      HomeView({
        version: this.version,
        windowWidth: this.layoutWidth(),
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
            this.TreeContent()
          }
          // 必须显式给宽度：layoutWeight(1) 会把整行吃光，
          // 树画布的最小内容宽度又撑得住，右侧详情列被推到行外被 clip 裁掉
          .width(this.treePaneWidth())
          .height(LayoutPolicy.matchParent)
          if (!this.treeDetailCollapsed) {
            Column() {
              this.DetailPane()
            }
            // 840~1200 窄三栏时详情收窄到 280，给树区留出可用的画布宽度
            .width(this.detailPaneWidth())
            // 宽度必须固定：不加 flexShrink(0) 会被树区挤成一条，看起来像详情溢出消失
            .flexShrink(0)
            .height(LayoutPolicy.matchParent)
            .margin({ left: Spacing.M })
            .padding({ top: Spacing.M })
          }
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        .clip(true)
      } else {
        this.TreePane()
      }
    } else if (this.currentTab === 2) {
      if (this.isMasterDetail()) {
        Row() {
          Column() {
            this.CatalogPane()
          }
          // 与谱系三栏同理：layoutWeight 会吃满整行把详情栏推出屏幕，必须显式给宽
          .width(this.catalogPaneWidth())
          .height(LayoutPolicy.matchParent)
          Column() {
            this.DetailPane()
          }
          .width(this.catalogDetailWidth())
          // 与谱系三栏同理：详情宽度固定，不被左侧名录挤掉
          .flexShrink(0)
          .height(LayoutPolicy.matchParent)
          .margin({ left: Spacing.L })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        .clip(true)
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

  /** 协作态角标：仅本机 / 已接入（角色 + 待传数） */
  private familyBadge(): string {
    if (this.syncMode === 'LOCAL') {
      return this.hasBook ? '仅本机' : '';
    }
    const role: string = this.familyRole === 'OWNER' ? '谱主' :
      (this.familyRole === 'EDITOR' ? '编辑' : (this.familyRole === 'VIEWER' ? '只读' : '协作'));
    return role + (this.pendingCount > 0 ? ' · 待传' + this.pendingCount.toString() : '');
  }

  private peopleCount(): number {
    return GenealogyService.getInstance().getPeople().length;
  }

  /** 手机（含横屏）不按大屏处理：横屏时仍用窄屏布局，避免侧栏把内容整体右移 */
  private isPhone(): boolean {
    return DeviceUtil.deviceType() === 'phone';
  }

  /** 布局宽度：手机取短边，横屏不会被当成平板/折叠展开的阔屏 */
  private layoutWidth(): number {
    if (this.isPhone()) {
      return Math.min(this.windowWidth, this.windowHeight);
    }
    return this.windowWidth;
  }

  private isMasterDetail(): boolean {
    return this.layoutWidth() >= Breakpoint.MD;
  }

  /**
   * 谱系三栏阈值：对齐鸿蒙官方 lg 断点（≥840vp）。
   * 平板横屏全屏约 1198vp、电脑窗口化多落在 840~1200 区间，
   * 若按 1200 判定这些设备永远出不了三栏，详情预览只能靠浮层甚至完全看不见。
   *
   * 折叠屏（双屏 / 三屏展开）额外放宽到 sm 断点：这类设备手机取短边后
   * 只有 700~800vp，永远到不了 840，展开态只能用浮层看详情。
   */
  private isTriplePane(): boolean {
    if (this.layoutWidth() >= Breakpoint.MD) {
      return true;
    }
    return DeviceUtil.isFoldable() && this.windowWidth >= Breakpoint.SM;
  }

  /**
   * 是否处于「欧式/苏式分页」视图。
   * 分页只是欧式/苏式的子视图：其它谱式一律按连续视图处理，
   * 这样即使 pagedMode 因为异步时序没来得及复位，谱式导航栏也不会被藏掉。
   */
  private inPagedView(): boolean {
    if (this.styleName !== TreeStyle.EU && this.styleName !== TreeStyle.SU) {
      return false;
    }
    return this.pagedMode;
  }

  private showSidebar(): boolean {
    // 手机竖屏用底部导航；手机横屏改为左侧竖向导航（底部栏太占纵向空间）。
    // 平板/折叠/阔屏仍按宽度走多栏布局。
    if (this.isPhone()) {
      return this.windowWidth > this.windowHeight;
    }
    return this.layoutWidth() >= Breakpoint.SM;
  }

  private sidebarCollapsed(): boolean {
    return this.layoutWidth() < Breakpoint.MD;
  }

  /**
   * 内容列可用宽度（vp）：窗口宽 - 侧栏 - 左右页边距。
   *
   * ArkUI 的 width('100%') 以父的 padding-box 为基准，父级再设 padding 时
   * 内容会整体右移一个边距宽度，把最右侧的「切换」「新增族人」顶出屏幕。
   * 用 constraintSize 把它收敛到真实可用宽度，比百分比/calc 可靠。
   */
  private contentAvailWidth(hasSidebar: boolean): number {
    const nav: number = hasSidebar ?
      (this.sidebarCollapsed() ? NAV_WIDTH_COLLAPSED : NAV_WIDTH_EXPANDED) : 0;
    const pad: number = Layout.pagePadding(this.windowWidth);
    return Math.max(160, this.windowWidth - nav - pad * 2);
  }

  /** 内容区实际可用总宽（与内容列 constraintSize 的上限保持一致） */
  private paneRowWidth(): number {
    return Math.min(Layout.contentMaxWidth(this.windowWidth), this.contentAvailWidth(this.showSidebar()));
  }

  /** 三栏右侧详情栏宽度：窄三栏收窄到 280，宽屏最多 340 */
  private detailPaneWidth(): number {
    return Math.min(340, Math.max(280, this.paneRowWidth() * 0.28));
  }

  /** 三栏左侧树区宽度：总宽扣掉详情栏与间距；详情收起时占满整行 */
  private treePaneWidth(): number {
    const row: number = this.paneRowWidth();
    if (this.treeDetailCollapsed) {
      return row;
    }
    return Math.max(200, row - this.detailPaneWidth() - Spacing.M);
  }

  /** 名录主从布局的右侧详情宽度 */
  private catalogDetailWidth(): number {
    return Math.max(300, Math.min(380, this.paneRowWidth() * 0.36));
  }

  /** 名录主从布局的左侧列表宽度 */
  private catalogPaneWidth(): number {
    return Math.max(200, this.paneRowWidth() - this.catalogDetailWidth() - Spacing.L);
  }

  /**
   * 详情浮层卡片宽度。
   *
   * 居中弹窗的背板宽约 480vp 且与窗口宽度无关；横屏手机上卡片若按背板比例铺开，
   * 上部内容稀疏的行右侧会空出一大片。手机横屏固定为与竖屏观感一致的窄卡片，
   * 其它形态仍按背板 5/6 展示。
   */
  private detailCardWidth(): Length {
    if (this.isPhone() && this.windowWidth > this.windowHeight) {
      return Math.min(340, this.windowWidth - 40);
    }
    return '83.3%';
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 顶部品牌栏（大屏显示完整标题，小屏显示精简标题）
        Row() {
          Text(this.hasBook ? (this.bookTitle.length > 0 ? this.bookTitle : '未命名族谱') : '尚未创建族谱')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.ink)
          if (this.hasBook && GenealogyService.getInstance().getBook().hallName.length > 0) {
            Text('· ' + GenealogyService.getInstance().getBook().hallName)
              .fontSize(12)
              .fontColor(Theme.gold)
              .margin({ left: 6 })
              .maxLines(1)
          }
          Blank()
          Text(!this.isPhone() && this.showSidebar() ? Layout.deviceLabel(this.windowWidth) : '')
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
          Text(this.familyBadge())
            .fontSize(11)
            .fontColor(this.syncMode !== 'LOCAL' ? Theme.alive : Theme.inkTertiary)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor(this.syncMode !== 'LOCAL' ? Theme.field : Color.Transparent)
            .margin({ right: Spacing.S })
            .onClick((): void => {
              if (this.loggedIn) {
                RouterUtil.familyHome(this.getUIContext());
              } else {
                RouterUtil.login(this.getUIContext());
              }
            })
          Text(this.loggedIn ? '已登录' : '登录')
            .fontSize(11)
            .fontColor(this.loggedIn ? Theme.gold : Theme.primary)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor(this.loggedIn ? Theme.field : Theme.highlightBg)
            .margin({ left: Spacing.S })
            .onClick((): void => {
              if (this.loggedIn) {
                AppStorage.setOrCreate<number>('gpTab', 4);
              } else {
                RouterUtil.login(this.getUIContext());
              }
            })
          Text('⚙')
            .fontSize(15)
            .fontColor(Theme.inkSecondary)
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .margin({ left: Spacing.S })
            .onClick((): void => {
              AppStorage.setOrCreate<number>('gpTab', 4);
            })
        }
        .width('100%')
        .height(28)
        .padding({ left: Layout.pagePadding(this.windowWidth), right: Layout.pagePadding(this.windowWidth) })
        .backgroundColor(Theme.card)
        .shadow({ radius: 6, color: Theme.shadowDeep, offsetY: 2 })

        if (this.showSidebar()) {
          Row() {
            this.NavBar(this.sidebarCollapsed())
            Column() {
              Column() {
                this.ContentBody()
              }
              .width('100%')
              .height('100%')
              // 收敛到真实可用宽度：父级有 padding 时 width('100%') 会多出一个边距，
              // 最右侧「切换」「新增族人」被顶出屏幕（手机横屏必现）
              .constraintSize({
                maxWidth: Math.min(Layout.contentMaxWidth(this.windowWidth), this.contentAvailWidth(true))
              })
            }
            // 宽度必须交给 Row 分配：windowWidth 是断点用的代表值（400/720/1000），
            // 拿它减侧栏宽度会让内容列比实际窗口宽，横屏/分屏时右侧被裁掉
            .layoutWeight(1)
            .height(LayoutPolicy.matchParent)
            .padding({
              left: Layout.pagePadding(this.windowWidth),
              right: Layout.pagePadding(this.windowWidth),
              top: 0,
              bottom: 0
            })
            .onAreaChange((oldValue: Area, newValue: Area): void => {
              hilog.info(0x0000, TAG, 'content column h=%{public}d w=%{public}d sidebar=true',
                Number(newValue.height), Number(newValue.width));
            })
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          Column() {
            Column() {
              this.ContentBody()
            }
            .width('100%')
            .height('100%')
            .constraintSize({
              maxWidth: Math.min(Layout.contentMaxWidth(this.windowWidth), this.contentAvailWidth(false))
            })
          }
          .width('100%')
          .layoutWeight(1)
          .padding({
            left: Layout.pagePadding(this.windowWidth),
            right: Layout.pagePadding(this.windowWidth),
            top: 0,
            bottom: 0
          })
          .onAreaChange((oldValue: Area, newValue: Area): void => {
            hilog.info(0x0000, TAG, 'content column h=%{public}d w=%{public}d sidebar=false',
              Number(newValue.height), Number(newValue.width));
          })

          // 竖屏始终保留底部 tab：分页状态下也要能直接切回其它页面，
          // 否则横屏分页转竖屏后导航会消失。
          this.FloatingBottomBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.paper)

      if (this.showBookPicker) {
        this.BookPickerSheet()
      }
    }
    .width('100%')
    .height('100%')
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
      // 背板透明：宽度由内部卡片控制（系统居中弹窗的背板宽度随机型变化，
      // 直接铺底色会让详情右侧空出一大片）。拖拽条/阴影/模糊一并关掉，
      // 避免透明背板上残留系统装饰。
      dragBar: false,
      backgroundColor: Color.Transparent,
      blurStyle: BlurStyle.NONE,
      shadow: { radius: 0 },
      showClose: false,
      preferType: SheetType.CENTER
    })
  }

  @Builder
  detailSheet() {
    // 背板透明后，左右留白仍属半模态本体，不会触发「点外部关闭」。
    // 用 Stack 铺一层透明背景承接点击，详情卡片叠在上层，点卡片内部不误触。
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick((): void => {
          this.showDetailSheet = false;
        })
      // 卡片按背板宽度的 5/6 展示，让详情不再紧贴背板铺满、右侧留白过多
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
          },
          onCreateBranch: (uid: string): void => {
            this.createBranch(uid);
          }
        })
      }
      .width(this.detailCardWidth())
      .height('100%')
      .backgroundColor(Theme.card)
      .borderRadius(20)
      .clip(true)
      .shadow({ radius: 16, color: Theme.shadow, offsetY: 2 })
    }
    .width('100%')
    .height('100%')
  }
}
