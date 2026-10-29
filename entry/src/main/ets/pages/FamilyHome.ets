import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { PageNavBar } from '../components/PageNavBar';
import { AccountService } from '../service/AccountService';
import { FamilyService } from '../service/FamilyService';
import { FamilyBootstrapService } from '../service/FamilyBootstrapService';
import { FamilySyncService } from '../service/FamilySyncService';
import { PrivacyService } from '../service/PrivacyService';
import { GenealogyService } from '../service/GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import { FamilySummary, Role, SyncMode, SyncResult, roleLabel } from '../model/FamilyDomain';
import { Genealogy } from '../model/Genealogy';
import { RouterUtil } from '../util/RouterUtil';

/** 本版是否开启「加入别人的家族」入口 */
const ALLOW_JOIN: boolean = true;

/**
 * 我的家族（方案 §七：家族创建 / 加入 / 成员管理入口）。
 *
 * 页面职责（不涉及任何"看别人的谱"的功能）：
 *  - 把当前这部本地族谱接入云家族（创建），或凭加入码加入别人的家族；
 *  - 首次接入时把本地全量谱**发布**到云端（family-bootstrap）；
 *  - 已接入时：成员管理、访问申请、族谱黄页、待审变更、同步、加入码、隐私字段。
 */
@Entry
@Component
struct FamilyHome {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('windowWidth') windowWidth: number = 360;
  @StorageProp('gpLogin') loggedIn: boolean = false;
  @StorageProp('gpCloudReady') cloudReady: boolean = false;
  @StorageProp('gpCloudMsg') cloudMsg: string = '';
  @StorageProp('gpSyncMode') @Watch('onSyncMode') syncMode: string = SyncMode.LOCAL;
  @StorageProp('gpFamilyRole') role: string = '';
  @StorageProp('gpPendingCount') pendingCount: number = 0;
  @StorageProp('gpSyncStatus') syncStatus: string = '';

  @State busy: boolean = false;
  @State progressText: string = '';
  @State bookTitle: string = '';
  @State familyId: string = '';
  @State createTitle: string = '';
  @State inviteInput: string = '';
  @State myFamilies: FamilySummary[] = [];
  @State privateCount: number = 0;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  onSyncMode(): void {
    this.refreshHeader();
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    this.refreshHeader();
    this.loadMine();
  }

