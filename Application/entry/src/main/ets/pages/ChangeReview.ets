import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { PageNavBar } from '../components/PageNavBar';
import { FamilyService } from '../service/FamilyService';
import { FamilySyncService } from '../service/FamilySyncService';
import { GenealogyService } from '../service/GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import { ChangeRequestInfo, Role, SyncResult, opLabel, roleLabel } from '../model/FamilyDomain';
import { FieldChange, displayValue, fieldLabel, parsePatchJson } from '../util/PatchUtil';
import { Genealogy } from '../model/Genealogy';

/**
 * 待审变更（方案 §七 ChangeReview）。
 *
 * 谱主：待审列表 → 字段级 diff（旧值 → 新值）→ 通过（合入并分配 rev）/ 退回。
 * 编辑者：看到自己分支内的待审状态。
 * 只处理「改谱内容」，访问申请在 FamilyMembers 页处理，两者不混。
 */
@Entry
@Component
struct ChangeReview {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('gpFamilyRole') role: string = '';

  @State familyId: string = '';
  @State requests: ChangeRequestInfo[] = [];
  @State busy: boolean = false;
  @State message: string = '';
  @State expandedId: string = '';
  @State noteText: string = '';

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const book: Genealogy = GenealogyService.getInstance().getBook();
    this.familyId = book.familyId;
    this.load();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async load(): Promise<void> {
    if (this.familyId.length === 0) {
      return;
    }
    this.busy = true;
    this.message = '';
    try {
      this.requests = await FamilyService.getInstance().listPendingChanges(this.familyId);
      if (this.requests.length === 0) {
        this.message = this.role === Role.OWNER
          ? '没有待审的变更。亲戚提交补录后会出现在这里。'
          : '没有你可以审阅的变更（编辑者只能看到自己认领分支内的提交）。';
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.message = '读取失败：' + be.message;
    } finally {
      this.busy = false;
    }
  }

  private async review(r: ChangeRequestInfo, approve: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const note: string = await FamilyService.getInstance().reviewChange(r.requestId, approve, this.noteText);
      this.toast(approve ? '已合入，新的修订号已生成' : '已退回提交者');
      this.noteText = '';
      this.expandedId = '';
      await this.load();
      if (approve) {
        const synced: SyncResult = await FamilySyncService.getInstance().syncCurrent('after-review');
        GenealogyStore.notifyChanged();
        if (synced.integrityIssues.length > 0) {
          const shown: string[] = synced.integrityIssues.slice(0, 5);
          let text: string = shown.join('\n');
          if (synced.integrityIssues.length > shown.length) {
            text = text + '\n……另有 ' + (synced.integrityIssues.length - shown.length).toString() + ' 项';
          }
          this.getUIContext().showAlertDialog({
            title: synced.integrityBlocked > 0 ? '部分变更未合入' : '数据一致性提示',
            message: text + '\n\n请到「名录」核对相关人员的编号、父母与配偶关系。',
            confirm: {
              value: '知道了',
              action: (): void => {
              }
            }
          });
        }
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('操作失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  private targetName(r: ChangeRequestInfo): string {
    const p = GenealogyService.getInstance().getPerson(r.targetUid);
    return p !== null ? p.name : (r.targetName.length > 0 ? r.targetName : r.targetUid);
  }

  @Builder
  DiffLine(key: string, c: FieldChange) {
    Row() {
      Text(fieldLabel(key))
        .fontSize(11.5)
        .fontColor(Theme.inkTertiary)
        .width(72)
      Column() {
        Text(displayValue(c.b))
          .fontSize(11.5)
          .fontColor(Theme.inkTertiary)
          .decoration({ type: TextDecorationType.LineThrough, color: Theme.inkTertiary })
          .width('100%')
        Text('→ ' + displayValue(c.a))
          .fontSize(12.5)
          .fontColor(Theme.ink)
          .margin({ top: 2 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  RequestCard(r: ChangeRequestInfo) {
    Column() {
      Row() {
        Text(opLabel(r.op))
          .fontSize(10.5)
          .fontColor('#FFFFFF')
          .backgroundColor(Theme.primary)
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        Text(this.targetName(r))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .margin({ left: 6 })
          .layoutWeight(1)
          .maxLines(1)
        Text(new Date(r.createdAt).toLocaleDateString())
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
      }
      .width('100%')
      Text('提交者：' + (r.submitterName.length > 0 ? r.submitterName : r.submitterId) + ' · 基线 rev ' +
        r.baseRev.toString())
        .fontSize(10.5)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 3 })
        .width('100%')
      if (r.evidence.length > 0) {
        Text('依据：' + r.evidence)
          .fontSize(11.5)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 3 })
          .width('100%')
      }

      if (this.expandedId === r.requestId) {
        Divider().color(Theme.line).strokeWidth(0.5).margin({ top: Spacing.S, bottom: Spacing.S })
        ForEach(Array.from(parsePatchJson(r.patchJson).entries()), (entry: [string, FieldChange]) => {
          this.DiffLine(entry[0], entry[1])
        }, (entry: [string, FieldChange]) => 'diff_' + r.requestId + '_' + entry[0])
        if (r.op === 'DELETE_REQ') {
          Text('该申请会删除此人（云端保留墓碑，可追溯是谁在何时删除）。')
            .fontSize(11.5)
            .fontColor(Theme.danger)
            .width('100%')
        }
        if (this.role === Role.OWNER) {
          TextInput({ text: this.noteText, placeholder: '审批备注（退回时建议说明原因）' })
            .height(34)
            .fontSize(12.5)
            .backgroundColor(Theme.field)
            .borderRadius(8)
            .margin({ top: Spacing.S })
            .onChange((v: string): void => {
              this.noteText = v;
            })
          Row() {
            Button('退回')
              .fontSize(13)
              .height(34)
              .layoutWeight(1)
              .backgroundColor(Theme.field)
              .fontColor(Theme.danger)
              .enabled(!this.busy)
              .onClick((): void => {
                this.review(r, false);
              })
            Button('通过并合入')
              .fontSize(13)
              .height(34)
              .layoutWeight(1)
              .margin({ left: Spacing.S })
              .backgroundColor(Theme.alive)
              .fontColor('#FFFFFF')
              .enabled(!this.busy)
              .onClick((): void => {
                this.review(r, true);
              })
          }
          .width('100%')
          .margin({ top: Spacing.S })
        }
      }
      Text(this.expandedId === r.requestId ? '收起 ∧' : '查看字段变化 ∨')
        .fontSize(11.5)
        .fontColor(Theme.primary)
        .margin({ top: Spacing.S })
        .width('100%')
        .textAlign(TextAlign.End)
        .onClick((): void => {
          this.expandedId = this.expandedId === r.requestId ? '' : r.requestId;
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  build() {
    Column() {
      PageNavBar({
        title: '待审变更',
        subtitle: roleLabel(this.role) + ' · 只有谱主可以合入',
        actionText: '刷新',
        busy: this.busy,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        },
        onAction: (): void => {
          this.load();
        }
      })
      Scroll() {
        Column() {
          if (this.familyId.length === 0) {
            Text('本谱尚未接入云家族，没有云端变更')
              .fontSize(13)
              .fontColor(Theme.inkSecondary)
              .margin({ top: Spacing.XL })
          } else {
            TS({ title: '待审核', subtitle: '共 ' + this.requests.length.toString() + ' 条', icon: '📝' })
            Column() {
              if (this.requests.length === 0) {
                Text(this.message.length > 0 ? this.message : '暂无待审变更')
                  .fontSize(12.5)
                  .fontColor(Theme.inkTertiary)
                  .padding(Spacing.L)
              } else {
                ForEach(this.requests, (r: ChangeRequestInfo, idx: number) => {
                  this.RequestCard(r)
                  if (idx < this.requests.length - 1) {
                    Divider().color(Theme.line).strokeWidth(0.5)
                  }
                }, (r: ChangeRequestInfo) => 'req_' + r.requestId)
              }
            }
            .width('100%')
            .padding({ left: Spacing.L, right: Spacing.L, top: 4, bottom: 4 })
            .backgroundColor(Theme.card)
            .borderRadius(Radius.L)
            .border({ width: 0.5, color: Theme.line })

            Text('合入时云端会：校验基线 rev（过期则退回）→ 分配新的家族修订号 → 写入成员与审计流水。' +
              '“一人删一人改”时会以墓碑提示，而不是凭空出现幽灵人物。')
              .fontSize(10.5)
              .fontColor(Theme.inkTertiary)
              .margin({ top: Spacing.M })
              .width('100%')
              .lineHeight(16)
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
