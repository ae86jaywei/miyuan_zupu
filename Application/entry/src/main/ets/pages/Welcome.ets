import { Theme } from 'common_base';

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = '[Genealogy][Welcome]';
/** 首次欢迎引导是否已展示的偏好键（与 ConsentService 共用 zupu_consent 偏好库） */
const PREF_KEY_WELCOME_SHOWN: string = 'gpWelcomeShown';
/** 启动品牌 splash 展示时长（毫秒）：消除白屏，同时让后台初始化完成 */
const SPLASH_DURATION_MS: number = 900;

/** 单页引导文案模型 */
interface SlideData {
  eyebrow: string;
  title: string;
  subtitle: string;
}

/** 四页引导内容 */
const SLIDES: SlideData[] = [
  { eyebrow: '寻根 · 修谱 · 传家', title: '觅源', subtitle: '让每一代人都被记住\n中华宗族族谱数字化' },
  { eyebrow: '编修族谱', title: '五种谱式 · 随心编排', subtitle: '欧式 / 苏式 / 牒记 / 线图 / 宝塔\n多族谱管理 · 字辈世代 · PDF 纸质谱导出' },
  { eyebrow: '寻根问祖', title: '云协作 · 地图寻墓', subtitle: '家族成员共同编修\n墓葬定位导航 · 生卒日历 · 一人一档完整留存' },
  { eyebrow: '开启旅程', title: '即刻开启觅源之旅', subtitle: '从一位始祖开始，续写家族的故事' }
];

/**
 * 首次启动欢迎引导页（应用入口）。
 *
 * 流程：品牌 splash（~0.9s）→ 已看过则直接进入主页，未看过则展示 4 页引导，
 * 「开始使用 / 跳过」后写入偏好并 replaceUrl 到主页（不在路由栈残留，按返回不回引导页）。
 * 隐私同意仍由主页 Index 触发，引导页不触碰任何个人数据。
 */
