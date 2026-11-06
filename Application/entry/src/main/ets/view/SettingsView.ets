import { TREE_STYLES, TreeStyleMeta } from '../model/Enums';
import { GenealogyService } from '../service/GenealogyService';
import { Genealogy } from '../model/Genealogy';
import { Theme, Spacing } from '../theme/Theme';
import { TS } from '../components/TS';
import { GenealogyStore } from '../store/GenealogyStore';
import { RouterUtil } from '../util/RouterUtil';
import { AccountCard } from './AccountCard';
import { Breakpoint } from '../common/Constants';
import { DeviceUtil } from '../util/DeviceUtil';

import { BusinessError } from '@kit.BasicServicesKit';
import { DisplayService, ORIENTATION_OPTIONS, OrientationMeta } from '../service/DisplayService';

import { FamilySyncService } from '../service/FamilySyncService';
import { SyncMode, SyncResult, roleLabel } from '../model/FamilyDomain';

/**
 * 设置：族谱信息编辑、展示偏好、隐私开关、设备适配说明、关于。
 */
@Component
export struct SettingsView {
  @Prop windowWidth: number = 360;
  @Prop version: number = 0;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  onSyncModeChange(): void {
    this.familyModeText = this.computeFamilyModeText();
  }
  @StorageProp('gpStyle') styleName: string = 'eu';
  @StorageProp('gpShowPrivate') showPrivate: boolean = true;
  @StorageProp('gpPublicMode') publicMode: boolean = false;
  @StorageProp('gpOrientation') orientationMode: string = 'follow_system';
  @StorageProp('gpHasBook') hasBook: boolean = true;
  @StorageProp('gpSyncMode') @Watch('onSyncModeChange') syncMode: string = SyncMode.LOCAL;
  @StorageProp('gpFamilyRole') familyRole: string = '';
  @StorageProp('gpSyncStatus') syncStatus: string = '';
  @StorageProp('gpPendingCount') pendingCount: number = 0;
  /** 电脑 / 折叠屏：方向由系统统一管理，四个开关不下发 */
  @State orientationBySystem: boolean = false;
  @State editingBook: boolean = false;
  @State bookTitle: string = '';
  @State bookSurname: string = '';
  @State bookHall: string = '';
  @State bookJunwang: string = '';
  @State bookAncestor: string = '';
  @State bookPoem: string = '';
  @State bookPreface: string = '';
  @State bookRules: string = '';
  @State bookNotes: string = '';
  @State familyModeText: string = '';
  @State syncing: boolean = false;

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    this.loadBook();
    // 新增族谱后由其他页面置位，这里直接进入族谱信息编辑态
    const pendingEdit: boolean | undefined = AppStorage.get<boolean>(GenealogyStore.KEY_EDITING_BOOK);
    if (pendingEdit === true) {
      AppStorage.setOrCreate<boolean>(GenealogyStore.KEY_EDITING_BOOK, false);
      this.editingBook = true;
    }
    const w: number | undefined = AppStorage.get<number>('windowWidth');
    if (w !== undefined) {
      this.windowWidth = w;
    }
    this.orientationBySystem = DisplayService.isSystemManaged();
    this.familyModeText = this.computeFamilyModeText();
  }

  /** 家族协作状态一句话说明 */
  private computeFamilyModeText(): string {
    if (this.syncMode === SyncMode.LOCAL) {
      return '本谱只存在于本机：接入云家族后可邀请亲戚共同补录（谱主审核后合入）。';
    }
    if (this.syncMode === SyncMode.CLOUD_PENDING) {
      return '已创建云家族，但还没有把本谱发布到云端。';
    }
    return '已接入云家族 · 我的角色：' + roleLabel(this.familyRole) +
      (this.pendingCount > 0 ? ' · 离线待传 ' + this.pendingCount.toString() + ' 条' : '');
  }

  private async doSyncNow(): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    try {
      const result: SyncResult = await FamilySyncService.getInstance().syncCurrent('settings');
      this.getUIContext().getPromptAction().showToast({ message: result.message });
      if (result.integrityIssues.length > 0) {
        const shown: string[] = result.integrityIssues.slice(0, 5);
        let text: string = shown.join('\n');
        if (result.integrityIssues.length > shown.length) {
          text = text + '\n……另有 ' + (result.integrityIssues.length - shown.length).toString() + ' 项';
        }
        this.getUIContext().showAlertDialog({
          title: '数据一致性提示',
          message: text + '\n\n请到「名录」核对相关人员的编号、父母与配偶关系。',
          confirm: {
            value: '知道了',
            action: (): void => {
            }
          }
        });
      }
    } finally {
      this.syncing = false;
      this.familyModeText = this.computeFamilyModeText();
    }
  }

  /** 切换屏幕方向模式（电脑 / 折叠屏不下发到窗口，仅展示「跟随系统」） */
  private onOrientationChange(mode: string): void {
    if (this.orientationBySystem) {
      return;
    }
    DisplayService.getInstance().setMode(mode);
  }

  private loadBook(): void {
    const b: Genealogy = GenealogyService.getInstance().getBook();
    this.bookTitle = b.title;
    this.bookSurname = b.surname;
    this.bookHall = b.hallName;
    this.bookJunwang = b.junwang;
    this.bookAncestor = b.ancestorName;
    this.bookPoem = b.generationPoem;
    this.bookPreface = b.preface;
    this.bookRules = b.familyRules;
    this.bookNotes = b.editingNotes;
  }

  private async saveBook(): Promise<void> {
    const b: Genealogy = GenealogyService.getInstance().getBook();
    b.title = this.bookTitle;
    b.surname = this.bookSurname;
    b.hallName = this.bookHall;
    b.junwang = this.bookJunwang;
    b.ancestorName = this.bookAncestor;
    b.generationPoem = this.bookPoem;
    b.preface = this.bookPreface;
    b.familyRules = this.bookRules;
    b.editingNotes = this.bookNotes;
    await GenealogyService.getInstance().saveBook(b);
    GenealogyStore.notifyChanged();
    this.editingBook = false;
  }

  /** 删除族谱确认弹窗 */
  private deleteDialog: CustomDialogController | null = null;

  /** 打开删除确认弹窗（需输入谱名二次确认） */
  private openDeleteDialog(): void {
    const title: string = GenealogyService.getInstance().getBook().title;
    if (title.length === 0) {
      return;
    }
    this.deleteDialog = new CustomDialogController({
      builder: DeleteGenealogyDialog({
        bookTitle: title,
        onConfirm: (input: string): void => {
          this.confirmDelete(input);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.deleteDialog.open();
  }

  /** 执行删除族谱 */
  private async confirmDelete(input: string): Promise<void> {
    const title: string = GenealogyService.getInstance().getBook().title;
    if (input.trim() !== title) {
      this.getUIContext().getPromptAction().showToast({ message: '族谱名称输入不一致，已取消删除' });
      return;
    }
    try {
      await GenealogyService.getInstance().deleteGenealogy();
      GenealogyStore.notifyChanged();
      AppStorage.setOrCreate<string>('gpSelection', '');
      AppStorage.setOrCreate<number>('gpTab', 1);
      this.getUIContext().getPromptAction().showToast({ message: '族谱已删除' });
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: '删除失败：' + err.message });
    }
  }

  /** 无族谱状态下创建一部空族谱 */
  private async createBook(): Promise<void> {
    try {
      await GenealogyService.getInstance().createGenealogy('');
      GenealogyStore.notifyChanged();
      this.loadBook();
      // 创建后立即进入编辑态，填写谱名、堂号等信息
      this.editingBook = true;
      this.getUIContext().getPromptAction().showToast({ message: '已创建族谱，请填写族谱信息' });
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: '创建失败：' + err.message });
    }
  }

  @Builder
  FieldRow(label: string, value: string, onChange: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .width('100%')
      TextInput({ text: value })
        .height(38)
        .fontSize(14)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: 4 })
        .onChange((v: string): void => {
          onChange(v);
        })
    }
    .width('100%')
    .margin({ bottom: Spacing.S })
  }

  @Builder
  SwitchRow(label: string, tip: string, value: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(label)
          .fontSize(14)
          .fontColor(Theme.ink)
        if (tip.length > 0) {
          Text(tip)
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 2 })
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(Theme.primary)
        .onChange((isOn: boolean): void => {
          onChange(isOn);
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  BookForm() {
    Column() {
      this.FieldRow('谱名', this.bookTitle, (v: string): void => {
        this.bookTitle = v;
      })
      this.FieldRow('姓氏', this.bookSurname, (v: string): void => {
        this.bookSurname = v;
      })
      this.FieldRow('堂号', this.bookHall, (v: string): void => {
        this.bookHall = v;
      })
      this.FieldRow('郡望', this.bookJunwang, (v: string): void => {
        this.bookJunwang = v;
      })
      this.FieldRow('始迁祖', this.bookAncestor, (v: string): void => {
        this.bookAncestor = v;
      })
      this.FieldRow('字派谱（字辈诗）', this.bookPoem, (v: string): void => {
        this.bookPoem = v;
      })
      Text('谱序')
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .width('100%')
      TextArea({ text: this.bookPreface })
        .height(100)
        .fontSize(13)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: 4, bottom: Spacing.S })
        .onChange((v: string): void => {
          this.bookPreface = v;
        })
      Text('家训')
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .width('100%')
      TextArea({ text: this.bookRules })
        .height(100)
        .fontSize(13)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: 4, bottom: Spacing.S })
        .onChange((v: string): void => {
          this.bookRules = v;
        })
      Text('凡例 / 修谱说明')
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .width('100%')
      TextArea({ text: this.bookNotes })
        .height(80)
        .fontSize(13)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: 4 })

      Row() {
        Button('取消')
          .fontColor(Theme.inkSecondary)
          .backgroundColor(Theme.field)
          .layoutWeight(1)
          .height(38)
          .onClick((): void => {
            this.loadBook();
            this.editingBook = false;
          })
        Button('保存')
          .backgroundColor(Theme.primary)
          .layoutWeight(1)
          .height(38)
          .margin({ left: Spacing.S })
          .onClick((): void => {
            this.saveBook();
          })
      }
      .width('100%')
      .margin({ top: Spacing.M })
    }
    .width('100%')
  }

  @Builder
  BookOverview() {
    Column() {
      if (!this.hasBook) {
        Column() {
          Text('尚未创建族谱')
            .fontSize(15)
            .fontColor(Theme.ink)
          Text('可在此创建新族谱，或到「谱系」页通过 + 号新增族谱')
            .fontSize(11.5)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 4 })
            .maxLines(2)
          Button('创建族谱')
            .fontSize(13)
            .height(34)
            .backgroundColor(Theme.primary)
            .fontColor('#FFFFFF')
            .margin({ top: Spacing.M })
            .onClick((): void => {
              this.createBook();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      } else {
        Row() {
          Column() {
            Text(GenealogyService.getInstance().getBook().title)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.ink)
            Text((GenealogyService.getInstance().getBook().hallName.length > 0 ?
              GenealogyService.getInstance().getBook().hallName + ' · ' : '') +
              '始迁祖 ' + GenealogyService.getInstance().getBook().ancestorName)
              .fontSize(12)
              .fontColor(Theme.inkTertiary)
              .margin({ top: 3 })
            Text('字派：' + GenealogyService.getInstance().getBook().generationPoem)
              .fontSize(12)
              .fontColor(Theme.gold)
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button('编辑')
            .fontSize(13)
            .height(32)
            .backgroundColor(Theme.field)
            .fontColor(Theme.primary)
            .onClick((): void => {
              this.editingBook = true;
            })
          Button('删除')
            .fontSize(13)
            .height(32)
            .backgroundColor(Theme.field)
            .fontColor(Theme.danger)
            .margin({ left: Spacing.S })
            .onClick((): void => {
              this.openDeleteDialog();
            })
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  StyleRow(meta: TreeStyleMeta) {
    Row() {
      Text(meta.name)
        .fontSize(14)
        .fontColor(Theme.ink)
        .width(80)
      Text(meta.feature)
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .layoutWeight(1)
      Radio({ value: meta.key, group: 'styleGroup' })
        .checked(this.styleName === meta.key)
        .onChange((isChecked: boolean): void => {
          if (isChecked) {
            GenealogyStore.setStyle(meta.key);
          }
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  OrientationRow(meta: OrientationMeta, enabled: boolean, showDivider: boolean) {
    Column() {
      Row() {
        Column() {
          Text(meta.name)
            .fontSize(14)
            .fontColor(enabled ? Theme.ink : Theme.inkTertiary)
          Text(meta.desc)
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 2 })
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Radio({ value: meta.key, group: 'orientationGroup' })
          .checked(this.orientationMode === meta.key)
          .enabled(enabled)
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })
      .opacity(enabled ? 1 : 0.55)
      .onClick((): void => {
        if (enabled && this.orientationMode !== meta.key) {
          this.onOrientationChange(meta.key);
        }
      })

      if (showDivider) {
        Divider().color(Theme.line).strokeWidth(0.5)
      }
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column() {
        AccountCard()

        TS({ title: '家族协作', subtitle: this.familyModeText, icon: '👨‍👩‍👧' })
        Column() {
          this.NavRow('我的家族', '创建云家族 / 加入码加入 / 发布本谱 / 同步', (): void => {
            RouterUtil.familyHome(this.getUIContext());
          })
          Divider().color(Theme.line).strokeWidth(0.5)
          this.NavRow('成员与访问申请', '角色 · 期限 · 审批「申请查看 / 成为族人」', (): void => {
            RouterUtil.familyMembers(this.getUIContext());
          })
          Divider().color(Theme.line).strokeWidth(0.5)
          this.NavRow('族谱黄页', '默认不可搜；上架后他人可按谱名/姓氏/地域找到', (): void => {
            RouterUtil.familyDirectory(this.getUIContext());
          })
          Divider().color(Theme.line).strokeWidth(0.5)
          this.NavRow('待审变更', '亲戚补录的提交，谱主审核后合入', (): void => {
            RouterUtil.changeReview(this.getUIContext());
          })
          Divider().color(Theme.line).strokeWidth(0.5)
          this.NavRow('祭祖寻墓', '祖墓坐标对任意登录用户可见（离线可查）', (): void => {
            RouterUtil.graveMap(this.getUIContext());
          })
          if (this.syncMode !== SyncMode.LOCAL) {
            Button(this.syncing ? '同步中…' : '立即同步')
              .height(36)
              .width('100%')
              .fontSize(13)
              .backgroundColor(Theme.field)
              .fontColor(Theme.primary)
              .margin({ top: Spacing.S })
              .enabled(!this.syncing)
              .onClick((): void => {
                this.doSyncNow();
              })
            if (this.syncStatus.length > 0) {
              Text(this.syncStatus)
                .fontSize(10.5)
                .fontColor(Theme.inkTertiary)
                .margin({ top: 6 })
                .width('100%')
            }
          }
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        TS({ title: '族谱信息', subtitle: '谱名 · 堂号 · 郡望 · 字派 · 谱序 · 家训', icon: '📕' })
        Column() {
          if (this.editingBook) {
            this.BookForm()
          } else {
            this.BookOverview()
          }
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        TS({ title: '默认谱式', subtitle: '用于谱系页初始化', icon: '🎨' })
        Column() {
          ForEach(TREE_STYLES, (meta: TreeStyleMeta) => {
            this.StyleRow(meta)
          }, (meta: TreeStyleMeta) => 'st_' + meta.key)
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        TS({
          title: '显示设置',
          subtitle: '当前：' + DisplayService.labelOf(this.orientationMode),
          icon: '🖥️'
        })
        Column() {
          Text('屏幕方向')
            .fontSize(12)
            .fontColor(Theme.inkTertiary)
            .width('100%')
            .margin({ bottom: 6 })
          if (this.orientationBySystem) {
            Text(DisplayService.isPc() ?
              '当前设备为电脑，窗口方向由系统统一调度，应用侧配置不生效，故以下选项不可设置。' :
              '当前设备为折叠屏，方向跟随桌面并在折叠态切换时由系统自动更新，故以下选项不可设置。')
              .fontSize(11)
              .fontColor(Theme.inkTertiary)
              .width('100%')
              .margin({ bottom: 6 })
              .maxLines(3)
          }
          ForEach(ORIENTATION_OPTIONS, (meta: OrientationMeta, index: number) => {
            this.OrientationRow(meta, !this.orientationBySystem, index < ORIENTATION_OPTIONS.length - 1)
          }, (meta: OrientationMeta) => 'or_' + meta.key)
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        TS({ title: '隐私与展示', icon: '🔒' })
        Column() {
          this.SwitchRow('显示隐私字段', '手机号、微信号默认加星号显示，关闭后完全隐藏', this.showPrivate, (v: boolean): void => {
            this.showPrivate = v;
          })
          Divider().color(Theme.line).strokeWidth(0.5)
          this.SwitchRow('公开模式', '公开模式下所有隐私字段不显示，适用于分享/展示', this.publicMode, (v: boolean): void => {
            this.publicMode = v;
          })
          Text('协作说明：接入云家族后，手机号/微信/现居地只保存在云端「仅谱主可读」的隐私表中，' +
            '编辑者与只读成员都拿不到明文；被记录的活人可请谱主删除或更正（操作会留审计流水）。')
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .lineHeight(16)
            .width('100%')
            .margin({ top: Spacing.S })
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        TS({ title: '数据管理', icon: '💾' })
        Column() {
          this.NavRow('导入 / 导出', 'JSON 备份、CSV 表格、Markdown 谱文', (): void => {
            RouterUtil.importExport(this.getUIContext());
          })
          Divider().color(Theme.line).strokeWidth(0.5)
          this.NavRow('按 Excel 字段导出', '严格对齐《关键信息字段_20261023》', (): void => {
            RouterUtil.importExport(this.getUIContext());
          })
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        TS({
          title: '设备适配',
          subtitle: '当前窗口：' + Math.round(this.windowWidth).toString() + ' vp',
          icon: '📱'
        })
        Column() {
          this.InfoLine('设备类型', DeviceUtil.deviceType())
          this.InfoLine('设备形态', DeviceUtil.formLabel(DeviceUtil.formOf(this.windowWidth, this.windowWidth * 1.6)))
          this.InfoLine('断点', this.windowWidth >= Breakpoint.XL ? 'XL（宽屏/电脑）' :
            this.windowWidth >= Breakpoint.LG ? 'LG（电脑/三折叠）' :
              this.windowWidth >= Breakpoint.MD ? 'MD（平板/折叠展开）' :
                this.windowWidth >= Breakpoint.SM ? 'SM（阔屏）' : 'XS（手机）')
          this.InfoLine('适配说明', 'XS 底部导航 · SM 侧栏 · MD/LG/XL 三栏主从布局，支持折叠态/展开态无缝切换')
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        TS({ title: '关于', icon: 'ℹ️' })
        Column() {
          this.InfoLine('应用名称', '觅源 v1.0.0（com.zupu.ae86jay）')
          this.InfoLine('支持谱式', '欧式 · 苏式 · 宝塔式 · 牒记式 · 现代创新式')
          this.InfoLine('适配设备', '手机 · 平板 · 电脑(2in1) · 双折叠 · 三折叠 · 阔屏 · 阔折叠')
        }
        .width('100%')
        .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
        .backgroundColor(Theme.card)
        .borderRadius(16)
        .border({ width: 0.5, color: Theme.line })
        .margin({ bottom: Spacing.M })
        .clip(true)

        Column().height(100)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }


  @Builder
  NavRow(title: string, subtitle: string, action: () => void) {
        Row() {
          Column() {
            Text(title).fontSize(14).fontColor(Theme.ink)
            Text(subtitle).fontSize(11).fontColor(Theme.inkTertiary).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('›').fontSize(18).fontColor(Theme.inkTertiary)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .onClick((): void => {
          action();
        })
      }

  @Builder
  InfoLine(label: string, value: string) {
        Row() {
          Text(label).fontSize(12).fontColor(Theme.inkTertiary).width(72)
          Text(value).fontSize(12.5).fontColor(Theme.inkSecondary).layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ top: 4, bottom: 4 })
      }
}

/**
 * 删除族谱二次确认弹窗：必须输入完整谱名才能确认删除。
 */
@CustomDialog
struct DeleteGenealogyDialog {
  controller?: CustomDialogController;
  /** 待删除的族谱名称 */
  bookTitle: string = '';
  onConfirm: (input: string) => void = (input: string): void => {};
  @State input: string = '';

  private matched(): boolean {
    return this.input.trim() === this.bookTitle;
  }

  build() {
    Column() {
      Text('删除族谱')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.danger)
        .width('100%')
      Text('此操作将永久删除《' + this.bookTitle + '》的全部族人、配偶关系及族谱信息，删除后无法恢复。')
        .fontSize(12.5)
        .fontColor(Theme.inkSecondary)
        .lineHeight(19)
        .margin({ top: 10 })
        .width('100%')
      Text('请输入族谱名称「' + this.bookTitle + '」以确认')
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 14 })
        .width('100%')
      TextInput({ text: this.input, placeholder: '请输入谱名' })
        .height(40)
        .fontSize(14)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: 6 })
        .onChange((v: string): void => {
          this.input = v;
        })
      Row() {
        Button('取消')
          .fontColor(Theme.inkSecondary)
          .backgroundColor(Theme.field)
          .layoutWeight(1)
          .height(38)
          .onClick((): void => {
            this.controller?.close();
          })
        Button('确认删除')
          .backgroundColor(Theme.danger)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .height(38)
          .margin({ left: Spacing.S })
          .enabled(this.matched())
          .opacity(this.matched() ? 1 : 0.45)
          .onClick((): void => {
            if (!this.matched()) {
              return;
            }
            this.controller?.close();
            this.onConfirm(this.input.trim());
          })
      }
      .width('100%')
      .margin({ top: Spacing.L })
    }
    .width('100%')
    .padding(Spacing.XL)
    .backgroundColor(Theme.card)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }
}
