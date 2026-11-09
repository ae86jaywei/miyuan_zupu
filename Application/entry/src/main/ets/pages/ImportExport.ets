import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from '../theme/Theme';
import { TS } from '../components/TS';
import { BackButton } from '../components/BackButton';
import { GenealogyService } from '../service/GenealogyService';
import { ExportService, JsonBundle } from '../service/ExportService';
import { PdfExportService, PdfExportProgress, PdfVolume } from '../service/PdfExportService';
import { PagedPdfExportService, PagedPdfProgress } from '../service/PagedPdfExportService';
import { GenealogyStore } from '../store/GenealogyStore';
import { GenealogyScope } from '../model/Scope';
import { Person } from '../model/Person';
import { Genealogy, createEmptyGenealogy } from '../model/Genealogy';
import { ImportPlan, ImportResult } from '../service/ImportPlanner';

/** 单卷人数上限：超过则按世系分卷，避免单文件近万页被系统判定无响应 */
const PDF_VOLUME_MAX: number = 3000;

/**
 * 单部族谱在内存中的安全人数上限。
 * 应用启动会把整谱读入内存并构建谱系树，实测 8 万人时堆已达到约 388MB
 * （本机 JS 堆上限约 474MB）并在重建谱系时 OutOfMemoryError；
 * 6 万以内可稳定运行，超过则阻止导入并提示改用覆盖/跳过或另立新谱。
 */
