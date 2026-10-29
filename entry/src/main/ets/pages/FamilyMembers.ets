import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { PageNavBar } from '../components/PageNavBar';
import { AccountService } from '../service/AccountService';
import { FamilyService } from '../service/FamilyService';
import { GenealogyService } from '../service/GenealogyService';
import {
  AccessKind, AccessRequestInfo, MemberInfo, Role,
  accessKindLabel, membershipStatusLabel, roleLabel
} from '../model/FamilyDomain';
import { Genealogy } from '../model/Genealogy';
import { RouterUtil } from '../util/RouterUtil';

/**
 * 成员与访问申请（方案 §七 FamilyMembers + v1.3 增补）。
 *
 * 谱主视图：加入码、成员角色/分支/期限、访问申请审批（这也是 §十三 三条门槛的唯一审批入口）。
 * 成员视图：我的角色与授权期限。
 * 注意：ChangeReview 只管改谱内容，访问申请只在本页处理，两者不混。
 */
@Entry
@Component
struct FamilyMembers {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('gpFamilyRole') myRole: string = '';

  @State familyId: string = '';
  @State inviteCode: string = '';
  @State inviteRole: string = Role.VIEWER;
  @State members: MemberInfo[] = [];
  @State applications: AccessRequestInfo[] = [];
  @State busy: boolean = false;
  @State errorText: string = '';
  @State expireDaysText: string = '180';
  @State relationText: string = '';
  @State evidenceText: string = '';
  @State applicantName: string = '';

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const book: Genealogy = GenealogyService.getInstance().getBook();
    this.familyId = book.familyId;
    this.applicantName = AccountService.getInstance().getDisplayId();
    this.reload();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private isOwner(): boolean {
    return this.myRole === Role.OWNER;
  }

  private async reload(): Promise<void> {
    if (this.familyId.length === 0) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      if (this.isOwner()) {
        this.members = await FamilyService.getInstance().listMembers(this.familyId);
        this.applications = await FamilyService.getInstance().listPendingAccess(this.familyId);
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.errorText = '读取失败：' + be.message;
    } finally {
      this.busy = false;
    }
  }