  private refreshHeader(): void {
    const book: Genealogy = GenealogyService.getInstance().getBook();
    this.bookTitle = book.title;
    this.familyId = book.familyId;
    if (this.createTitle.length === 0) {
      this.createTitle = book.title.length > 0 ? book.title : '我的族谱';
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async loadMine(): Promise<void> {
    if (!this.loggedIn || !this.cloudReady) {
      this.myFamilies = [];
      return;
    }
    try {
      this.myFamilies = await FamilyService.getInstance().listMine();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '读取我的家族失败：' + be.message;
    }
  }

  // ---------------------------------------------------------------- 创建 / 加入

  private async doCreate(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!this.loggedIn) {
      this.toast('请先登录华为账号');
      RouterUtil.login(this.getUIContext());
      return;
    }
    if (!this.cloudReady) {
      this.toast(this.cloudMsg.length > 0 ? this.cloudMsg : '云服务未就绪');
      return;
    }
    const title: string = this.createTitle.trim();
    if (title.length === 0) {
      this.toast('请填写谱名');
      return;
    }
    this.busy = true;
    this.progressText = '正在创建云家族…';
    try {
      const summary: FamilySummary = await FamilyService.getInstance().createFamily(title,
        AccountService.getInstance().getDisplayId());
      this.familyId = summary.familyId;
      this.refreshHeader();
      this.progressText = '已创建云家族，加入码：' + summary.inviteCode;
      this.toast('云家族已创建');
      this.askDirectory();
      await this.loadMine();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '创建失败：' + be.message;
      this.toast(this.progressText);
    } finally {
      this.busy = false;
    }
  }

  /**
   * 创建家族后的**一次性显式询问**（方案 §13.4：默认不可搜，必须问一次）。
   * 不问的话，门槛①③的触达率会被默认值压到接近 0。
   */
  private askDirectory(): void {
    const ui = this.getUIContext();
    const title: string = GenealogyService.getInstance().getBook().title;
    ui.showAlertDialog({
      title: '是否让族人通过搜索找到这部谱？',
      message: '开启后，其他人可以在「族谱黄页」按谱名/姓氏/地域搜到《' + title +
        '》的索引信息（谱名、姓氏、地域、人数区间），但看不到任何人物数据；' +
        '想查看仍需你审核通过。默认关闭，之后可在「族谱黄页」随时开关。',
      primaryButton: {
        value: '暂不开放',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '去开放',
        fontColor: Theme.primary,
        action: (): void => {
          RouterUtil.familyDirectory(ui);
        }
      }
    });
  }

  private async doPublish(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.progressText = '正在发布到云端…';
    try {
      const result: SyncResult = await FamilyBootstrapService.getInstance().publishCurrent(
        (message: string, done: number, total: number): void => {
          this.progressText = message + ' ' + done.toString() + '/' + total.toString();
        });
      this.progressText = result.message;
      this.toast(result.message);
      if (result.ok) {
        await FamilySyncService.getInstance().syncCurrent('after-bootstrap');
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '发布失败：' + be.message;
    } finally {
      this.busy = false;
      this.refreshHeader();
      GenealogyStore.notifyChanged();
    }
  }

  private async doJoin(): Promise<void> {
    if (this.busy) {
      return;
    }
    const code: string = this.inviteInput.trim();
    if (code.length === 0) {
      this.toast('请输入加入码');
      return;
    }
    this.busy = true;
    this.progressText = '正在加入…';
    try {
      const summary: FamilySummary = await FamilyService.getInstance().joinFamily(code,
        AccountService.getInstance().getDisplayId());
      const localBookId: number = FamilyService.getInstance().findLocalBook(summary.familyId);
      if (localBookId > 0) {
        await GenealogyService.getInstance().switchGenealogy(localBookId);
      } else {
        await FamilyService.getInstance().createLocalBookForFamily(summary);
      }
      GenealogyStore.notifyChanged();
      this.refreshHeader();
      await FamilySyncService.getInstance().syncCurrent('after-join');
      this.progressText = '已加入《' + summary.title + '》，角色：' + roleLabel(summary.role);
      this.toast(this.progressText);
      await this.loadMine();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '加入失败：' + be.message;
      this.toast(this.progressText);
    } finally {
      this.busy = false;
    }
  }

  private async doSync(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const result: SyncResult = await FamilySyncService.getInstance().syncCurrent('manual');
      this.progressText = result.message +
        (result.applied > 0 ? '（应用 ' + result.applied.toString() + ' 条变更）' : '');
      this.toast(result.message);
      this.refreshHeader();
    } finally {
      this.busy = false;
    }
  }

  private async loadPrivate(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const n: number = await PrivacyService.getInstance().loadAll(this.familyId);
      this.privateCount = n;
      this.progressText = '已读取 ' + n.toString() + ' 位族人的隐私字段（仅谱主可见）';
      this.toast(this.progressText);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '读取隐私字段失败：' + be.message;
    } finally {
      this.busy = false;
    }
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  CloudGate() {
    Column() {
      Text('☁️').fontSize(40)
      Text('本谱只存在于本机')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.ink)
        .margin({ top: Spacing.M })
      Text('接入云家族后，可邀请亲戚共同补录：谱主审核后合入，所有变更都有审计流水。')
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .textAlign(TextAlign.Center)
        .margin({ top: 6 })
        .lineHeight(18)
      if (!this.loggedIn) {
        Button('登录华为账号')
          .fontSize(14)
          .height(38)
          .backgroundColor(Theme.primary)
          .fontColor('#FFFFFF')
          .margin({ top: Spacing.L })
          .onClick((): void => {
            RouterUtil.login(this.getUIContext());
          })
      } else if (!this.cloudReady) {
        Text(this.cloudMsg.length > 0 ? this.cloudMsg : '云服务未就绪')
          .fontSize(12)
          .fontColor(Theme.danger)
          .margin({ top: Spacing.L })
      }
    }
    .width('100%')
    .padding(Spacing.XL)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
  }

