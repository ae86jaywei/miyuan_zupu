import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { PageNavBar } from '../components/PageNavBar';
import { DirectoryForm, DirectoryService, MEMBER_COUNT_BANDS } from '../service/DirectoryService';
import { FamilyService } from '../service/FamilyService';
import { GenealogyService } from '../service/GenealogyService';
import { DirectoryEntry } from '../model/FamilyDomain';
import { Genealogy } from '../model/Genealogy';
import { RouterUtil } from '../util/RouterUtil';

/**
 * 族谱黄页（方案 §五.11、§十三.4）。
 *
 * 红线（页面层必须守住）：
 *  1. 搜索结果只渲染**索引元数据**，**不得渲染任何人物数据**；
 *  2. 详情只有两个动作：「申请查看」与「我要加入」，点进去仍要过三条门槛；
 *  3. 谱主侧的上架开关默认关闭，关闭 = 云端物理删除该行（不是写一行 false）。
 */
@Entry
@Component
struct FamilyDirectoryView {
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;
  @StorageProp('gpCloudReady') cloudReady: boolean = false;

  @State keyword: string = '';
  @State results: DirectoryEntry[] = [];
  @State searching: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';
  @State form: DirectoryForm = new DirectoryForm();
  @State showOwnerPanel: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    const book: Genealogy = GenealogyService.getInstance().getBook();
    this.form = DirectoryService.defaultForm(book);
    this.search();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async search(): Promise<void> {
    if (!this.cloudReady) {
      this.message = '请先登录华为账号并等待云服务就绪';
      return;
    }
    this.searching = true;
    try {
      this.results = await DirectoryService.getInstance().search(this.keyword);
      if (this.results.length === 0) {
        this.message = '没有搜到已上架的族谱。多数家庭默认不上架黄页，可让谱主把加入码或分享链接发给你。';
      } else {
        this.message = '';
      }
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.message = '搜索失败：' + be.message;
    } finally {
      this.searching = false;
    }
  }

