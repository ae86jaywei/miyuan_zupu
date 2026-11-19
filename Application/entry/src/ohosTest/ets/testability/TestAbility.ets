import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

/**
 * 仪器化测试宿主 Ability：为 ohosTest 用例提供可用的 UIAbilityContext（数据库等系统 API 需要）。
 */
export default class TestAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('testability/pages/Index');
  }
}
