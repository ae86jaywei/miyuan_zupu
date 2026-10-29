import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { PageNavBar } from '../components/PageNavBar';
import { AccountService } from '../service/AccountService';
import { FamilyService } from '../service/FamilyService';
import {
  AccessKind, AccessRequestInfo, AccessStatus,
  accessKindLabel, accessStatusLabel
} from '../model/FamilyDomain';
import { AccessParams } from '../model/Scope';
import { RouterUtil } from '../util/RouterUtil';

/**
 * 申请认证（方案 §十三 门槛①③、§七 AccessApply）。
 *
 * 两种申请走同一条链路（AccessRequest → access-review → 写 Membership）：
 *  - VIEW_APPLY：申请查看，默认 180 天有效（审批页可改）；
 *  - JOIN_CLAIM：申请成为族人并认领支系，默认永久。
 * 本页同时展示「我的申请」状态。
 */
@Entry
@Component
struct AccessApply {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  @State familyId: string = '';
  @State kind: string = AccessKind.VIEW_APPLY;
  @State relationText: string = '';
  @State evidenceText: string = '';
  @State branchUid: string = '';
  @State applicantName: string = '';
  @State myApplications: AccessRequestInfo[] = [];
  @State busy: boolean = false;
  @State message: string = '';

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const params: AccessParams | undefined =
      this.getUIContext().getRouter().getParams() as AccessParams | undefined;
    if (params !== undefined && params !== null) {
      this.familyId = params.familyId !== undefined ? params.familyId : '';
      this.kind = params.kind !== undefined && params.kind.length > 0 ? params.kind : AccessKind.VIEW_APPLY;
    }
    this.applicantName = AccountService.getInstance().getDisplayId();
    this.loadMyApplications();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async loadMyApplications(): Promise<void> {
    if (!AccountService.getInstance().isCloudReady()) {
      return;
    }
    try {
      this.myApplications = await FamilyService.getInstance().listMyAccess();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.message = '读取我的申请失败：' + be.message;
    }
  }