  /** 上架：先确认告知，再写入黄页并在 Family.directoryEnabled 置 true */
  private publish(enable: boolean): void {
    const book: Genealogy = GenealogyService.getInstance().getBook();
    if (book.familyId.length === 0) {
      this.toast('本谱尚未接入云家族');
      return;
    }
    if (!FamilyService.getInstance().canEditCurrent()) {
      this.toast('只有谱主或编辑者可以修改黄页信息');
      return;
    }
    if (!enable) {
      this.doPublish(false);
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '确认上架到族谱黄页？',
      message: '上架后，任何登录用户都能按谱名/姓氏/地域搜索到本谱的索引信息（谱名、姓氏、地域、支系概述、人数区间、提示文案）。' +
        '这些内容从提交起就对所有人可见，且可能被他人记录或转存，事后下架也无法追回已被看到的信息。' +
        '任何人物数据都不会出现在黄页里。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '确认上架',
        fontColor: Theme.primary,
        action: (): void => {
          this.doPublish(true);
        }
      }
    });
  }

  private async doPublish(enable: boolean): Promise<void> {
    const book: Genealogy = GenealogyService.getInstance().getBook();
    this.busy = true;
    try {
      const f: DirectoryForm = this.form;
      f.directoryEnabled = enable;
      await DirectoryService.getInstance().upsert(book.familyId, f);
      this.form = f;
      this.toast(enable ? '已上架，族人现在可以搜到这部谱' : '已下架，该谱已从黄页移除（不是隐藏）');
      await this.search();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('操作失败：' + be.message);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  Card(e: DirectoryEntry) {
    Column() {
      Row() {
        Text(e.title.length > 0 ? e.title : '未命名族谱')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(e.surname.length > 0 ? e.surname + '氏' : '')
          .fontSize(11)
          .fontColor(Theme.gold)
      }
      .width('100%')
      Text((e.region.length > 0 ? e.region : '地域未填') +
        (e.memberCountBand.length > 0 ? ' · ' + e.memberCountBand + ' 人' : ''))
        .fontSize(11.5)
        .fontColor(Theme.inkTertiary)
        .margin({ top: 4 })
        .width('100%')
      if (e.branchSummary.length > 0) {
        Text(e.branchSummary)
          .fontSize(12)
          .fontColor(Theme.inkSecondary)
          .margin({ top: 4 })
          .maxLines(2)
          .width('100%')
      }
      Row() {
        Text(e.accessHint.length > 0 ? e.accessHint : '需谱主审核后可查看')
          .fontSize(10.5)
          .fontColor(Theme.primary)
          .layoutWeight(1)
        Button('申请查看')
          .fontSize(12)
          .height(30)
          .backgroundColor(Theme.primary)
          .fontColor('#FFFFFF')
          .onClick((): void => {
            RouterUtil.accessApply(this.getUIContext(), e.familyId);
          })
        Button('我要加入')
          .fontSize(12)
          .height(30)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.field)
          .fontColor(Theme.primary)
          .onClick((): void => {
            RouterUtil.accessApply(this.getUIContext(), e.familyId);
          })
      }
      .width('100%')
      .margin({ top: Spacing.M })
    }
    .width('100%')
    .padding(Spacing.L)
    .backgroundColor(Theme.card)
    .borderRadius(Radius.L)
    .border({ width: 0.5, color: Theme.line })
    .margin({ bottom: Spacing.M })
  }

  @Builder
  FieldRow(label: string, value: string, placeholder: string, onChange: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .width('100%')
      TextInput({ text: value, placeholder: placeholder })
        .height(36)
        .fontSize(13)
        .backgroundColor(Theme.field)
        .borderRadius(8)
        .margin({ top: 3 })
        .onChange((v: string): void => {
          onChange(v);
        })
    }
    .width('100%')
    .margin({ bottom: Spacing.S })
  }

  @Builder
  OwnerPanel() {
    Column() {
      Row() {
        Column() {
          Text('黄页上架')
            .fontSize(14)
            .fontColor(Theme.ink)
          Text('默认关闭。关闭 = 从黄页物理移除，别人搜不到。')
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.form.directoryEnabled })
          .selectedColor(Theme.primary)
          .onChange((isOn: boolean): void => {
            this.publish(isOn);
          })
      }
      .width('100%')

      Divider().color(Theme.line).strokeWidth(0.5).margin({ top: Spacing.S, bottom: Spacing.S })
      this.FieldRow('谱名', this.form.title, '如：新宁李氏三修族谱', (v: string): void => {
        this.form.title = v;
      })
      this.FieldRow('姓氏', this.form.surname, '如：李', (v: string): void => {
        this.form.surname = v;
      })
      this.FieldRow('地域', this.form.region, '如：湖南·邵阳·新宁', (v: string): void => {
        this.form.region = v;
      })
      this.FieldRow('支系概述', this.form.branchSummary, '一句话概述，不得含具体人物姓名', (v: string): void => {
        this.form.branchSummary = v;
      })
      this.FieldRow('对外提示', this.form.accessHint, '如：需谱主审核后可查看', (v: string): void => {
        this.form.accessHint = v;
      })
      Text('人数区间（不填精确人数）')
        .fontSize(11)
        .fontColor(Theme.inkTertiary)
        .width('100%')
      Row() {
        ForEach(MEMBER_COUNT_BANDS, (band: string) => {
          Text(band)
            .fontSize(11.5)
            .fontColor(this.form.memberCountBand === band ? '#FFFFFF' : Theme.inkSecondary)
            .backgroundColor(this.form.memberCountBand === band ? Theme.primary : Theme.field)
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 6, top: 4 })
            .onClick((): void => {
              this.form.memberCountBand = band;
            })
        }, (band: string) => 'band_' + band)
      }
      .width('100%')
      Button(this.busy ? '保存中…' : '保存黄页信息')
        .fontSize(13)
        .height(36)
        .width('100%')
        .margin({ top: Spacing.M })
        .backgroundColor(Theme.field)
        .fontColor(Theme.primary)
        .enabled(!this.busy)
        .onClick((): void => {
          this.doPublish(this.form.directoryEnabled);
        })
      Text('黄页里只允许出现谱名 / 姓氏 / 地域 / 支系概述 / 人数区间 / 封面图 / 提示文案。上传任何人物数据都会被云函数拒绝。')
        .fontSize(10.5)
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

  build() {
    Column() {
      PageNavBar({
        title: '族谱黄页',
        subtitle: '只含索引信息 · 不含任何人物数据',
        actionText: FamilyService.getInstance().canEditCurrent() ? '管理' : '',
        busy: this.busy,
        onBack: (): void => {
          this.getUIContext().getRouter().back();
        },
        onAction: (): void => {
          this.showOwnerPanel = !this.showOwnerPanel;
        }
      })
      Scroll() {
        Column() {
          if (this.showOwnerPanel) {
            this.OwnerPanel()
          }
          Row() {
            TextInput({ text: this.keyword, placeholder: '谱名 / 姓氏 / 地域' })
              .height(38)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor(Theme.field)
              .borderRadius(10)
              .onChange((v: string): void => {
                this.keyword = v;
              })
              .onSubmit(() => {
                this.search();
              })
            Button(this.searching ? '搜索中' : '搜索')
              .fontSize(13)
              .height(38)
              .margin({ left: Spacing.S })
              .backgroundColor(Theme.primary)
              .fontColor('#FFFFFF')
              .enabled(!this.searching)
              .onClick((): void => {
                this.search();
              })
          }
          .width('100%')
          .margin({ bottom: Spacing.M })

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .padding(Spacing.M)
              .backgroundColor(Theme.highlightBg)
              .borderRadius(Radius.S)
              .margin({ bottom: Spacing.M })
          }

          ForEach(this.results, (e: DirectoryEntry) => {
            this.Card(e)
          }, (e: DirectoryEntry) => 'dir_' + e.dirId)

          Text('注意：黄页里出现 ≠ 能看到人物数据；没出现在黄页里 ≠ 不存在（谱主可关闭上架，此时只能靠加入码或分享链接进入）。')
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .width('100%')
            .margin({ top: Spacing.M })
            .lineHeight(16)
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
