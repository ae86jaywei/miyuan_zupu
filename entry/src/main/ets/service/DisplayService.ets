import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = '[Genealogy][Display]';

/**
 * 屏幕方向模式（设置页「显示设置 · 屏幕方向」的四个开关）。
 *
 * 与鸿蒙 window.Orientation 枚举的对应关系（见官方《窗口方向》最佳实践）：
 *  - FOLLOW_SYSTEM   → AUTO_ROTATION_UNSPECIFIED(12)：受控制中心旋转开关控制，可旋转方向由系统按设备形态判定；
 *  - LOCK_LANDSCAPE  → LANDSCAPE(2)：锁定横屏；
 *  - LOCK_PORTRAIT   → PORTRAIT(1)：锁定竖屏；
 *  - AUTO_ROTATE     → AUTO_ROTATION(5)：四向跟随传感器旋转，不受控制中心旋转开关控制。
 *
 * 注意：AUTO_ROTATION(5) 官方标注「不受控制中心的旋转开关控制」，
 * 这正是原 module.json5 配置 auto_rotation 时系统锁定旋转仍会旋转的原因。
 */
export enum OrientationMode {
  FOLLOW_SYSTEM = 'follow_system',
  LOCK_LANDSCAPE = 'lock_landscape',
  LOCK_PORTRAIT = 'lock_portrait',
  AUTO_ROTATE = 'auto_rotate'
}

export interface OrientationMeta {
  key: OrientationMode;
  name: string;
  desc: string;
}

export const ORIENTATION_OPTIONS: OrientationMeta[] = [
  {
    key: OrientationMode.FOLLOW_SYSTEM,
    name: '跟随系统',
    desc: '受控制中心「旋转锁定」开关控制，可旋转方向由系统判定'
  },
  {
    key: OrientationMode.LOCK_LANDSCAPE,
    name: '锁定横屏',
    desc: '始终保持横屏显示，不随设备姿态改变'
  },
  {
    key: OrientationMode.LOCK_PORTRAIT,
    name: '锁定竖屏',
    desc: '始终保持竖屏显示，不随设备姿态改变'
  },
  {
    key: OrientationMode.AUTO_ROTATE,
    name: '自动旋转',
    desc: '四向跟随设备姿态旋转，不受控制中心旋转开关控制'
  }
];

/**
 * 显示设置服务（单例）：屏幕方向偏好的持久化与生效。
 *
 * 按鸿蒙官方要求处理设备差异：
 *  - 电脑（2in1）：官方明确「应用无法配置窗口旋转策略」，系统策略优先级高于应用，故不下发；
 *  - 折叠屏：官方推荐 FOLLOW_DESKTOP，桌面可旋转则可旋转，且折叠态切换时策略自动更新
 *    （如三折叠单屏态仅竖屏，切到双屏/三屏态自动变为受开关控制的自由旋转）；
 *  - 手机 / 平板：四个开关全部生效。
 */
export class DisplayService {
  private static instance: DisplayService | null = null;

  static readonly KEY_ORIENTATION: string = 'gpOrientation';
  private static readonly PREF_NAME: string = 'zupu_display';
  private static readonly PREF_FIELD: string = 'orientation';

  private context: common.Context | null = null;
  private prefs: preferences.Preferences | null = null;
  /** 主窗口引用：由 EntryAbility 注入，避免 getLastWindow 的查找延迟 */
  private mainWindow: window.Window | null = null;

  static getInstance(): DisplayService {
    if (DisplayService.instance === null) {
      DisplayService.instance = new DisplayService();
    }
    return DisplayService.instance;
  }

  /** 当前生效的方向模式 */
  static mode(): string {
    const v: string | undefined = AppStorage.get<string>(DisplayService.KEY_ORIENTATION);
    return v !== undefined && DisplayService.isValid(v) ? v : OrientationMode.FOLLOW_SYSTEM;
  }

  /** 是否为电脑（2in1） */
  static isPc(): boolean {
    return deviceInfo.deviceType === '2in1';
  }

  /** 是否为折叠屏（双折叠 / 三折叠 / 阔折叠） */
  static isFoldable(): boolean {
    try {
      return display.isFoldable();
    } catch (e) {
      return false;
    }
  }

  /**
   * 方向是否由系统统一管理（电脑 / 折叠屏）。
   * 为 true 时四个开关不下发用户偏好，界面固定展示「跟随系统」。
   */
  static isSystemManaged(): boolean {
    return DisplayService.isPc() || DisplayService.isFoldable();
  }

  /** 方向模式的中文名称（用于提示与日志） */
  static labelOf(mode: string): string {
    for (let i: number = 0; i < ORIENTATION_OPTIONS.length; i++) {
      if (ORIENTATION_OPTIONS[i].key === mode) {
        return ORIENTATION_OPTIONS[i].name;
      }
    }
    return '跟随系统';
  }

  private static isValid(mode: string): boolean {
    return mode === OrientationMode.FOLLOW_SYSTEM || mode === OrientationMode.LOCK_LANDSCAPE ||
      mode === OrientationMode.LOCK_PORTRAIT || mode === OrientationMode.AUTO_ROTATE;
  }