  @Builder
  CreateBlock() {
    Column() {
      Text('把《' + (this.bookTitle.length > 0 ? this.bookTitle : '当前族谱') + '》接入云家族')
        .fontSize(14)
        .fontColor(Theme.ink)
        .width('100%')
      Text('接入后本谱会归属于你（谱主），由你决定谁能看、谁能改。')
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 3, bottom: Spacing.S })
        .width('100%')
      TextInput({ text: this.createTitle, placeholder: '云家族名称（一般就用谱名）' })
        .height(40)
        .fontSize(14)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .onChange((v: string): void => {
          this.createTitle = v;
        })
      Button(this.busy ? '处理中…' : '创建云家族')
        .fontSize(14)
        .height(38)
        .width('100%')
        .backgroundColor(Theme.primary)
        .fontColor('#FFFFFF')
        .margin({ top: Spacing.S })
        .enabled(!this.busy && this.loggedIn && this.cloudReady)
        .onClick((): void => {
          this.doCreate();
        })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
  }

  @Builder
  JoinBlock() {
    Column() {
      Text('用加入码加入别人的族谱')
        .fontSize(14)
        .fontColor(Theme.ink)
        .width('100%')
      Text('加入码由谱主生成（例如 A1B2C3D4），加入后你只能看到被授权的这一部谱。')
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 3, bottom: Spacing.S })
        .width('100%')
      Row() {
        TextInput({ text: this.inviteInput, placeholder: '输入加入码' })
          .height(40)
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.inviteInput = v;
          })
        Button('加入')
          .fontSize(14)
          .height(40)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.primary)
          .fontColor('#FFFFFF')
          .enabled(!this.busy && this.loggedIn && this.cloudReady)
          .onClick((): void => {
            this.doJoin();
          })
      }
      .width('100%')
      Button('在族谱黄页里找谱 →')
        .fontSize(12.5)
        .height(34)
        .width('100%')
        .margin({ top: Spacing.S })
        .backgroundColor(Theme.field)
        .fontColor(Theme.primary)
        .onClick((): void => {
          RouterUtil.familyDirectory(this.getUIContext());
        })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ top: Spacing.M })
  }

  @Builder
  CloudBlock() {
    Column() {
      Row() {
        Text('已接入云家族')
          .fontSize(14)
          .fontColor(Theme.alive)
        Blank()
        Text(roleLabel(this.role))
          .fontSize(11)
          .fontColor(Theme.primary)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor(Theme.highlightBg)
      }
      .width('100%')
      Text('家族ID：' + this.familyId)
        .fontSize(10.5)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 6 })
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
      Text('同步状态：' + (this.syncStatus.length > 0 ? this.syncStatus : '未同步') +
        (this.pendingCount > 0 && this.syncStatus.indexOf('条') < 0
          ? '（待上传 ' + this.pendingCount.toString() + ' 条）' : ''))
        .fontSize(11)
        .fontColor(this.pendingCount > 0 ? Theme.lost : Theme.inkSecondary)
        .margin({ top: 4 })
        .width('100%')

      if (this.syncMode === SyncMode.CLOUD_PENDING) {
        Text('本谱尚未发布到云端：先把当前本地全量族人上传，之后才能增量同步。')
          .fontSize(11)
          .fontColor(Theme.danger)
          .margin({ top: 8 })
          .width('100%')
        Button(this.busy ? '发布中…' : '发布当前族谱到云端')
          .fontSize(14)
          .height(38)
          .width('100%')
          .margin({ top: Spacing.S })
          .backgroundColor(Theme.primary)
          .fontColor('#FFFFFF')
          .enabled(!this.busy)
          .onClick((): void => {
            this.doPublish();
          })
      } else {
        Row() {
          Button('立即同步')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor(Theme.primary)
            .fontColor('#FFFFFF')
            .enabled(!this.busy)
            .onClick((): void => {
              this.doSync();
            })
          Button('重新全量拉取')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .margin({ left: Spacing.S })
            .backgroundColor(Theme.field)
            .fontColor(Theme.primary)
            .enabled(!this.busy)
            .onClick((): void => {
              FamilySyncService.getInstance().fullResync();
            })
        }
        .width('100%')
        .margin({ top: Spacing.M })
      }
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
  }

  @Builder
  NavRow(icon: string, title: string, subtitle: string, action: () => void) {
    Row() {
      Text(icon).fontSize(18).width(28)
      Column() {
        Text(title).fontSize(14).fontColor(Theme.ink)
        Text(subtitle)
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 2 })
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›').fontSize(18).fontColor(Theme.inkTertiary)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick((): void => {
      action();
    })
  }

  @Builder
  ManageBlock() {
    Column() {
      this.NavRow('👥', '成员与访问申请', this.role === Role.OWNER
        ? '邀请加入码 · 角色与期限 · 审批「申请查看 / 成为族人」'
        : '查看我的角色与授权期限',
        (): void => {
          RouterUtil.familyMembers(this.getUIContext());
        })
      Divider().color(Theme.line).strokeWidth(0.5)
      this.NavRow('📒', '族谱黄页',
        '默认不可搜；开启后别人可按谱名/姓氏/地域找到这部谱的索引信息',
        (): void => {
          RouterUtil.familyDirectory(this.getUIContext());
        })
      Divider().color(Theme.line).strokeWidth(0.5)
      this.NavRow('📝', '待审变更', '亲戚提交的补录，谱主审核后合入',
        (): void => {
          RouterUtil.changeReview(this.getUIContext());
        })
      Divider().color(Theme.line).strokeWidth(0.5)
      this.NavRow('📨', '我的申请', '查看我提交的查看申请 / 加入申请的状态',
        (): void => {
          RouterUtil.accessApply(this.getUIContext(), this.familyId);
        })
      Divider().color(Theme.line).strokeWidth(0.5)
      this.NavRow('🪦', '祭祖寻墓', '按人物名/谱名查祖墓坐标（对任何登录用户可见）',
        (): void => {
          RouterUtil.graveMap(this.getUIContext());
        })
      if (this.role === Role.OWNER) {
        Divider().color(Theme.line).strokeWidth(0.5)
        this.NavRow('🔒', '隐私字段（仅谱主）',
          this.privateCount > 0 ? ('已加载 ' + this.privateCount.toString() + ' 位')
            : '手机号/微信/现居地只对你可见',
          (): void => {
            this.loadPrivate();
          })
      }
    }
    .width('100%')
    .padding({ left: Spacing.L, right: Spacing.L, top: 4, bottom: 4 })
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ top: Spacing.M })
  }

  @Builder
  MineBlock() {
    Column() {
      ForEach(this.myFamilies, (f: FamilySummary) => {
        Row() {
          Column() {
            Text(f.title)
              .fontSize(14)
              .fontColor(Theme.ink)
              .maxLines(1)
            Text(roleLabel(f.role) + ' · rev ' + f.rev.toString() +
              (f.localBookId > 0 ? ' · 本机已有' : ' · 本机未导入'))
              .fontSize(10.5)
              .fontColor(Theme.inkTertiary)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          if (f.localBookId === 0 && ALLOW_JOIN) {
            Text('导入本机')
              .fontSize(11.5)
              .fontColor(Theme.primary)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(9)
              .backgroundColor(Theme.highlightBg)
              .onClick((): void => {
                this.importFamily(f);
              })
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }, (f: FamilySummary) => 'fam_' + f.familyId)
    }
    .width('100%')
    .padding({ left: Spacing.L, right: Spacing.L, top: 4, bottom: 4 })
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ top: Spacing.M })
  }

  private async importFamily(f: FamilySummary): Promise<void> {
    this.busy = true;
    try {
      await FamilyService.getInstance().createLocalBookForFamily(f);
      GenealogyStore.notifyChanged();
      this.refreshHeader();
      await FamilySyncService.getInstance().syncCurrent('import');
      await this.loadMine();
      this.toast('已导入《' + f.title + '》');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('导入失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      PageNavBar({
        title: '我的家族',
        subtitle: this.bookTitle,
        actionText: this.busy ? '' : '同步',
        busy: this.busy,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        },
        onAction: (): void => {
          if (this.familyId.length > 0) {
            this.doSync();
          }
        }
      })
      Scroll() {
        Column() {
          if (this.syncMode === SyncMode.LOCAL || this.familyId.length === 0) {
            this.CloudGate()
            Column().height(Spacing.M)
            if (this.loggedIn && this.cloudReady) {
              this.CreateBlock()
              if (ALLOW_JOIN) {
                this.JoinBlock()
              }
            }
          } else {
            this.CloudBlock()
            this.ManageBlock()
          }

          if (this.myFamilies.length > 0) {
            TS({ title: '我参与的家族', subtitle: '共 ' + this.myFamilies.length.toString() + ' 部', icon: '🏛️' })
            this.MineBlock()
          }

          if (this.progressText.length > 0) {
            Text(this.progressText)
              .fontSize(11.5)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .padding(Spacing.M)
              .margin({ top: Spacing.M })
              .backgroundColor(Theme.highlightBg)
              .borderRadius(Radius.S)
              .copyOption(CopyOptions.LocalDevice)
          }

          Column() {
            Text('可见性规则')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.ink)
            Text('查看任一部族谱的人物数据，必须满足以下之一：' +
              '① 申请认证通过（谱主审批，默认 180 天有效）；' +
              '② 持有分享链接/加入码；' +
              '③ 申请成为族人并获得通过（永久）。' +
              '族谱黄页只公开索引信息（谱名/姓氏/地域/人数区间），不含任何人物数据。')
              .fontSize(11.5)
              .fontColor(Theme.inkSecondary)
              .lineHeight(18)
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Spacing.L)
          .margin({ top: Spacing.M })
          .backgroundColor(Theme.card)
          .borderRadius(Radius.L)
          .border({ width: 0.5, color: Theme.line })

          Column().height(60)
        }
        .width('100%')
        .padding(Spacing.L)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}