const MAX_PEOPLE_IN_MEMORY: number = 60000;


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
  /** PDF 谱式：die=牒记式（文字流），eu=欧式分页，su=苏式分页 */
  @State pdfStyle: string = 'die';
  @State mergeStrategy: string = 'auto';
  @State previewText: string = '';
  @State parsedCount: number = 0;
  /** 解析结果可能有数万人，不能放到 @State/@Prop 里（状态同步会深拷贝导致卡死） */
  private pendingPeople: Person[] = [];
  @State pendingBook: Genealogy | null = null;
  /** 进度条：0~100 与当前阶段文案（数万条导入要跨分钟，没有进度会被当成卡死） */
  @State progress: number = 0;
  @State progressText: string = '';
  @State showProgress: boolean = false;
  /** 页首「当前共 X 位族人」：导入完成后要立刻反映新人数，不能等页面重建 */
  @State peopleCount: number = 0;

  private svc(): GenealogyService {
    return GenealogyService.getInstance();
  }

  aboutToAppear(): void {
    this.peopleCount = this.svc().getPeople().length;
  }

  /** 更新进度条 */
  private setProgress(text: string, percent: number): void {
    this.progressText = text;
    this.progress = percent > 100 ? 100 : (percent < 0 ? 0 : percent);
    this.showProgress = true;
  }

  /** 让出主线程一帧，保证进度文案先渲染出来（后面紧跟同步大计算时用） */
  private yieldFrame(): Promise<void> {
    return new Promise<void>((resolve: (v: void) => void): void => {
      setTimeout((): void => {
        resolve();
      }, 40);
    });
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
      // 生成几十 MB 文本是同步计算，先让进度条画出来再开工
      this.setProgress('正在生成导出内容…', 10);
      await this.yieldFrame();
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
      this.setProgress('正在保存 ' + fileName + '…', 80);
      await ExportService.saveAsFile(GenealogyScope.context(), fileName, content);
      this.setProgress('已导出 ' + fileName, 100);
      this.getUIContext().getPromptAction().showToast({ message: '已导出 ' + fileName });
    } catch (e) {
      const err = e as BusinessError;
      this.setProgress('导出失败：' + err.message, 100);
      if (err.code !== 13900042) {
        this.getUIContext().getPromptAction().showToast({ message: '导出失败：' + err.message });
      }
    } finally {
      this.busy = false;
    }
  }

  private async doExportPdf(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.previewText = '正在渲染，请稍候……';
    this.setProgress('正在排版 PDF…', 2);
    try {
      const ctx = GenealogyScope.context();
      const people: Person[] = this.svc().getPeople();
      const book: Genealogy = this.svc().getBook();
      // 欧式/苏式：直接导出分页画布（320×220mm 横版，一页一张），页码与屏幕上完全一致
      if (this.pdfStyle === 'eu' || this.pdfStyle === 'su') {
        const path: string = await PagedPdfExportService.exportPdf(ctx, book, this.pdfStyle,
          (p: PagedPdfProgress): void => {
            this.previewText = p.message;
            this.setProgress(p.message, p.total > 0 ? Math.min(96, Math.round(p.current * 96 / p.total)) : 2);
          });
        const name: string = path.substring(path.lastIndexOf('/') + 1);
        const savedCount: number = await ExportService.saveBinariesAsFiles(ctx, [path], [name]);
        if (savedCount === 0) {
          this.setProgress('已取消保存', 100);
          return;
        }
        const msg: string = '已导出 ' + name;
        this.setProgress(msg, 100);
        this.getUIContext().getPromptAction().showToast({ message: msg });
        return;
      }
      // 牒记式：先算全谱每一卷的卷号/页码并回填，再逐卷生成 PDF
      const planned: PdfVolume[] = PdfExportService.planVolumes(people, PDF_VOLUME_MAX);
      const jobs: PdfVolume[] = planned.length > 0 ? planned : [{ title: '', people: people }];
      this.setProgress('正在计算各卷页码…', 3);
      const crossRef: Map<string, string> = PdfExportService.prepareCrossRefs(people, book, jobs, true);
      const paths: string[] = [];
      const names: string[] = [];
      for (let i: number = 0; i < jobs.length; i++) {
        const vol: PdfVolume = jobs[i];
        const base: number = Math.floor(i * 96 / jobs.length);
        const span: number = Math.floor(96 / jobs.length);
        const path: string = await PdfExportService.exportPdf(ctx, vol.people, book,
          {
            includeCover: true,
            volumeTitle: vol.title,
            kinSource: people,
            style: 'die',
            crossRef: crossRef
          },
          (p: PdfExportProgress): void => {
            this.previewText = p.message;
            const pct: number = p.total > 0 ? base + Math.round(p.current * span / p.total) : base;
            this.setProgress(p.message, pct);
          });
        paths.push(path);
        names.push(path.substring(path.lastIndexOf('/') + 1));
      }
      this.setProgress('正在保存 ' + names.length + ' 个文件…', 98);
      const saved: number = await ExportService.saveBinariesAsFiles(ctx, paths, names);
      if (saved === 0) {
        this.setProgress('已取消保存', 100);
        return;
      }
      const msg: string = jobs.length > 1 ? '已导出 ' + saved + ' 卷 PDF' : '已导出 ' + names[0];
      this.setProgress(msg, 100);
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (e) {
      const err = e as BusinessError;
      this.setProgress('导出失败：' + (err.message ?? String(e)), 100);
      this.getUIContext().getPromptAction().showToast({ message: '导出失败：' + (err.message ?? String(e)) });
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
      this.setProgress('正在选择文件…', 5);
      const text: string = await ExportService.pickFileText(GenealogyScope.context(),
        kind === 'json' ? ['.json'] : ['.csv', '.txt']);
      if (text.length === 0) {
        this.showProgress = false;
        return;
      }
      // 数十 MB 备份的 JSON.parse 是同步的，先让进度条画出来再解析
      this.setProgress('正在解析 ' + (kind === 'json' ? 'JSON' : 'CSV') + ' 文件…', 35);
      await this.yieldFrame();
      this.previewText = text.length > 1200 ? text.substring(0, 1200) + '\n……' : text;
      let list: Person[] = [];
      let book: Genealogy | null = null;
      if (kind === 'json') {
        // 大备份（数万人约 37MB）只解析一次，同时取出人物与族谱信息
        const bundle: JsonBundle = ExportService.parseJsonBundle(text);
        list = bundle.people;
        book = bundle.book;
      } else {
        list = ExportService.parseCsv(text);
      }
      this.pendingBook = book;
      this.pendingPeople = list;
      this.parsedCount = list.length;
      this.setProgress('解析完成，共 ' + list.length.toString() + ' 条记录', 100);
      const tip: string = this.pendingBook !== null ? '，含族谱信息「' + this.pendingBook.title + '」' : '';
      this.getUIContext().getPromptAction().showToast({
        message: '解析到 ' + list.length.toString() + ' 条记录' + tip + '，请确认导入'
      });
    } catch (e) {
      const err = e as BusinessError;
      this.setProgress('导入失败：' + err.message, 100);
      this.getUIContext().getPromptAction().showToast({ message: '导入失败：' + err.message });
    } finally {
      this.busy = false;
    }
  }

  private async confirmImport(): Promise<void> {
    if (this.pendingPeople.length === 0 || this.busy) {
      return;
    }
    // 身份匹配 + ID 重映射是同步计算，数万条时也会占用主线程一段时间。
    // 先让界面把进度画出来，并拦住重复点击。
    this.busy = true;
    this.setProgress('正在匹配族人身份（' + this.pendingPeople.length.toString() + ' 条）…', 20);
    await this.yieldFrame();
    // 先生成导入计划（身份匹配 + ID 重映射），让用户看到合并/新增/跳过的人数再执行
    const meta: Genealogy = this.pendingBook !== null ? this.pendingBook : createEmptyGenealogy();
    const curTitle: string = this.svc().hasBook() ? this.svc().getBook().title : '';
    // 文件自带谱名且与当前谱不同：属于另一部族谱，必须另立新谱，不能并进当前谱
    const isOtherBook: boolean = this.pendingBook !== null && meta.title.trim().length > 0
      && curTitle.length > 0 && meta.title.trim() !== curTitle.trim();
    const asNewBook: boolean = !this.svc().hasBook() || isOtherBook;
    const plan: ImportPlan = await this.svc().planImport(this.pendingPeople, this.mergeStrategy, asNewBook,
      (done: number, total: number): void => {
        this.setProgress('正在匹配族人身份（' + done.toString() + '/' + total.toString() + '）…',
          20 + Math.round(done * 40 / Math.max(total, 1)));
      });
    // 人数安全阀：合并进当前谱且总人数将超过内存上限时直接拦下，
    // 否则写入完成后重读全谱 + 重建谱系会 OutOfMemoryError（应用被杀，数据也白导）
    const curCount: number = this.svc().hasBook() ? this.svc().getPeople().length : 0;
    const projected: number = asNewBook ? plan.people.length : curCount + plan.newCount();
    if (projected > MAX_PEOPLE_IN_MEMORY) {
      this.busy = false;
      this.showProgress = false;
      const tip: string = '导入后本族谱将达到 ' + projected.toString() + ' 人，超出本机内存安全上限 '
        + MAX_PEOPLE_IN_MEMORY.toString() + ' 人（当前 ' + curCount.toString() + ' 人），'
        + '继续导入会因内存不足被系统强制退出。\n\n'
        + '建议：改用「覆盖」或「跳过重复」策略；如需保留两套编号，请先在「谱系」中新建族谱再导入。';
      this.setProgress(tip, 100);
      this.getUIContext().getPromptAction().showToast({ message: '人数超出内存安全上限，已取消导入' });
      return;
    }
    let text: string = '';
    if (isOtherBook) {
      text = '检测到文件属于另一部族谱「' + meta.title + '」，将新建独立族谱导入，'
        + '不会与当前「' + curTitle + '」合并。\n\n';
    } else if (asNewBook) {
      text = '当前没有族谱，将先按文件中的族谱信息新建「' + meta.title + '」再导入。\n\n';
    } else {
      text = '导入到当前族谱「' + curTitle + '」，文件中的族谱信息不会覆盖现有设置。\n\n';
    }
    text = text + plan.summary() + '\n\n导入过程整体在一个事务里，写入失败会自动回滚。';
    // 计划已算完，恢复可点击状态：弹窗的「开始导入」会走 executeImport
    this.busy = false;
    this.showProgress = false;
    this.getUIContext().showAlertDialog({
      title: '导入合并预览',
      message: text,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '开始导入',
        fontColor: Theme.primary,
        action: async (): Promise<void> => {
          await this.executeImport(plan);
        }
      }
    });
  }

  private async executeImport(plan: ImportPlan): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.setProgress('正在写入族谱…', 3);
    // 计划已生成，解析出来的数万条原始人物不再需要，先释放以降低写入与重读阶段的堆压力
    this.pendingPeople = [];
    try {
      // 数万条写入要跨分钟，进度条按已写入条数推进（3%~93%），重建谱系占 95%
      const onProgress: (done: number, total: number) => void = (done: number, total: number): void => {
        const denom: number = total > 0 ? total : 1;
        this.setProgress('正在写入 ' + done.toString() + ' / ' + total.toString() + ' 人…',
          3 + Math.round(done * 90 / denom));
      };
      const meta: Genealogy = this.pendingBook !== null ? this.pendingBook : createEmptyGenealogy();
      const curTitle: string = this.svc().hasBook() ? this.svc().getBook().title : '';
      const isOtherBook: boolean = this.pendingBook !== null && meta.title.trim().length > 0
        && curTitle.length > 0 && meta.title.trim() !== curTitle.trim();
      const result: ImportResult = (!this.svc().hasBook() || isOtherBook)
        ? await this.svc().importAsNewBook(meta, plan, onProgress)
        : await this.svc().applyImportPlan(plan, onProgress);
      this.setProgress('正在重建谱系…', 95);
      GenealogyStore.notifyChanged();
      this.pendingPeople = [];
      this.pendingBook = null;
      this.parsedCount = 0;
      this.peopleCount = this.svc().getPeople().length;
      this.setProgress('导入完成：' + result.summary(), 100);
      this.getUIContext().getPromptAction().showToast({ message: '导入完成：' + result.summary() });
    } catch (e) {
      const err = e as BusinessError;
      this.setProgress('导入失败，已回滚：' + err.message, 100);
      this.getUIContext().getPromptAction().showToast({ message: '导入失败，已回滚：' + err.message });
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

  /** PDF 谱式选择按钮 */
  @Builder
  PdfStyleChip(label: string, value: string, hint: string) {
    Column() {
      Text(label)
        .fontSize(12.5)
        .fontColor(this.pdfStyle === value ? '#FFFFFF' : Theme.ink)
        .fontWeight(FontWeight.Medium)
      Text(hint)
        .fontSize(9)
        .fontColor(this.pdfStyle === value ? '#FFF4DE' : Theme.inkTertiary)
        .margin({ top: 2 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8, left: 4, right: 4 })
    .margin({ right: 6 })
    .backgroundColor(this.pdfStyle === value ? Theme.primary : Theme.field)
    .borderRadius(8)
    .border({ width: 0.5, color: this.pdfStyle === value ? Theme.primary : Theme.line })
    .onClick((): void => {
      this.pdfStyle = value;
    })
  }

  /** 导入/导出进行中拦截返回键，避免页面被销毁导致流程中断 */
  onBackPress(): boolean {
    return this.busy;
  }

  /** 全屏进度弹窗：盖住页面并显示阶段文案，避免用户以为卡死或中途切走 */
  @Builder
  ProgressOverlay() {
    Column() {
      Column() {
        LoadingProgress().width(34).height(34).color(Theme.primary)
        Text(this.progressText)
          .fontSize(13)
          .fontColor(Theme.ink)
          .margin({ top: 12 })
          .maxLines(3)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .color(Theme.primary)
          .backgroundColor(Theme.field)
          .width('100%')
          .height(6)
          .margin({ top: 14 })
        Text(this.progress.toString() + '%')
          .fontSize(12)
          .fontColor(Theme.primary)
          .margin({ top: 6 })
        Text('请停在此页，完成前不要退出或切换')
          .fontSize(10.5)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 10 })
      }
      .width('78%')
      .padding({ left: 24, right: 24, top: 24, bottom: 20 })
      .backgroundColor(Theme.card)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Block)
    .onClick((): void => {
      // 吞掉点击，防止穿透到下层页面
    })
  }

  build() {
    // 用 Stack 在最上层盖一层遮罩：导入/导出进行中禁止点其它入口、禁止返回
    Stack() {
      Column() {
        Row() {
        BackButton({
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
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
          TS({ title: '导出', subtitle: '当前共 ' + this.peopleCount.toString() + ' 位族人', icon: '📤' })
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
            Divider().color(Theme.line).strokeWidth(0.5)
            Column() {
              Text('PDF 导出谱式')
                .fontSize(13)
                .fontColor(Theme.ink)
                .fontWeight(FontWeight.Medium)
                .width('100%')
              Row() {
                this.PdfStyleChip('牒记式', 'die', '文字流，分卷连续排版')
                this.PdfStyleChip('欧式谱', 'eu', '横版分页，世系连线')
                this.PdfStyleChip('苏式谱', 'su', '横版分页，房支竖排')
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            Divider().color(Theme.line).strokeWidth(0.5)
            this.ExportRow('PDF 整本族谱', '按所选谱式导出：牒记式分卷文字流，或欧式/苏式 320×220mm 横版分页', '打印',
              (): void => {
                this.doExportPdf();
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

            Text('人员匹配策略：')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: Spacing.M, bottom: 6 })
            Row() {
              ForEach([['auto', '智能匹配'], ['skip', '跳过'], ['replace', '覆盖'], ['newId', '另编号']],
                (item: string[]) => {
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
                if (this.pendingBook !== null) {
                  Text('族谱信息：' + this.pendingBook.title +
                    (this.pendingBook.hallName.length > 0 ? ' · ' + this.pendingBook.hallName : ''))
                    .fontSize(11)
                    .fontColor(Theme.inkSecondary)
                    .margin({ top: 4 })
                }
                if (!this.svc().hasBook()) {
                  Text('当前没有族谱，确认导入时会自动新建')
                    .fontSize(11)
                    .fontColor(Theme.gold)
                    .margin({ top: 4 })
                }
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

      if (this.busy && this.showProgress) {
        this.ProgressOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