  /**
   * 解析最终要下发给窗口的旋转策略。
   * 返回 undefined 表示该设备不需要（也不应该）由应用下发方向。
   */
  private static resolveOrientation(mode: string): window.Orientation | undefined {
    if (DisplayService.isPc()) {
      // 电脑：窗口方向由系统窗口管理器决定，应用配置不生效
      return undefined;
    }
    if (DisplayService.isFoldable()) {
      // 折叠屏：跟随桌面，折叠态切换时由系统自动更新策略
      return window.Orientation.FOLLOW_DESKTOP;
    }
    if (mode === OrientationMode.LOCK_LANDSCAPE) {
      return window.Orientation.LANDSCAPE;
    }
    if (mode === OrientationMode.LOCK_PORTRAIT) {
      return window.Orientation.PORTRAIT;
    }
    if (mode === OrientationMode.AUTO_ROTATE) {
      return window.Orientation.AUTO_ROTATION;
    }
    return window.Orientation.AUTO_ROTATION_UNSPECIFIED;
  }

  /**
   * 初始化（幂等）：读取持久化偏好写入 AppStorage。
   * 电脑 / 折叠屏固定展示「跟随系统」，且不覆盖用户在其他设备上保存的偏好。
   */
  init(context: common.Context): void {
    if (this.prefs !== null) {
      return;
    }
    this.context = context;
    try {
      const opt: preferences.Options = { name: DisplayService.PREF_NAME };
      this.prefs = preferences.getPreferencesSync(context, opt);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'prefs init failed: %{public}s', JSON.stringify(err));
    }
    if (DisplayService.isSystemManaged()) {
      AppStorage.setOrCreate<string>(DisplayService.KEY_ORIENTATION, OrientationMode.FOLLOW_SYSTEM);
      hilog.info(0x0000, TAG, 'orientation managed by system on this device');
      return;
    }
    AppStorage.setOrCreate<string>(DisplayService.KEY_ORIENTATION, this.readSaved());
  }

  /** 注入主窗口（onWindowStageCreate 中调用），后续切换方向直接复用 */
  setMainWindow(win: window.Window): void {
    this.mainWindow = win;
  }

  private readSaved(): string {
    if (this.prefs === null) {
      return OrientationMode.FOLLOW_SYSTEM;
    }
    try {
      const v: string = this.prefs.getSync(DisplayService.PREF_FIELD, OrientationMode.FOLLOW_SYSTEM) as string;
      return DisplayService.isValid(v) ? v : OrientationMode.FOLLOW_SYSTEM;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'read orientation failed: %{public}s', JSON.stringify(err));
      return OrientationMode.FOLLOW_SYSTEM;
    }
  }

  /**
   * 切换方向模式：立即生效并持久化。
   * 电脑 / 折叠屏按官方策略处理，用户偏好仅在手机 / 平板生效。
   */
  async setMode(mode: string): Promise<void> {
    if (!DisplayService.isValid(mode)) {
      return;
    }
    AppStorage.setOrCreate<string>(DisplayService.KEY_ORIENTATION, mode);
    if (this.prefs !== null) {
      try {
        await this.prefs.put(DisplayService.PREF_FIELD, mode);
        await this.prefs.flush();
      } catch (err) {
        hilog.warn(0x0000, TAG, 'persist orientation failed: %{public}s', JSON.stringify(err));
      }
    }
    await this.apply(mode);
  }

  /** 把方向策略下发到主窗口；不传参时使用当前生效值 */
  async apply(mode?: string): Promise<void> {
    const target: string = mode !== undefined ? mode : DisplayService.mode();
    const orientation: window.Orientation | undefined = DisplayService.resolveOrientation(target);
    if (orientation === undefined) {
      hilog.info(0x0000, TAG, 'skip setPreferredOrientation: pc device');
      return;
    }
    if (this.mainWindow !== null) {
      await this.applyToWindow(this.mainWindow, target);
      return;
    }
    if (this.context === null) {
      hilog.warn(0x0000, TAG, 'apply skipped: window and context not ready');
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(this.context);
      this.mainWindow = win;
      await this.applyToWindow(win, target);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'getLastWindow failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 对指定窗口下发方向策略。
   * 电脑设备由系统管理，内部自动跳过。
   */
  async applyToWindow(win: window.Window, mode?: string): Promise<void> {
    const target: string = mode !== undefined ? mode : DisplayService.mode();
    const orientation: window.Orientation | undefined = DisplayService.resolveOrientation(target);
    if (orientation === undefined) {
      hilog.info(0x0000, TAG, 'skip setPreferredOrientation: pc device');
      return;
    }
    this.mainWindow = win;
    try {
      await win.setPreferredOrientation(orientation);
      hilog.info(0x0000, TAG, 'orientation applied: mode=%{public}s', target);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'setPreferredOrientation failed: %{public}s', JSON.stringify(err));
    }
  }
}