  /** 轮换加入码：旧码立即失效（方案 §八.3） */
  private async doRotateInvite(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      this.inviteCode = await FamilyService.getInstance().rotateInvite(this.familyId, 0, this.inviteRole);
      this.toast('已生成新的加入码，旧码立即失效');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('轮换失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  private async setMemberRole(m: MemberInfo, role: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await FamilyService.getInstance().updateMember(this.familyId, m.userId, role, m.branchRootUid, m.expireAt,
        m.status);
      this.toast('已设置为' + roleLabel(role));
      await this.reload();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('设置失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  private async revokeMember(m: MemberInfo): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await FamilyService.getInstance().updateMember(this.familyId, m.userId, m.role, m.branchRootUid, m.expireAt,
        'REVOKED');
      this.toast('已撤销该成员的授权');
      await this.reload();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('撤销失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  /** 审批通过：唯一动作 = 写一条 Membership（期限默认按申请类型） */
  private async approve(a: AccessRequestInfo): Promise<void> {
    if (this.busy) {
      return;
    }
    const days: number = Number.parseInt(this.expireDaysText, 10);
    const expireAt: number = a.kind === AccessKind.JOIN_CLAIM || Number.isNaN(days) || days <= 0
      ? 0
      : Date.now() + days * 24 * 3600 * 1000;
    this.busy = true;
    try {
      await FamilyService.getInstance().reviewAccess(a.requestId, true,
        a.kind === AccessKind.JOIN_CLAIM ? '同意成为族人' : '同意查看', a.grantedRole, expireAt);
      this.toast('已通过，申请人的授权立即生效');
      await this.reload();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('审批失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  private async reject(a: AccessRequestInfo): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await FamilyService.getInstance().reviewAccess(a.requestId, false, '谱主未通过', '', 0);
      this.toast('已拒绝');
      await this.reload();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('操作失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  private expireText(expireAt: number): string {
    if (expireAt <= 0) {
      return '永久';
    }
    const d: Date = new Date(expireAt);
    return d.getFullYear().toString() + '-' + (d.getMonth() + 1).toString().padStart(2, '0') + '-' +
      d.getDate().toString().padStart(2, '0') + ' 到期';
  }

  private async submitApply(kind: string): Promise<void> {
    if (this.busy || this.familyId.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const result: string = await FamilyService.getInstance().requestAccess(this.familyId, kind, this.relationText, '',
        this.evidenceText, this.applicantName);
      if (result === 'ALREADY_MEMBER') {
        this.toast('你已是该谱成员，无需重复申请');
      } else if (result === 'DUPLICATED') {
        this.toast('已有待审核的申请，请等待谱主处理');
      } else {
        this.toast('申请已提交，请等待谱主审核');
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('提交失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  InviteBlock() {
    Column() {
      Text('加入码')
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .width('100%')
      Text(this.inviteCode.length > 0 ? this.inviteCode : '点击右侧生成')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.gold)
        .width('100%')
        .margin({ top: 4 })
        .copyOption(CopyOptions.LocalDevice)
      Button('重新生成')
        .fontSize(12.5)
        .height(32)
        .width('100%')
        .margin({ top: Spacing.S })
        .backgroundColor(Theme.field)
        .fontColor(Theme.primary)
        .onClick((): void => {
          this.doRotateInvite();
        })
      Text('把加入码发给亲戚，他们在「我的家族」输入即可加入。加入后默认只读，可在此提升为编辑者；重新生成后旧码立即失效。')
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 6 })
        .width('100%')
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ bottom: Spacing.M })
  }

  @Builder
  MemberRow(m: MemberInfo) {
    Column() {
      Text(m.displayName)
        .fontSize(14)
        .fontColor(Theme.ink)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(roleLabel(m.role) + ' · ' + membershipStatusLabel(m.status) + ' · ' + this.expireText(m.expireAt) +
        (m.branchRootUid.length > 0 ? ' · 分支 ' + m.branchRootUid : ' · 全谱'))
        .fontSize(10.5)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 2 })
        .width('100%')
      if (m.role !== Role.OWNER) {
        Row() {
          Text(roleLabel(Role.VIEWER))
            .fontSize(11.5)
            .fontColor(m.role === Role.VIEWER ? '#FFFFFF' : Theme.inkSecondary)
            .backgroundColor(m.role === Role.VIEWER ? Theme.primary : Theme.field)
            .borderRadius(11)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ right: 6 })
            .onClick((): void => {
              this.setMemberRole(m, Role.VIEWER);
            })
          Text(roleLabel(Role.EDITOR))
            .fontSize(11.5)
            .fontColor(m.role === Role.EDITOR ? '#FFFFFF' : Theme.inkSecondary)
            .backgroundColor(m.role === Role.EDITOR ? Theme.primary : Theme.field)
            .borderRadius(11)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick((): void => {
              this.setMemberRole(m, Role.EDITOR);
            })
          Blank()
          Text('撤销')
            .fontSize(11.5)
            .fontColor(Theme.danger)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick((): void => {
              this.revokeMember(m);
            })
        }
        .width('100%')
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  ApplyRow(a: AccessRequestInfo) {
    Column() {
      Row() {
        Text(a.applicantName.length > 0 ? a.applicantName : a.applicantId)
          .fontSize(14)
          .fontColor(Theme.ink)
          .layoutWeight(1)
          .maxLines(1)
        Text(accessKindLabel(a.kind))
          .fontSize(10.5)
          .fontColor(Theme.primary)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(Theme.highlightBg)
      }
      .width('100%')
      if (a.relationClaim.length > 0) {
        Text('关系说明：' + a.relationClaim)
          .fontSize(11.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 4 })
          .width('100%')
      }
      if (a.branchClaimUid.length > 0) {
        Text('认领分支根人物：' + a.branchClaimUid)
          .fontSize(11.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 2 })
          .width('100%')
      }
      if (a.evidence.length > 0) {
        Text('依据：' + a.evidence)
          .fontSize(11.5)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 2 })
          .width('100%')
      }
      Text('申请人ID：' + a.applicantId)
        .fontSize(10)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 2 })
        .width('100%')
      Row() {
        if (a.kind === AccessKind.VIEW_APPLY) {
          Text('期限')
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
          TextInput({ text: this.expireDaysText })
            .height(30)
            .width(56)
            .fontSize(12)
            .backgroundColor(Theme.field)
            .borderRadius(6)
            .margin({ left: 4, right: 4 })
            .onChange((v: string): void => {
              this.expireDaysText = v;
            })
          Text('天')
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
        }
        Blank()
        Button('拒绝')
          .fontSize(12.5)
          .height(32)
          .backgroundColor(Theme.field)
          .fontColor(Theme.danger)
          .onClick((): void => {
            this.reject(a);
          })
        Button('通过')
          .fontSize(12.5)
          .height(32)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.alive)
          .fontColor('#FFFFFF')
          .onClick((): void => {
            this.approve(a);
          })
      }
      .width('100%')
      .margin({ top: Spacing.S })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  SelfApplyBlock() {
    Column() {
      Text('向谱主申请')
        .fontSize(14)
        .fontColor(Theme.ink)
        .width('100%')
      Text('申请查看获批后默认 180 天有效；申请成为族人获批后永久有效，并可认领一个分支。')
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 3 })
        .width('100%')
      TextInput({ text: this.relationText, placeholder: '关系说明，如：我是三房李泽民之子' })
        .height(36)
        .fontSize(13)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.relationText = v;
        })
      TextInput({ text: this.evidenceText, placeholder: '依据，如：家有旧谱照片 / 介绍人：李某' })
        .height(36)
        .fontSize(13)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: Spacing.S })
        .onChange((v: string): void => {
          this.evidenceText = v;
        })
      Row() {
        Button('申请查看')
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor(Theme.primary)
          .fontColor('#FFFFFF')
          .onClick((): void => {
            this.submitApply(AccessKind.VIEW_APPLY);
          })
        Button('申请成为族人')
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.field)
          .fontColor(Theme.primary)
          .onClick((): void => {
            this.submitApply(AccessKind.JOIN_CLAIM);
          })
      }
      .width('100%')
      .margin({ top: Spacing.S })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
  }

  build() {
    Column() {
      PageNavBar({
        title: '成员与访问申请',
        subtitle: roleLabel(this.myRole),
        busy: this.busy,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        }
      })
      Scroll() {
        Column() {
          if (this.familyId.length === 0) {
            Text('本谱尚未接入云家族')
              .fontSize(14)
              .fontColor(Theme.inkSecondary)
              .margin({ top: Spacing.XL })
            Button('去「我的家族」接入')
              .fontSize(13)
              .height(36)
              .margin({ top: Spacing.M })
              .backgroundColor(Theme.primary)
              .onClick((): void => {
                RouterUtil.familyHome(this.getUIContext());
              })
          } else if (this.isOwner()) {
            this.InviteBlock()
            TS({ title: '待审访问申请', subtitle: '通过后立即写入一条成员授权', icon: '📨' })
            Column() {
              if (this.applications.length === 0) {
                Text(this.errorText.length > 0 ? this.errorText : '暂无待审申请')
                  .fontSize(12.5)
                  .fontColor(Theme.inkTertiary)
                  .padding(Spacing.L)
              } else {
                ForEach(this.applications, (a: AccessRequestInfo, idx: number) => {
                  this.ApplyRow(a)
                  if (idx < this.applications.length - 1) {
                    Divider().color(Theme.line).strokeWidth(0.5)
                  }
                }, (a: AccessRequestInfo) => 'app_' + a.requestId)
              }
            }
            .width('100%')
            .padding({ left: Spacing.L, right: Spacing.L, top: 4, bottom: 4 })
            .backgroundColor(Theme.card)
            .borderRadius(Radius.L)
            .border({ width: 0.5, color: Theme.line })
            .margin({ bottom: Spacing.M })

            TS({ title: '成员', subtitle: '共 ' + this.members.length.toString() + ' 人', icon: '👥' })
            Column() {
              ForEach(this.members, (m: MemberInfo, idx: number) => {
                this.MemberRow(m)
                if (idx < this.members.length - 1) {
                  Divider().color(Theme.line).strokeWidth(0.5)
                }
              }, (m: MemberInfo) => 'mem_' + m.userId)
            }
            .width('100%')
            .padding({ left: Spacing.L, right: Spacing.L, top: 4, bottom: 4 })
            .backgroundColor(Theme.card)
            .borderRadius(Radius.L)
            .border({ width: 0.5, color: Theme.line })
          } else {
            Column() {
              Text('你在这部谱中的角色')
                .fontSize(12)
                .fontColor(Theme.inkTertiary)
              Text(roleLabel(this.myRole))
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.primary)
                .margin({ top: 4 })
              Text(this.myRole === Role.EDITOR
                ? '你可以提交补录，谱主审核后合入；也可修改认领分支内的族人。'
                : '你可以浏览族谱，如需补录请向谱主申请成为族人。')
                .fontSize(11.5)
                .fontColor(Theme.inkSecondary)
                .margin({ top: 6 })
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding(Spacing.L)
            .backgroundColor(Theme.card)
            .borderRadius(Radius.L)
            .border({ width: 0.5, color: Theme.line })
            .margin({ bottom: Spacing.M })
            this.SelfApplyBlock()
          }
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