@Entry
@Component
struct Welcome {
  @StorageProp('darkMode') darkMode: boolean = false;
  /** splash | guide */
  @State phase: string = 'splash';
  /** 引导当前页索引 */
  @State current: number = 0;
  private swiper: SwiperController = new SwiperController();
  private prefs: preferences.Preferences | null = null;
  /** 防止重复跳转 */
  private navigated: boolean = false;
  /** splash 定时器句柄，页面销毁时清理 */
  private splashTimer: number = -1;

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const ctx: Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined && ctx !== null) {
      try {
        this.prefs = preferences.getPreferencesSync(ctx as common.UIAbilityContext, { name: 'zupu_consent' });
      } catch (e) {
        const be: BusinessError = e as BusinessError;
        hilog.warn(0x0000, TAG, 'getPreferences failed %{public}s', be.message);
      }
    }
    // splash 展示后再决定进入引导还是直接进主页
    this.splashTimer = setTimeout((): void => {
      const shown: boolean = this.prefs !== null && (this.prefs.getSync(PREF_KEY_WELCOME_SHOWN, false) as boolean);
      if (shown) {
        this.goIndex();
      } else {
        this.phase = 'guide';
      }
    }, SPLASH_DURATION_MS);
  }

  onPageHide(): void {
    // 页面被替换/应用退到后台时清理定时器，避免在已销毁页面触发导航
    if (this.splashTimer !== -1) {
      clearTimeout(this.splashTimer);
      this.splashTimer = -1;
    }
  }

  // ---------------------------------------------------------------- 配色
  private bgTop(): string {
    return this.darkMode ? '#1C1712' : '#FBF7EE';
  }
  private bgBottom(): string {
    return this.darkMode ? '#2A1F16' : '#F1E7D2';
  }
  private inkPrimary(): string {
    return this.darkMode ? '#EDE3D2' : '#2B2118';
  }
  private inkSecondary(): string {
    return this.darkMode ? '#B5A88E' : '#7A6A57';
  }
  private accent(): string {
    return this.darkMode ? '#C25A47' : '#8C2F1E';
  }
  private gold(): string {
    return this.darkMode ? '#D8B86A' : '#A8893F';
  }
  private dotOff(): string {
    return this.darkMode ? '#5A4A3A' : '#D8CCB6';
  }

  // ---------------------------------------------------------------- 导航
  private goIndex(): void {
    if (this.navigated) {
      return;
    }
    this.navigated = true;
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' })
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'replaceUrl failed %{public}s', err.message);
      });
  }

  private markAndGoIndex(): void {
    if (this.prefs !== null) {
      try {
        this.prefs.putSync(PREF_KEY_WELCOME_SHOWN, true);
        this.prefs.flush();
      } catch (e) {
        hilog.warn(0x0000, TAG, 'save welcome shown failed');
      }
    }
    this.goIndex();
  }

  private nextSlide(): void {
    if (this.current < SLIDES.length - 1) {
      this.swiper.showNext();
    } else {
      this.markAndGoIndex();
    }
  }

  private prevSlide(): void {
    if (this.current > 0) {
      this.swiper.showPrevious();
    }
  }

  /** 按返回键：引导内翻到上一页，首页则直接标记并进入主页 */
  onBackPress(): boolean {
    if (this.current > 0) {
      this.prevSlide();
    } else {
      this.markAndGoIndex();
    }
    return true;
  }

  // ---------------------------------------------------------------- 装饰图形
  /** 品牌光环：同心圆环 + 鎏金光斑 */
  @Builder
  brandAura() {
    Stack({ alignContent: Alignment.Center }) {
      Circle().width(260).height(260)
        .backgroundColor(this.gold())
        .opacity(this.darkMode ? 0.06 : 0.08)
        .blur(8);
      Circle().width(200).height(200)
        .border({ width: 1.2, color: this.gold() })
        .opacity(0.55);
      Circle().width(150).height(150)
        .border({ width: 1.4, color: this.accent() })
        .opacity(0.6);
      Circle().width(96).height(96)
        .backgroundColor(this.accent())
        .opacity(0.08);
      Image($r('app.media.startIcon'))
        .width(72)
        .height(72)
        .objectFit(ImageFit.Contain);
    }
    .width(280)
    .height(280)
  }

  /** 编谱：展开的书本抽象 */
  @Builder
  bookArt() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        Column() {
        }
        .width(104)
        .height(136)
        .backgroundColor(this.darkMode ? '#3A2E22' : '#FFFFFF')
        .borderRadius({ topLeft: 10, bottomLeft: 10 })
        .shadow({ radius: 14, color: '#33000000', offsetY: 6 })
        Column() {
        }
        .width(104)
        .height(136)
        .backgroundColor(this.darkMode ? '#33291D' : '#FBF7EE')
        .borderRadius({ topRight: 10, bottomRight: 10 })
        .shadow({ radius: 14, color: '#33000000', offsetY: 6 })
      }
      .offset({ y: -4 })
      // 书脊
      Divider()
        .vertical(true)
        .height(136)
        .color(this.gold())
        .strokeWidth(2)
      // 金色章节线
      Column({ space: 12 }) {
        Divider().color(this.gold()).strokeWidth(1.4).width(62).opacity(0.8);
        Divider().color(this.accent()).strokeWidth(1.4).width(46).opacity(0.6);
        Divider().color(this.gold()).strokeWidth(1.4).width(70).opacity(0.7);
      }
      .offset({ x: 32, y: 0 })
    }
    .width(280)
    .height(220)
  }

  /** 寻根：同心圆 + 定位点 */
  @Builder
  rootArt() {
    Stack({ alignContent: Alignment.Center }) {
      Circle().width(240).height(240)
        .border({ width: 1, color: this.gold() })
        .opacity(0.45);
      Circle().width(168).height(168)
        .border({ width: 1.2, color: this.accent() })
        .opacity(0.55);
      Circle().width(96).height(96)
        .backgroundColor(this.gold())
        .opacity(0.12);
      // 中心定位钉
      Circle().width(18).height(18).backgroundColor(this.accent());
      Circle().width(8).height(8).backgroundColor('#FFFFFF').opacity(0.9);
      // 放射刻度
      ForEach([0, 45, 90, 135, 180, 225, 270, 315], (deg: number) => {
        Column() {
          Divider().color(this.gold()).strokeWidth(1.4).width(16).opacity(0.7);
        }
        .offset({ y: -120 })
        .rotate({ angle: deg })
      }, (deg: number) => deg.toString());
    }
    .width(280)
    .height(280)
  }

  /** 印章：圆角朱砂方印 + 源字 */
  @Builder
  sealArt() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
      }
      .width(156)
      .height(156)
      .backgroundColor(this.accent())
      .borderRadius(18)
      .shadow({ radius: 18, color: '#558C2F1E', offsetY: 8 })
      .linearGradient({ angle: 135, colors: [[this.accent(), 0], [this.darkMode ? '#8C2F1E' : '#6E2417', 1]] })
      Text('源')
        .fontSize(88)
        .fontFamily('MiyuanHan')
        .fontColor('#F7EFE0')
        .fontWeight(FontWeight.Bold)
    }
    .width(280)
    .height(220)
  }

  @Builder
  slideArt(index: number) {
    if (index === 0) {
      this.brandAura();
    } else if (index === 1) {
      this.bookArt();
    } else if (index === 2) {
      this.rootArt();
    } else {
      this.sealArt();
    }
  }

  // ---------------------------------------------------------------- 页面
  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 背景渐变
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 160, colors: [[this.bgTop(), 0], [this.bgBottom(), 1]] })
      // 顶部与底部点缀金斑
      Circle().width(220).height(220)
        .backgroundColor(this.gold())
        .opacity(this.darkMode ? 0.05 : 0.07)
        .position({ x: -60, y: -70 })
      Circle().width(180).height(180)
        .backgroundColor(this.accent())
        .opacity(this.darkMode ? 0.04 : 0.05)
        .position({ x: '70%', y: '72%' })

      if (this.phase === 'splash') {
        this.splashView();
      } else {
        this.guideView();
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  splashView() {
    Column() {
      this.brandAura();
      Text('觅源')
        .fontSize(52)
        .fontFamily('MiyuanHan')
        .fontColor(this.inkPrimary())
        .fontWeight(FontWeight.Bold)
        .letterSpacing(12)
        .margin({ top: 24 })
      Text('中华宗族族谱数字化')
        .fontSize(14)
        .fontColor(this.inkSecondary())
        .letterSpacing(6)
        .margin({ top: 10 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .opacity(this.phase === 'splash' ? 1 : 0)
    .animation({ duration: 480, curve: Curve.EaseInOut })
  }

  @Builder
  guideView() {
    Column() {
      Swiper(this.swiper) {
        ForEach(SLIDES, (item: SlideData, index: number) => {
          Column({ space: 0 }) {
            this.slideArt(index);
            Text(item.eyebrow)
              .fontSize(14)
              .fontColor(this.gold())
              .letterSpacing(4)
              .margin({ top: 28, bottom: 14 })
            Text(item.title)
              .fontSize(index === 0 ? 56 : 34)
              .fontFamily('MiyuanHan')
              .fontColor(this.inkPrimary())
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Center)
              .maxLines(2)
            Text(item.subtitle)
              .fontSize(15)
              .fontColor(this.inkSecondary())
              .textAlign(TextAlign.Center)
              .lineHeight(26)
              .margin({ top: 16 })
              .maxLines(3)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ left: 36, right: 36 })
        }, (item: SlideData, index: number) => index.toString());
      }
      .index(this.current)
      .loop(false)
      .indicator(false)
      .displayCount(1)
      .itemSpace(0)
      .onChange((index: number): void => {
        this.current = index;
      })
      .layoutWeight(1)

      // 底部控制栏
      Row() {
        if (this.current < SLIDES.length - 1) {
          Text('跳过')
            .fontSize(15)
            .fontColor(this.inkSecondary())
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick((): void => {
              this.markAndGoIndex();
            })
        } else {
          Text('')
            .width(40);
        }

        // 圆点指示器
        Row({ space: 8 }) {
          ForEach(SLIDES, (_sd: SlideData, idx: number) => {
            Circle().width(idx === this.current ? 22 : 7).height(7)
              .backgroundColor(idx === this.current ? this.accent() : this.dotOff())
              .animation({ duration: 260, curve: Curve.EaseOut })
          }, (_sd: SlideData, idx: number) => idx.toString());
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Button(this.current < SLIDES.length - 1 ? '下一步' : '开始使用')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accent())
          .borderRadius(24)
          .width(this.current < SLIDES.length - 1 ? 104 : 132)
          .height(48)
          .shadow({ radius: 12, color: '#558C2F1E', offsetY: 4 })
          .onClick((): void => {
            this.nextSlide();
          });
      }
      .width('100%')
      .padding({ left: 28, right: 28, top: 14, bottom: 28 })
    }
    .width('100%')
    .height('100%')
  }
}