  private async submit(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.familyId.length === 0) {
      this.toast('请先从族谱黄页选择一部族谱');
      return;
    }
    if (!AccountService.getInstance().isLoggedIn()) {
      this.toast('请先登录华为账号');
      return;
    }
    if (this.kind === AccessKind.JOIN_CLAIM && this.branchUid.trim().length === 0) {
      this.toast('请填写你要认领的支系根人物（唯一ID）');
      return;
    }
    this.busy = true;
    this.message = '';
    try {
      const result: string = await FamilyService.getInstance().requestAccess(this.familyId, this.kind,
        this.relationText, this.branchUid.trim().toUpperCase(), this.evidenceText, this.applicantName);
      if (result === 'ALREADY_MEMBER') {
        this.message = '你已是该谱成员，无需重复申请。';
      } else if (result === 'DUPLICATED') {
        this.message = '你已有一条待审核的申请，请等待谱主处理。';
      } else {
        this.message = this.kind === AccessKind.JOIN_CLAIM
          ? '申请已提交。谱主通过后你会成为族人（永久），并可修改认领支系内的族人。'
          : '申请已提交。谱主通过后可以在 180 天内查看。';
      }
      this.toast('提交成功');
      await this.loadMyApplications();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.message = '提交失败：' + be.message;
      this.toast(this.message);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  KindTab(k: string, label: string, desc: string) {
    Column() {
      Row() {
        Radio({ value: k, group: 'applyKind' })
          .checked(this.kind === k)
          .onChange((isChecked: boolean): void => {
            if (isChecked) {
              this.kind = k;
            }
          })
        Text(label)
          .fontSize(14)
          .fontColor(this.kind === k ? Theme.ink : Theme.inkSecondary)
      }
      .width('100%')
      Text(desc)
        .fontSize(10.5)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 2, left: 28 })
        .width('100%')
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  ApplicationRow(a: AccessRequestInfo) {
    Column() {
      Row() {
        Text(accessKindLabel(a.kind))
          .fontSize(13)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text(accessStatusLabel(a.status))
          .fontSize(11)
          .fontColor(a.status === AccessStatus.APPROVED ? Theme.alive :
            (a.status === AccessStatus.REJECTED ? Theme.danger : Theme.gold))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(Theme.field)
      }
      .width('100%')
      Text((a.familyTitle.length > 0 ? a.familyTitle : a.familyId))
        .fontSize(10)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 3 })
        .width('100%')
      if (a.reviewNote.length > 0) {
        Text('审批备注：' + a.reviewNote)
          .fontSize(10.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 2 })
          .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Column() {
      PageNavBar({
        title: '申请认证',
        subtitle: '申请查看 / 申请成为族人',
        busy: this.busy,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        }
      })
      Scroll() {
        Column() {
          TS({ title: '提交申请', subtitle: '申请单只会交给该谱谱主审核', icon: '✉️' })
          Column() {
            Text('族谱ID：' + (this.familyId.length > 0 ? this.familyId : '（请从族谱黄页选择）'))
              .fontSize(11)
              .fontColor(Theme.inkTertiary)
              .width('100%')
            Row() {
              TextInput({ text: this.familyId, placeholder: '从黄页进入会自动带入' })
                .height(34)
                .fontSize(12)
                .layoutWeight(1)
                .backgroundColor(Theme.field)
                .borderRadius(8)
                .onChange((v: string): void => {
                  this.familyId = v.trim();
                })
              Button('黄页')
                .fontSize(12)
                .height(34)
                .margin({ left: Spacing.S })
                .backgroundColor(Theme.highlightBg)
                .fontColor(Theme.primary)
                .onClick((): void => {
                  RouterUtil.familyDirectory(this.getUIContext());
                })
            }
            .width('100%')
            .margin({ top: 4 })

            this.KindTab(AccessKind.VIEW_APPLY, '申请查看', '只想先看一眼：默认 180 天后自动失效（谱主审批时可改）')
            this.KindTab(AccessKind.JOIN_CLAIM, '申请成为族人并认领支系', '真正的族人身份：永久有效，可修改认领支系内的族人')

            TextInput({ text: this.relationText, placeholder: '关系说明，如：我是三房李泽民之子' })
              .height(36)
              .fontSize(13)
              .backgroundColor(Theme.field)
              .borderRadius(8)
              .margin({ top: Spacing.S })
              .onChange((v: string): void => {
                this.relationText = v;
              })
            if (this.kind === AccessKind.JOIN_CLAIM) {
              TextInput({ text: this.branchUid, placeholder: '认领支系根人物唯一ID，如 F012' })
                .height(34)
                .fontSize(13)
                .backgroundColor(Theme.field)
                .borderRadius(8)
                .margin({ top: Spacing.S })
                .onChange((v: string): void => {
                  this.branchUid = v;
                })
            }
            TextInput({ text: this.evidenceText, placeholder: '依据：老谱照片 / 介绍人 / 口述人' })
              .height(36)
              .fontSize(13)
              .backgroundColor(Theme.field)
              .borderRadius(8)
              .margin({ top: Spacing.S })
              .onChange((v: string): void => {
                this.evidenceText = v;
              })
            Button(this.busy ? '提交中…' : '提交申请')
              .fontSize(14)
              .height(40)
              .width('100%')
              .margin({ top: Spacing.M })
              .backgroundColor(Theme.primary)
              .fontColor('#FFFFFF')
              .enabled(!this.busy)
              .onClick((): void => {
                this.submit();
              })
            if (this.message.length > 0) {
              Text(this.message)
                .fontSize(11.5)
                .fontColor(Theme.inkSecondary)
                .margin({ top: Spacing.S })
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Spacing.L)
          .backgroundColor(Theme.card)
          .borderRadius(Radius.L)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })

          TS({ title: '我的申请', subtitle: '共 ' + this.myApplications.length.toString() + ' 条', icon: '📨' })
          Column() {
            if (this.myApplications.length === 0) {
              Text('还没有提交过申请')
                .fontSize(12.5)
                .fontColor(Theme.inkTertiary)
                .padding(Spacing.L)
            } else {
              ForEach(this.myApplications, (a: AccessRequestInfo, idx: number) => {
                this.ApplicationRow(a)
                if (idx < this.myApplications.length - 1) {
                  Divider().color(Theme.line).strokeWidth(0.5)
                }
              }, (a: AccessRequestInfo) => 'myapp_' + a.requestId)
            }
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: 4, bottom: 4 })
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
