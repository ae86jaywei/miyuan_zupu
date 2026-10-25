import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { GenealogyService } from '../service/GenealogyService';
import { ExportService } from '../service/ExportService';
import { GenealogyStore } from '../store/GenealogyStore';
import { GenealogyScope } from '../model/Scope';
import { Person } from '../model/Person';
import { Breakpoint } from '../common/Constants';

/**
 * 导入 / 导出中心。
 */
@Entry
@Component
struct ImportExport {
  @StorageProp('windowWidth') windowWidth: number = 360;
  @State busy: boolean = false;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }
  @State includePrivate: boolean = true;
  @State mergeStrategy: string = 'skip';
  @State previewText: string = '';
  @State parsedCount: number = 0;
  @State pendingPeople: Person[] = [];

  private svc(): GenealogyService {
    return GenealogyService.getInstance();
  }

  private async doExport(kind: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const people: Person[] = this.svc().getPeople();
      let content: string = '';
      let fileName: string = '';
      const stamp: string = new Date().getFullYear().toString() +
        (new Date().getMonth() + 1).toString().padStart(2, '0') +
        new Date().getDate().toString().padStart(2, '0');
      if (kind === 'json-full') {
        content = ExportService.toJson(people, this.svc().getBook(), true);
        fileName = '族谱备份_' + stamp + '.json';
      } else if (kind === 'json-public') {
        content = ExportService.toJson(people, this.svc().getBook(), false);
        fileName = '族谱公开版_' + stamp + '.json';
      } else if (kind === 'csv') {
        content = ExportService.toCsv(people, this.includePrivate);
        fileName = '族谱表格_' + stamp + '.csv';
      } else {
        content = ExportService.toMarkdown(people, this.svc().getBook());
        fileName = '族谱谱文_' + stamp + '.md';
      }
      this.previewText = content.length > 1200 ? content.substring(0, 1200) + '\n……' : content;
      await ExportService.saveAsFile(GenealogyScope.context(), fileName, content);
      this.getUIContext().getPromptAction().showToast({ message: '已导出 ' + fileName });
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== 13900042) {
        this.getUIContext().getPromptAction().showToast({ message: '导出失败：' + err.message });
      }
    } finally {
      this.busy = false;
    }
  }

  private async doImport(kind: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const text: string = await ExportService.pickFileText(GenealogyScope.context(),
        kind === 'json' ? ['.json'] : ['.csv', '.txt']);
      if (text.length === 0) {
        return;
      }
      this.previewText = text.length > 1200 ? text.substring(0, 1200) + '\n……' : text;
      const list: Person[] = kind === 'json' ? ExportService.parseJson(text) : ExportService.parseCsv(text);
      this.pendingPeople = list;
      this.parsedCount = list.length;
      this.getUIContext().getPromptAction().showToast({ message: '解析到 ' + list.length.toString() + ' 条记录，请确认导入' });
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: '导入失败：' + err.message });
    } finally {
      this.busy = false;
    }
  }

  private async confirmImport(): Promise<void> {
    if (this.pendingPeople.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const n: number = await this.svc().importPeople(this.pendingPeople, this.mergeStrategy);
      GenealogyStore.notifyChanged();
      this.pendingPeople = [];
      this.parsedCount = 0;
      this.getUIContext().getPromptAction().showToast({ message: '成功导入 ' + n.toString() + ' 人' });
    } catch (e) {
      const err = e as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: '导入失败：' + err.message });
    } finally {
      this.busy = false;
    }
  }

  @Builder
  ExportRow(title: string, desc: string, tag: string, action: () => void) {
    Row() {
      Column() {
        Row() {
          Text(title).fontSize(14).fontColor(Theme.ink)
          Text(tag)
            .fontSize(10)
            .fontColor(Theme.gold)
            .backgroundColor('#FBF4E2')
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 6 })
        }
        Text(desc)
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('导出 ›')
        .fontSize(12.5)
        .fontColor(Theme.primary)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick((): void => {
      action();
    })
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(22)
          .fontColor(Theme.ink)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.getUIContext().getRouter().back();
          })
        Text('导入 / 导出')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        if (this.busy) {
          LoadingProgress().width(20).height(20).color(Theme.primary)
        }
      }
      .width('100%')
      .height(34)
      .padding({ left: Spacing.S, right: Spacing.L })
      .backgroundColor(Theme.card)
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      Scroll() {
        Column() {
          TS({ title: '导出', subtitle: '当前共 ' + this.svc().getPeople().length.toString() + ' 位族人', icon: '📤' })
          Column() {
            this.ExportRow('JSON 全量备份', '含全部字段与隐私信息，用于换机/归档，可再次导入', '推荐',
              (): void => {
                this.doExport('json-full');
              })
            Divider().color(Theme.line).strokeWidth(0.5)
            this.ExportRow('JSON 公开分享版', '自动去除手机号、微信号，可放心分享给族人', '脱敏',
              (): void => {
                this.doExport('json-public');
              })
            Divider().color(Theme.line).strokeWidth(0.5)
            this.ExportRow('CSV 表格', '完全对齐《关键信息字段》22 项字段，可用 Excel 打开', 'Excel',
              (): void => {
                this.doExport('csv');
              })
            Divider().color(Theme.line).strokeWidth(0.5)
            this.ExportRow('Markdown 牒记谱文', '按世序生成的文字谱文，可直接打印或转 PDF', '成册',
              (): void => {
                this.doExport('markdown');
              })
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          TS({ title: '导入', subtitle: '支持本应用导出的 JSON/CSV，或 Excel 另存的 CSV', icon: '📥' })
          Column() {
            Row() {
              Button('选择 JSON 文件')
                .fontSize(13)
                .height(36)
                .backgroundColor(Theme.primary)
                .onClick((): void => {
                  this.doImport('json');
                })
              Button('选择 CSV 文件')
                .fontSize(13)
                .height(36)
                .backgroundColor(Theme.field)
                .fontColor(Theme.primary)
                .margin({ left: Spacing.S })
                .onClick((): void => {
                  this.doImport('csv');
                })
            }
            .width('100%')

            Text('唯一ID冲突时：')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: Spacing.M, bottom: 6 })
            Row() {
              ForEach([['skip', '跳过'], ['replace', '覆盖'], ['newId', '另生成ID']], (item: string[]) => {
                Text(item[1])
                  .fontSize(12)
                  .fontColor(this.mergeStrategy === item[0] ? '#FFFFFF' : Theme.inkSecondary)
                  .backgroundColor(this.mergeStrategy === item[0] ? Theme.primary : Theme.field)
                  .borderRadius(12)
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .margin({ right: 6 })
                  .onClick((): void => {
                    this.mergeStrategy = item[0];
                  })
              }, (item: string[]) => 'ms_' + item[0])
            }
            .width('100%')

            if (this.parsedCount > 0) {
              Column() {
                Text('已解析 ' + this.parsedCount.toString() + ' 条记录')
                  .fontSize(13)
                  .fontColor(Theme.alive)
                if (this.pendingPeople.length > 0) {
                  Text('示例：' + this.pendingPeople[0].name + '（' + this.pendingPeople[0].uid + '）')
                    .fontSize(11)
                    .fontColor(Theme.inkTertiary)
                    .margin({ top: 4 })
                }
                Button('确认导入')
                  .fontSize(13)
                  .height(34)
                  .backgroundColor(Theme.alive)
                  .margin({ top: Spacing.S })
                  .onClick((): void => {
                    this.confirmImport();
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(Spacing.M)
              .backgroundColor(Theme.highlightBg)
              .borderRadius(Radius.S)
              .margin({ top: Spacing.M })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

          if (this.previewText.length > 0) {
            TS({ title: '内容预览', icon: '👁' })
            Column() {
              Text(this.previewText)
                .fontSize(11)
                .fontColor(Theme.inkSecondary)
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
            .backgroundColor(Theme.card)
            .borderRadius(16)
            .border({ width: 0.5, color: Theme.line })
            .margin({ bottom: Spacing.M })
            .clip(true)
          }

          TS({ title: '字段规范', subtitle: '《关键信息字段_20261023.xlsx》', icon: '📋' })
          Column() {
            Text('身份标识：世代、唯一ID、谱名、曾用名/小名、性别、辈分/字派、在世状态、子女身份（嫡出/庶出/婢生/奸生/嗣子/养子）')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
            Text('时间信息：出生日期、逝世日期（支持公历/农历双标）、出生地（省-市-县-乡镇-村）、现居地')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text('亲属关系：父亲ID、母亲ID、配偶关系（正妻/平妻/贵妾/良妾/贱妾/外室，格式 UID:名分;UID:名分）、排行、过继/出嗣')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text('生平履历：学历/学位、职业/职务、生平简介、墓葬信息（含GPS经纬度海拔）')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text('联系方式：手机号、微信号（隐私字段）')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text('图像信息：头像（含相片、视频资料）')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
          }
          .width('100%')
          .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
          .backgroundColor(Theme.card)
          .borderRadius(16)
          .border({ width: 0.5, color: Theme.line })
          .margin({ bottom: Spacing.M })
          .clip(true)

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