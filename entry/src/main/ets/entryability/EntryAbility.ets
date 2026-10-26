import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { GenealogyService } from '../service/GenealogyService';
import { GenealogyScope } from '../model/Scope';
import { AccountService } from '../service/AccountService';
import { CloudSyncService } from '../service/CloudSyncService';
import { DisplayService } from '../service/DisplayService';
import { Theme } from '../theme/Theme';
import { resourceManager } from '@kit.LocalizationKit';

const TAG: string = '[Genealogy][EntryAbility]';

/**
 * 应用入口。
 * 负责：数据库初始化、沉浸式窗口、屏幕方向偏好、全局字体缩放兼容、设备形态记录。
 */
export default class EntryAbility extends UIAbility {
  /** 主窗口引用，用于跟随深浅色刷新系统栏配色 */
  private mainWindow?: window.Window;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 屏幕方向偏好：读取用户设置并广播到 AppStorage（电脑/折叠屏固定跟随系统）
    DisplayService.getInstance().init(this.context);
    // 跟随系统深浅色（应用已适配深色主题，见 theme/Theme.ets）
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'setColorMode failed: %{public}s', JSON.stringify(e));
    }
    // 初始深浅色（后续切换由 onConfigurationUpdate 推送）
    try {
      const rm = this.context.resourceManager;
      AppStorage.setOrCreate<boolean>('darkMode', rm.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK);
    } catch (e) {
      AppStorage.setOrCreate<boolean>('darkMode', false);
    }
    GenealogyScope.set(this.context);
    GenealogyService.getInstance().init(this.context)
      .then((): void => {
        hilog.info(0x0000, TAG, 'database initialised');
      })
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'database init failed: %{public}d %{public}s', err.code, err.message);
      });

    // 账号与云同步服务（幂等）：读取缓存登录态、初始化 AGC 与云开发服务
    CloudSyncService.getInstance().init(this.context);
    AccountService.getInstance().init(this.context)
      .catch((err: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'account init failed: %{public}s', err.message);
      });

    // App Linking：分享链接拉起应用时记录族谱归属
    this.handleShareLink(want);
  }

  /** 应用已在运行时再次被分享链接唤起 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleShareLink(want);
  }

  /**
   * 解析分享链接中的 owner / familyId。
   * 预留能力：当前未配置公网域名，分享走「文本 + 邀请码」，链接拉起暂不生效。
   * 若后续配置 App Linking，链接形如 https://{域名}/family?familyId=xxx&owner=hw-xxx
   */
  private handleShareLink(want: Want): void {
    const uri: string | undefined = want.uri;
    if (uri === undefined || uri.length === 0) {
      return;
    }
    const queryIndex: number = uri.indexOf('?');
    if (queryIndex < 0 || queryIndex >= uri.length - 1) {
      return;
    }
    const query: string = uri.substring(queryIndex + 1);
    const pairs: string[] = query.split('&');
    let owner: string = '';
    let familyId: string = '';
    for (let i: number = 0; i < pairs.length; i++) {
      const pair: string = pairs[i];
      const eq: number = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key: string = pair.substring(0, eq);
      const value: string = decodeURIComponent(pair.substring(eq + 1));
      if (key === 'owner') {
        owner = value;
      } else if (key === 'familyId') {
        familyId = value;
      }
    }
    if (owner.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>('gpSharedOwner', owner);
    AppStorage.setOrCreate<string>('gpSharedFamilyId', familyId);
    AppStorage.setOrCreate<boolean>('gpPendingShare', true);
    hilog.info(0x0000, TAG, 'share link received, owner=%{public}s', owner);
  }

  /**
   * 系统深浅色切换时由框架回调（无需重启应用）。
   * 注意：必须在 Ability 侧接收后广播到 AppStorage，UI 才能即时刷新。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    const dark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>('darkMode', dark);
    // 系统栏图标与底色同步切换，避免深色模式下状态栏文字看不清
    this.applySystemBarStyle(dark);
    hilog.info(0x0000, TAG, 'darkMode updated: %{public}s', String(dark));
  }

  /**
   * 系统状态栏 / 导航栏配色。
   * 状态栏与页面顶部栏同色（Theme.card），导航栏与页面底色同色（Theme.paper），
   * 营造顶部、底部与系统栏视觉连贯的沉浸效果。
   */
  private applySystemBarStyle(isDark: boolean): void {
    if (!this.mainWindow) {
      return;
    }
    try {
      Theme.use(isDark);
      this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: Theme.card,
        statusBarContentColor: isDark ? '#FFFFFF' : '#000000',
        navigationBarColor: Theme.paper,
        navigationBarContentColor: isDark ? '#FFFFFF' : '#000000'
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.getMainWindow()
      .then((mainWindow: window.Window): void => {
        this.mainWindow = mainWindow;
        try {
          mainWindow.setWindowLayoutFullScreen(false);
        } catch (e) {
          hilog.warn(0x0000, TAG, 'layout fullscreen not supported');
        }
        const dark: boolean = AppStorage.get<boolean>('darkMode') ?? false;
        this.applySystemBarStyle(dark);
        // 主窗口就绪后下发屏幕方向：手机/平板按用户设置生效，
        // 折叠屏跟随桌面，电脑由系统统一调度（服务内部自动判断）
        const displaySvc: DisplayService = DisplayService.getInstance();
        displaySvc.setMainWindow(mainWindow);
        displaySvc.apply();
      })
      .catch((err: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'getMainWindow failed %{public}d', err.code);
      });

    windowStage.loadContent('pages/Index', (err: BusinessError): void => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent failed %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'content loaded');
    });
  }
}
