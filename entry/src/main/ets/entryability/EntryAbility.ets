import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { GenealogyService } from '../service/GenealogyService';
import { GenealogyScope } from '../model/Scope';
import { resourceManager } from '@kit.LocalizationKit';

const TAG: string = '[Genealogy][EntryAbility]';

/**
 * 应用入口。
 * 负责：数据库初始化、沉浸式窗口、全局字体缩放兼容、设备形态记录。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
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
  }

  /**
   * 系统深浅色切换时由框架回调（无需重启应用）。
   * 注意：必须在 Ability 侧接收后广播到 AppStorage，UI 才能即时刷新。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    const dark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>('darkMode', dark);
    hilog.info(0x0000, TAG, 'darkMode updated: %{public}s', String(dark));
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.getMainWindow()
      .then((mainWindow: window.Window): void => {
        try {
          mainWindow.setWindowLayoutFullScreen(false);
        } catch (e) {
          hilog.warn(0x0000, TAG, 'layout fullscreen not supported');
        }
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
