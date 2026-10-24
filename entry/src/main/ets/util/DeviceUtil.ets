import { mediaquery } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Breakpoint, DeviceForm } from '../common/Constants';

/**
 * 设备与窗口形态识别 + 断点监听。
 *
 * HarmonyOS 在应用侧统一以“窗口宽度 + deviceType”做一多适配：
 *  - 手机                        约 320~430vp（XS）
 *  - 双折叠（折叠 / 展开）        390 / 700~840vp（XS / SM~MD）
 *  - 阔折叠（Pocket 展开）        约 560~620vp（SM）
 *  - 阔屏（大直板 / 平板竖屏）    600~800vp（SM~MD）
 *  - 平板横屏 / 三折叠展开        840~1100vp（MD~LG）
 *  - 电脑（2in1）窗口、超宽屏     1200vp+（LG/XL）
 */
export class DeviceUtil {
  /**
   * 注册官方 mediaquery 断点监听（smsm/md/lg），并把窗口宽度写入 AppStorage['windowWidth']。
   * 折叠屏展开/折叠、电脑窗口拖拽时都会自动回调，实现无缝切换布局。
   */
  static listenBreakpoints(uiContext: UIContext): void {
    try {
      // XS：手机 / 折叠态 / 阔折叠折叠态
      uiContext.getMediaQuery().matchMediaSync('(width<600vp)').on('change',
        (result: mediaquery.MediaQueryResult): void => {
          if (result.matches) {
            AppStorage.setOrCreate<number>('windowWidth', 400);
          }
        });
      // SM：阔屏 / 阔折叠展开 / 小尺寸平板
      uiContext.getMediaQuery().matchMediaSync('(600vp<=width<840vp)').on('change',
        (result: mediaquery.MediaQueryResult): void => {
          if (result.matches) {
            AppStorage.setOrCreate<number>('windowWidth', 720);
          }
        });
      // MD：平板横屏 / 双折叠展开
      uiContext.getMediaQuery().matchMediaSync('(840vp<=width<1200vp)').on('change',
        (result: mediaquery.MediaQueryResult): void => {
          if (result.matches) {
            AppStorage.setOrCreate<number>('windowWidth', 1000);
          }
        });
      // LG/XL：电脑、三折叠展开、超宽屏
      uiContext.getMediaQuery().matchMediaSync('(1200vp<=width)').on('change',
        (result: mediaquery.MediaQueryResult): void => {
          if (result.matches) {
            AppStorage.setOrCreate<number>('windowWidth', 1300);
          }
        });
    } catch (e) {
      // 预览器或旧版本不支持时忽略（仍由 onAreaChange 驱动）
    }
  }

  /** 当前宽度对应的断点 */
  static breakpointOf(width: number): string {
    if (width >= Breakpoint.XL) {
      return 'XL';
    }
    if (width >= Breakpoint.LG) {
      return 'LG';
    }
    if (width >= Breakpoint.MD) {
      return 'MD';
    }
    if (width >= Breakpoint.SM) {
      return 'SM';
    }
    return 'XS';
  }

  /** 是否为宽屏布局（平板 / 折叠展开 / 电脑） */
  static isWide(width: number): boolean {
    return width >= Breakpoint.SM;
  }

  /** 是否为桌面级布局（电脑 / 三折叠展开） */
  static isDesktop(width: number): boolean {
    return width >= Breakpoint.LG;
  }

  /**
   * 识别具体设备形态（用于提示文案、布局微调）。
   * width / height 单位为 vp。
   */
  static formOf(width: number, height: number): DeviceForm {
    const dt: string = DeviceUtil.deviceType();
    const shortSide: number = Math.min(width, height);
    const longSide: number = Math.max(width, height);
    if (dt === '2in1') {
      return DeviceForm.PC;
    }
    if (dt === 'tablet') {
      return DeviceForm.TABLET;
    }
    if (dt === 'phone') {
      if (shortSide >= 600 || width >= 1000) {
        // 三折叠展开：接近平板宽度
        return width >= 1000 ? DeviceForm.TRIPLE_FOLD_UNFOLDED : DeviceForm.DUAL_FOLD_UNFOLDED;
      }
      if (width >= 700) {
        return DeviceForm.DUAL_FOLD_UNFOLDED;
      }
      if (width >= 560) {
        return DeviceForm.WIDE_FOLD_UNFOLDED;
      }
      if (width >= 500) {
        return DeviceForm.WIDE_FOLD_FOLDED;
      }
      if (width >= 380 && longSide >= 800) {
        return DeviceForm.TRIPLE_FOLD_FOLDED;
      }
      return DeviceForm.PHONE;
    }
    return DeviceForm.PHONE;
  }

  /** 设备形态中文描述（展示在设置页信息卡） */
  static formLabel(form: DeviceForm): string {
    switch (form) {
      case DeviceForm.PC:
        return '电脑（2in1）';
      case DeviceForm.TABLET:
        return '平板';
      case DeviceForm.TRIPLE_FOLD_UNFOLDED:
        return '三折叠 · 展开';
      case DeviceForm.TRIPLE_FOLD_FOLDED:
        return '三折叠 · 折叠';
      case DeviceForm.DUAL_FOLD_UNFOLDED:
        return '双折叠 · 展开';
      case DeviceForm.DUAL_FOLD_FOLDED:
        return '双折叠 · 折叠';
      case DeviceForm.WIDE_FOLD_UNFOLDED:
        return '阔折叠 · 展开';
      case DeviceForm.WIDE_FOLD_FOLDED:
        return '阔折叠 · 折叠';
      default:
        return '手机';
    }
  }

  /** 系统 deviceType */
  static deviceType(): string {
    try {
      return deviceInfo.deviceType;
    } catch (e) {
      return 'phone';
    }
  }

  /** 屏幕宽度 vp（像素 / 密度） */
  static screenWidthVp(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels ?? 1;
      return d.width / density;
    } catch (e) {
      return 360;
    }
  }

  /** 是否支持鼠标/触控板（电脑、平板） */
  static isMouseDevice(): boolean {
    const dt: string = DeviceUtil.deviceType();
    return dt === '2in1' || dt === 'tablet';
  }
}
