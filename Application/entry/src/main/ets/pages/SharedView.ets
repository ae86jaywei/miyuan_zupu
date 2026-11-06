import { Theme, Spacing } from '../theme/Theme';
import { BackButton } from '../components/BackButton';
import { Person } from '../model/Person';
import { CloudSyncService } from '../service/CloudSyncService';
import { AccountService } from '../service/AccountService';
import { InviteInfo, ShareService } from '../service/ShareService';
import { RouterUtil } from '../util/RouterUtil';
import { FamilyService } from '../service/FamilyService';
import { FamilySummary } from '../model/FamilyDomain';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 分享查看页（只读）。
 *
 * 入口：其他用户点击 App Linking 分享链接后，EntryAbility 解析链接中的
 * owner / familyId 写入 AppStorage，再跳转到本页。
 * 展示内容通过 Cloud DB 按 owner 的 userId 只读查询，不做本地写入。
 *
 * ⚠️ 自本版起，本页只是老的"邀请码只读查看"兼容通道（方案 §八.2）：
 * 该能力完全依赖老备份 Zone 的 Authenticated: Read，而那条权限正是
 * "任何登录用户可全表读取所有账号族谱"漏洞的来源（§十三.2）。
 * 新口径是「加入码 → 加入家族 → Membership → 云函数 sync-pull」，
 * 协作只读路径验证通过后，本页将下线。
 */
@Entry
@Component
struct SharedView {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('gpLogin') @Watch('onLoginChange') loggedIn: boolean = false;
  @StorageProp('gpCloudReady') cloudReady: boolean = false;

  @State ownerUserId: string = '';
  @State familyId: string = '';
  /** 云端族谱ID（0 表示旧版邀请码，展示全部） */
  @State bookKey: number = 0;
  @State loading: boolean = false;
  @State errorText: string = '';
  @State people: Person[] = [];
  /** 无分享链接进入时（如从文本复制邀请码），先展示邀请码录入 */
  @State needCode: boolean = false;
  @State inviteCode: string = '';

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  onLoginChange(): void {
    if (this.loggedIn && this.people.length === 0) {
      this.loadShared();
    }
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const owner: string | undefined = AppStorage.get<string>('gpSharedOwner');
    const family: string | undefined = AppStorage.get<string>('gpSharedFamilyId');
    const bookKey: number | undefined = AppStorage.get<number>('gpSharedBookKey');
    this.ownerUserId = owner !== undefined ? owner : '';
    this.familyId = family !== undefined ? family : '';
    this.bookKey = bookKey !== undefined ? bookKey : 0;
    if (this.ownerUserId.length === 0) {
      this.needCode = true;
      return;
    }
    this.loadShared();
  }

  /**
   * 用加入码加入家族（新口径）。
   * 先按加入码调 family-join 写 Membership，成功后再跳转「我的家族」拉取数据。
   */
  private async joinByCode(): Promise<void> {
    const code: string = this.inviteCode.trim();
    if (code.length === 0) {
      this.errorText = '请输入加入码';
      return;
    }
    if (!this.loggedIn) {
      this.errorText = '请先登录华为账号';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const summary: FamilySummary = await FamilyService.getInstance().joinFamily(code,
        AccountService.getInstance().getDisplayId());
      this.getUIContext().getPromptAction().showToast({
        message: '已加入《' + summary.title + '》，正在打开…'
      });
      RouterUtil.familyHome(this.getUIContext());
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.errorText = '加入失败：' + be.message;
    } finally {
      this.loading = false;
    }
  }

  /** 录入邀请码后开始只读加载（旧通道） */
  private applyInviteCode(): void {
    const info: InviteInfo = ShareService.parseInviteCode(this.inviteCode);
    if (!info.valid) {
      this.errorText = '邀请码格式不正确，请检查后重试';
      return;
    }
    this.ownerUserId = info.ownerUserId;
    this.familyId = info.familyId;
    this.bookKey = info.bookKey;
    AppStorage.setOrCreate<string>('gpSharedOwner', info.ownerUserId);
    AppStorage.setOrCreate<string>('gpSharedFamilyId', info.familyId);
    AppStorage.setOrCreate<number>('gpSharedBookKey', info.bookKey);
    this.needCode = false;
    this.errorText = '';
    this.loadShared();
  }

  private async loadShared(): Promise<void> {
    if (this.loading) {
      return;
    }
    if (this.ownerUserId.length === 0) {
      this.errorText = '分享链接缺少族谱归属信息，无法查看';
      return;
    }
    if (!this.loggedIn) {
      this.errorText = '请先登录华为账号后查看分享的族谱';
      return;
    }
    if (!this.cloudReady) {
      this.errorText = AccountService.getInstance().getCloudMessage();
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      this.people = await CloudSyncService.getInstance().loadSharedMembers(this.ownerUserId, this.bookKey);
      if (this.people.length === 0) {
        this.errorText = '该族谱暂无公开的成员数据';
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.errorText = '读取失败：' + (be.message !== undefined ? be.message : '请检查网络后重试');
    } finally {
      this.loading = false;
    }
  }

  private generationLabel(person: Person): string {
    if (person.generationChar.length > 0) {
      return '第 ' + person.generation.toString() + ' 世 · ' + person.generationChar;
    }
    return '第 ' + person.generation.toString() + ' 世';
  }

  @Builder
  PersonRow(person: Person) {
    Column() {
      Row() {
        Text(person.name.length > 0 ? person.name : '（未命名）')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.generationLabel(person))
          .fontSize(11)
          .fontColor(Theme.gold)
      }
      .width('100%')
      if (person.alias.length > 0 || person.birthDate.length > 0) {
        Text((person.alias.length > 0 ? '字/号 ' + person.alias + '　' : '') +
          (person.birthDate.length > 0 ? '生 ' + person.birthDate : ''))
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: Spacing.L, right: Spacing.L })
    .border({ width: { bottom: 0.5 }, color: Theme.line })
  }

  build() {
    Column() {
      Row() {
        BackButton({
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
        })
        Text('分享的族谱')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text(this.people.length > 0 ? this.people.length.toString() + ' 人' : '')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
      }
      .width('100%')
      .height(34)
      .padding({ left: Spacing.S, right: Spacing.L })
      .backgroundColor(Theme.card)
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      if (this.needCode) {
        Column() {
          Text('📩').fontSize(30)
          Text('输入分享邀请码')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ink)
            .margin({ top: Spacing.M })
          Text('请向谱主索取「加入码」（8 位字母数字），加入后可在「我的家族」查看')
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .textAlign(TextAlign.Center)
            .margin({ top: 6 })
          TextInput({ placeholder: '粘贴邀请码', text: this.inviteCode })
            .height(42)
            .fontSize(13)
            .backgroundColor(Theme.field)
            .borderRadius(10)
            .margin({ top: Spacing.L })
            .onChange((value: string): void => {
              this.inviteCode = value;
            })
          Button('用加入码加入')
            .height(40)
            .width('100%')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(Theme.primary)
            .margin({ top: Spacing.M })
            .onClick((): void => {
              this.joinByCode();
            })
          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(11)
              .fontColor(Theme.gold)
              .textAlign(TextAlign.Center)
              .margin({ top: Spacing.S })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: Spacing.XL, right: Spacing.XL })
      } else if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color(Theme.primary)
          Text('正在读取分享内容…').fontSize(12).fontColor(Theme.inkTertiary).margin({ top: Spacing.M })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorText.length > 0) {
        Column() {
          Text('🔒').fontSize(30)
          Text(this.errorText)
            .fontSize(13)
            .fontColor(Theme.inkSecondary)
            .textAlign(TextAlign.Center)
            .margin({ top: Spacing.M })
            .maxLines(3)
          if (!this.loggedIn) {
            Button('登录华为账号')
              .height(40)
              .fontSize(14)
              .fontColor('#FFFFFF')
              .backgroundColor(Theme.primary)
              .margin({ top: Spacing.L })
              .onClick((): void => {
                RouterUtil.login(this.getUIContext());
              })
          } else {
            Button('重新加载')
              .height(40)
              .fontSize(14)
              .fontColor(Theme.primary)
              .backgroundColor(Theme.field)
              .margin({ top: Spacing.L })
              .onClick((): void => {
                this.loadShared();
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: Spacing.XL, right: Spacing.XL })
      } else {
        List() {
          ForEach(this.people, (person: Person) => {
            ListItem() {
              this.PersonRow(person)
            }
          }, (person: Person) => 'shared_' + person.uid)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0, color: Color.Transparent })

        Text('只读查看（旧通道）· 将在协作只读路径上线后下线')
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: Spacing.S, bottom: Spacing.S })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}