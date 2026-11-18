import { T, uiFontFamily } from 'common_base';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing, Radius } from 'common_base';
import { TS } from 'common_ui';
import { PageHeader } from 'common_ui';
import { GenealogyService, BranchSuggestion } from '../service/GenealogyService';
import { ExportService, JsonBundle } from '../service/ExportService';
import { PdfExportService, PdfExportProgress, PdfVolume } from '../service/PdfExportService';
import { PagedPdfExportService, PagedPdfProgress } from '../service/PagedPdfExportService';
import { PageSpec } from '../service/PrintLayout';
import { GenealogyStore } from '../store/GenealogyStore';
import { GenealogyScope } from 'common_base';
import { Person } from 'common_base';
import { Genealogy, createEmptyGenealogy } from 'common_base';
import { ImportPlan, ImportResult } from '../service/ImportPlanner';

/**
 * 单卷人数上限：超过则按世系分卷。
 * 由 3000 降到 1000 —— 原值单卷约 600~900 页、3~4 万个文本对象，PDFKit 在 native 层
 * 累积过多对象 + saveDocument 一次性序列化整份 PDF 时内存峰值过高，大数据导出会 OOM 崩溃
 * （进程级 native 崩溃，HiLog 里看不到错误）。减小单卷可显著降低单份 PDF 的内存峰值。
 */
const PDF_VOLUME_MAX: number = 1000;

/**
 * 单部族谱在内存中的安全人数上限。
 * 应用启动会把整谱读入内存并构建谱系树，实测 8 万人时堆已达到约 388MB
 * （本机 JS 堆上限约 474MB）并在重建谱系时 OutOfMemoryError；
 * 6 万以内可稳定运行，超过则阻止导入并提示改用覆盖/跳过或另立新谱。
 */
const MAX_PEOPLE_IN_MEMORY: number = 60000;

/**
 * 整谱（总谱）单次导出人数上限。
 * 0 = 不限制：用于验证 5 万人以上整谱一次性导出；恢复限制时改回 5000。
 * 分支谱不受此限制。
 */
const PDF_PEOPLE_LIMIT: number = 0;

/**
 * 牒记式单卷人数：自写 PDF 逐页写，卷大小不再受内存限制，
 * 卷越大每卷的固定开销（字体、谱序、关系索引）均摊得越少。
 * 2 万人以上按 1500 人/卷（6 万人 → 40 卷）。
 */
function volumeMaxFor(total: number): number {
  if (total > 20000) {
    return 1500;
  }
  return PDF_VOLUME_MAX;
}


/**
 * 导入 / 导出中心。
 */
@Entry
@Component
struct ImportExport {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @StorageProp('windowWidth') windowWidth: number = 360;
  @State busy: boolean = false;
  @StorageProp('darkMode') @Watch('onDarkModeChange') darkMode: boolean = false;

  onDarkModeChange(): void {
    Theme.use(this.darkMode);
  }
  @State includePrivate: boolean = true;
  /** PDF 谱式：die=牒记式（文字流），eu=欧式分页，su=苏式分页 */
  @State pdfStyle: string = 'die';
  /** 牒记版式：modern=现代横排，classic=仿古竖排（右起左行） */
  @State pdfLayout: string = 'modern';
  /** 装订方式：true=双面（按所选装订边镜像），false=单面（每页统一装订边） */
  @StorageLink('printDuplex') printDuplex: boolean = true;
  /** 装订方向：left=左侧装订，right=右侧装订（传统右翻） */
  @StorageLink('printBinding') printBinding: string = 'right';
  /** 导出范围：可选择总谱或某个分支谱，避免 5 万人整谱一次性导出 */
  @State exportBookId: number = 0;
  @State exportBookIds: number[] = [];
  @State exportBookTitles: string[] = [];
  /** 分支建议：第 5 世、后代 ≥2000 的房支，提示用户先拆分再导出 */
  @State branchSuggestions: BranchSuggestion[] = [];
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

  /** 从建议列表建立分支谱（移动式：原谱保留始祖占位，后代迁入分支谱） */
  private confirmCreateBranch(uid: string): void {
    this.getUIContext().showAlertDialog({
      title: T('建立分支谱'),
      message: T('将把该房支以下的族人移动到新分支谱，原谱保留该始祖作为分支占位。')
        + '建支后当前谱会切换到分支谱，确定继续？',
      primaryButton: {
        value: T('取消'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: T('建分支'),
        fontColor: Theme.primary,
        action: async (): Promise<void> => {
          if (this.busy) {
            return;
          }
          this.busy = true;
          this.setProgress('正在建立分支…', 1);
          try {
            const b: Genealogy = await this.svc().createBranchFromPerson(uid,
              (done: number, total: number): void => {
                this.setProgress('正在迁移分支数据 ' + done.toString() + '/' + total.toString() + '…',
                  Math.min(99, Math.round(done * 100 / Math.max(total, 1))));
              });
            this.peopleCount = this.svc().getPeople().length;
            const books: Genealogy[] = this.svc().getBooks();
            const ids: number[] = [];
            const titles: string[] = [];
            for (let i: number = 0; i < books.length; i = i + 1) {
              ids.push(books[i].key);
              titles.push(books[i].title + (books[i].parentBookId > 0 ? '（分支）' : ''));
            }
            this.exportBookIds = ids;
            this.exportBookTitles = titles;
            this.exportBookId = b.key;
            this.branchSuggestions = this.svc().suggestBranches();
            this.getUIContext().getPromptAction().showToast({ message: T('已建立分支：') + b.title });
          } catch (e) {
            const err = e as BusinessError;
            this.getUIContext().getPromptAction().showToast({ message: T('建分支失败：') + (err.message ?? String(e)) });
          } finally {
            this.busy = false;
            this.showProgress = false;
          }
        }
      }
    });
  }

  aboutToAppear(): void {
    // 导出与分页预览共用装订设置：进入页面先把当前选择同步到页面规格
    PageSpec.defaultBinding = this.printBinding;
    PageSpec.defaultDuplex = this.printDuplex;
    this.peopleCount = this.svc().getPeople().length;
    const books: Genealogy[] = this.svc().getBooks();
    const ids: number[] = [];
    const titles: string[] = [];
    for (let i: number = 0; i < books.length; i = i + 1) {
      ids.push(books[i].key);
      titles.push(books[i].title + (books[i].parentBookId > 0 ? '（分支）' : ''));
    }
    this.exportBookIds = ids;
    this.exportBookTitles = titles;
    this.exportBookId = this.svc().getBook().key;
    this.branchSuggestions = this.svc().suggestBranches();
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
      this.getUIContext().getPromptAction().showToast({ message: T('已导出 ') + fileName });
    } catch (e) {
      const err = e as BusinessError;
      this.setProgress('导出失败：' + err.message, 100);
      if (err.code !== 13900042) {
        this.getUIContext().getPromptAction().showToast({ message: T('导出失败：') + err.message });
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
    // 导出与屏幕分页共用装订几何：装订方向与单双面以当前设置快照为准
    PageSpec.defaultBinding = this.printBinding;
    PageSpec.defaultDuplex = this.printDuplex;
    // 导出范围：需要时临时切到分支谱，导出结束再切回，避免把 5 万人总谱整本导出
    const originalBookId: number = this.svc().getBook().key;
    const targetBookId: number = this.exportBookId > 0 ? this.exportBookId : originalBookId;
    let switched: boolean = false;
    /** 已完成的卷文件：中途失败也能把已导出的部分交给用户，避免几小时白跑 */
    const donePaths: string[] = [];
    const doneNames: string[] = [];
    try {
      if (targetBookId !== originalBookId) {
        await this.svc().switchGenealogy(targetBookId);
        switched = true;
      }
      const ctx = GenealogyScope.context();
      const people: Person[] = this.svc().getPeople();
      const book: Genealogy = this.svc().getBook();
      // 整谱人数限制（PDF_PEOPLE_LIMIT=0 时暂不限制，仅用于大谱验证）
      if (PDF_PEOPLE_LIMIT > 0 && book.parentBookId <= 0 && people.length > PDF_PEOPLE_LIMIT) {
        throw new Error('整谱 ' + people.length.toString() +
          ' 人，移动端无法一次导出。请先在「建议拆分」中建立分支，再选择分支导出。');
      }
      // 欧式/苏式：方案 F，自写 PDF（300dpi 整页 JPEG 直嵌，逐页写，绕开 PDFKit 内存峰值）
      if (this.pdfStyle === 'eu' || this.pdfStyle === 'su') {
        const paths: string[] = await PagedPdfExportService.exportRawPdf(ctx, book, this.pdfStyle,
          (p: PagedPdfProgress): void => {
            this.previewText = p.message;
            this.setProgress(p.message, p.total > 0 ? Math.min(96, Math.round(p.current * 96 / p.total)) : 2);
          });
        if (paths.length === 0) {
          this.setProgress('未生成 PDF', 100);
          return;
        }
        const names: string[] = [];
        for (let pi: number = 0; pi < paths.length; pi++) {
          names.push(paths[pi].substring(paths[pi].lastIndexOf('/') + 1));
        }
        const savedCount: number = await ExportService.saveBinariesAsFiles(ctx, paths, names);
        if (savedCount === 0) {
          this.setProgress('已取消保存', 100);
          return;
        }
        const msg: string = paths.length > 1
          ? ('已导出 ' + paths.length.toString() + ' 卷 PDF')
          : ('已导出 ' + names[0]);
        this.setProgress(msg, 100);
        this.getUIContext().getPromptAction().showToast({ message: T(msg) });
        return;
      }
      // 牒记式：方案 F 自写 PDF（矢量文本页 + 嵌入字体），逐卷生成
      const planned: PdfVolume[] = PdfExportService.planVolumes(people, volumeMaxFor(people.length));
      const jobs: PdfVolume[] = planned.length > 0 ? planned : [{ title: '', people: people }];
      // 卷数一多，「逐卷预排一遍全谱页码」会多出几十次全量排版，既慢又抬内存峰值：
      // 超过 30 卷时跳过预排，关系人统一标注「另卷」
      let crossRef: Map<string, string> | null = null;
      if (jobs.length <= 30) {
        this.setProgress('正在计算各卷页码…', 3);
        crossRef = await PdfExportService.prepareCrossRefs(people, book, jobs, true,
          this.pdfLayout === 'classic');
      }
      for (let i: number = 0; i < jobs.length; i++) {
        const vol: PdfVolume = jobs[i];
        const base: number = Math.floor(i * 96 / jobs.length);
        const span: number = Math.floor(96 / jobs.length);
        const path: string = await PdfExportService.exportRawTextPdf(ctx, vol.people, book,
          {
            includeCover: true,
            volumeTitle: vol.title,
            kinSource: people,
            style: 'die',
            classicLayout: this.pdfLayout === 'classic',
            crossRef: crossRef === null ? undefined : crossRef
          },
          (p: PdfExportProgress): void => {
            this.previewText = p.message;
            const pct: number = p.total > 0 ? base + Math.round(p.current * span / p.total) : base;
            this.setProgress(p.message, pct);
          });
        donePaths.push(path);
        doneNames.push(path.substring(path.lastIndexOf('/') + 1));
        console.info('[PdfExport] volume ' + (i + 1).toString() + '/' + jobs.length.toString() + ' done');
      }
      this.setProgress('正在保存 ' + doneNames.length + ' 个文件…', 98);
      const saved: number = await ExportService.saveBinariesAsFiles(ctx, donePaths, doneNames);
      if (saved === 0) {
        this.setProgress('已取消保存', 100);
        return;
      }
      const msg: string = jobs.length > 1 ? '已导出 ' + saved + ' 卷 PDF' : '已导出 ' + doneNames[0];
      this.setProgress(msg, 100);
      this.getUIContext().getPromptAction().showToast({ message: T(msg) });
    } catch (e) {
      const err = e as BusinessError;
      const reason: string = err.message ?? String(e);
      // 已完成的卷先交付：几万人牒记要跑很久，中途出错不该全部作废
      if (donePaths.length > 0) {
        try {
          const savedPart: number = await ExportService.saveBinariesAsFiles(GenealogyScope.context(),
            donePaths, doneNames);
          if (savedPart > 0) {
            this.setProgress('导出中断（' + reason + '）：已完成 ' + savedPart.toString() + ' 卷，已保存', 100);
            this.getUIContext().getPromptAction().showToast({
              message: T('已完成 ') + savedPart.toString() + ' 卷并保存，剩余卷可重试'
            });
            return;
          }
        } catch (_e2) {
        }
      }
      this.setProgress('导出失败：' + reason, 100);
      this.getUIContext().getPromptAction().showToast({ message: T('导出失败：') + reason });
    } finally {
      if (switched) {
        try {
          await this.svc().switchGenealogy(originalBookId);
        } catch (_e) {
        }
      }
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
        message: T('解析到 ') + list.length.toString() + ' 条记录' + tip + '，请确认导入'
      });
    } catch (e) {
      const err = e as BusinessError;
      this.setProgress('导入失败：' + err.message, 100);
      this.getUIContext().getPromptAction().showToast({ message: T('导入失败：') + err.message });
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
      this.getUIContext().getPromptAction().showToast({ message: T('人数超出内存安全上限，已取消导入') });
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
      title: T('导入合并预览'),
      message: T(text),
      primaryButton: {
        value: T('取消'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: T('开始导入'),
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
      this.getUIContext().getPromptAction().showToast({ message: T('导入完成：') + result.summary() });
    } catch (e) {
      const err = e as BusinessError;
      this.setProgress('导入失败，已回滚：' + err.message, 100);
      this.getUIContext().getPromptAction().showToast({ message: T('导入失败，已回滚：') + err.message });
    } finally {
      this.busy = false;
    }
  }

  @Builder
  ExportRow(title: string, desc: string, tag: string, action: () => void) {
    Row() {
      Column() {
        Row() {
          Text(T(title)).fontFamily(uiFontFamily()).fontSize(14).fontColor(Theme.ink)
          Text(T(tag)).fontFamily(uiFontFamily())
            .fontSize(10)
            .fontColor(Theme.gold)
            .backgroundColor(Theme.highlightBg)
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 6 })
        }
        Text(T(desc)).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(T('导出 ›')).fontFamily(uiFontFamily())
        .fontSize(12.5)
        .fontColor(Theme.primary)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick((): void => {
      action();
    })
  }

  /** 牒记版式选择按钮：现代版 / 仿古版 */
  @Builder
  LayoutChip(label: string, value: string, hint: string) {
    Column() {
      Text(T(label)).fontFamily(uiFontFamily())
        .fontSize(12.5)
        .fontColor(this.pdfLayout === value ? Theme.onPrimary : Theme.ink)
        .fontWeight(FontWeight.Medium)
      Text(T(hint)).fontFamily(uiFontFamily())
        .fontSize(9)
        .fontColor(this.pdfLayout === value ? Theme.onPrimarySubtle : Theme.inkTertiary)
        .margin({ top: 2 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8, left: 4, right: 4 })
    .margin({ right: 6 })
    .backgroundColor(this.pdfLayout === value ? Theme.primary : Theme.field)
    .borderRadius(8)
    .border({ width: 0.5, color: this.pdfLayout === value ? Theme.primary : Theme.line })
    .onClick((): void => {
      this.pdfLayout = value;
    })
  }

  /** PDF 谱式选择按钮 */
  @Builder
  PdfStyleChip(label: string, value: string, hint: string) {
    Column() {
      Text(T(label)).fontFamily(uiFontFamily())
        .fontSize(12.5)
        .fontColor(this.pdfStyle === value ? Theme.onPrimary : Theme.ink)
        .fontWeight(FontWeight.Medium)
      Text(T(hint)).fontFamily(uiFontFamily())
        .fontSize(9)
        .fontColor(this.pdfStyle === value ? Theme.onPrimarySubtle : Theme.inkTertiary)
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

  /** 装订方式选择按钮：双面（奇右偶左）/ 单面（统一右侧） */
  @Builder
  BindChip(label: string, duplex: boolean, hint: string) {
    Column() {
      Text(T(label)).fontFamily(uiFontFamily())
        .fontSize(12.5)
        .fontColor(this.printDuplex === duplex ? Theme.onPrimary : Theme.ink)
        .fontWeight(FontWeight.Medium)
      Text(T(hint)).fontFamily(uiFontFamily())
        .fontSize(9)
        .fontColor(this.printDuplex === duplex ? Theme.onPrimarySubtle : Theme.inkTertiary)
        .margin({ top: 2 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8, left: 4, right: 4 })
    .margin({ right: 6 })
    .backgroundColor(this.printDuplex === duplex ? Theme.primary : Theme.field)
    .borderRadius(8)
    .border({ width: 0.5, color: this.printDuplex === duplex ? Theme.primary : Theme.line })
    .onClick((): void => {
      this.printDuplex = duplex;
      PageSpec.defaultDuplex = duplex;
    })
  }

  /** 装订方向选择按钮：左侧装订 / 右侧装订（传统右翻） */
  @Builder
  BindSideChip(label: string, value: string, hint: string) {
    Column() {
      Text(T(label)).fontFamily(uiFontFamily())
        .fontSize(12.5)
        .fontColor(this.printBinding === value ? Theme.onPrimary : Theme.ink)
        .fontWeight(FontWeight.Medium)
      Text(T(hint)).fontFamily(uiFontFamily())
        .fontSize(9)
        .fontColor(this.printBinding === value ? Theme.onPrimarySubtle : Theme.inkTertiary)
        .margin({ top: 2 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8, left: 4, right: 4 })
    .margin({ right: 6 })
    .backgroundColor(this.printBinding === value ? Theme.primary : Theme.field)
    .borderRadius(8)
    .border({ width: 0.5, color: this.printBinding === value ? Theme.primary : Theme.line })
    .onClick((): void => {
      this.printBinding = value;
      PageSpec.defaultBinding = value;
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
        Text(T(this.progressText)).fontFamily(uiFontFamily())
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
        Text(T(this.progress.toString() + '%')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.primary)
          .margin({ top: 6 })
        Text(T('请停在此页，完成前不要退出或切换')).fontFamily(uiFontFamily())
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
    .backgroundColor(Theme.scrim)
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
        PageHeader({
          title: '导入 / 导出',
          loading: this.busy,
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
        })

      Scroll() {
        Column() {
          TS({ title: T('导出'), subtitle: '当前共 ' + this.peopleCount.toString() + ' 位族人', icon: '📤' })
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
            this.ExportRow('CSV 表格', '可用 Excel 打开', 'Excel',
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
              if (this.branchSuggestions.length > 0) {
                Text(T('建议拆分（当前谱 ' + this.peopleCount.toString() + ' 人，整谱无法一次导出）')).fontFamily(uiFontFamily())
                  .fontSize(13)
                  .fontColor(Theme.ink)
                  .fontWeight(FontWeight.Medium)
                  .width('100%')
                Column() {
                  ForEach(this.branchSuggestions, (s: BranchSuggestion) => {
                    Row() {
                      Text(T('第' + s.generation.toString() + '世 ' + s.name + ' · ' +
                        s.descendants.toString() + '人')).fontFamily(uiFontFamily())
                        .fontSize(11)
                        .fontColor(Theme.inkSecondary)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(T('建分支')).fontFamily(uiFontFamily())
                        .fontSize(11)
                        .fontColor(Theme.onPrimary)
                        .backgroundColor(Theme.primary)
                        .borderRadius(6)
                        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                        .onClick((): void => {
                          this.confirmCreateBranch(s.uid);
                        })
                    }
                    .width('100%')
                    .padding({ top: 4, bottom: 4 })
                  }, (s: BranchSuggestion) => 'branch_sug_' + s.uid)
                }
                .width('100%')
                .margin({ top: 8, bottom: 6 })
              }
              if (this.exportBookIds.length > 1) {
                Text(T('导出范围')).fontFamily(uiFontFamily())
                  .fontSize(13)
                  .fontColor(Theme.ink)
                  .fontWeight(FontWeight.Medium)
                  .width('100%')
                Scroll() {
                  Row() {
                    ForEach(this.exportBookIds, (id: number, i: number) => {
                      Text(T(this.exportBookTitles.length > i ? this.exportBookTitles[i] : id.toString())).fontFamily(uiFontFamily())
                        .fontSize(11)
                        .fontColor(this.exportBookId === id ? Theme.onPrimary : Theme.ink)
                        .backgroundColor(this.exportBookId === id ? Theme.primary : Theme.field)
                        .borderRadius(6)
                        .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                        .margin({ right: 6 })
                        .maxLines(1)
                        .onClick((): void => {
                          this.exportBookId = id;
                        })
                    }, (id: number) => 'expbook_' + id.toString())
                  }
                }
                .width('100%')
                .scrollable(ScrollDirection.Horizontal)
                .margin({ top: 8, bottom: 10 })
              }
              Text(T('PDF 导出谱式')).fontFamily(uiFontFamily())
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
              if (this.pdfStyle === 'die') {
                Text(T('牒记版式')).fontFamily(uiFontFamily())
                  .fontSize(13)
                  .fontColor(Theme.ink)
                  .fontWeight(FontWeight.Medium)
                  .width('100%')
                  .margin({ top: 12 })
                Row() {
                  this.LayoutChip('现代版', 'modern', '横排，现代阅读习惯')
                  this.LayoutChip('仿古版', 'classic', '竖排，右起左行')
                }
                .width('100%')
                .margin({ top: 8 })
              }
              Text(T('装订边')).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .fontWeight(FontWeight.Medium)
                .width('100%')
                .margin({ top: 12 })
              Row() {
                this.BindSideChip('左侧装订', 'left', '装订线在左')
                this.BindSideChip('右侧装订', 'right', '装订线在右')
              }
              .width('100%')
              .margin({ top: 8 })
              Text(T('装订方式')).fontFamily(uiFontFamily())
                .fontSize(13)
                .fontColor(Theme.ink)
                .fontWeight(FontWeight.Medium)
                .width('100%')
                .margin({ top: 12 })
              Row() {
                this.BindChip('双面印刷', true, '奇偶页自动镜像装订线')
                this.BindChip('单面', false, '每张纸统一装订边')
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            Divider().color(Theme.line).strokeWidth(0.5)
            this.ExportRow('PDF 整本族谱', '按所选谱式导出：牒记式 A4 分卷文字流，或欧式/苏式 320×220mm 横版分页（文字可选中，300dpi；支持左右装订线与单面/双面装订）', '打印',
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

          TS({ title: T('导入'), subtitle: '支持本应用导出的 JSON/CSV，或 Excel 另存的 CSV', icon: '📥' })
          Column() {
            Row() {
              Button(T('选择 JSON 文件')).fontFamily(uiFontFamily())
                .fontSize(13)
                .height(36)
                .backgroundColor(Theme.primary)
                .onClick((): void => {
                  this.doImport('json');
                })
              Button(T('选择 CSV 文件')).fontFamily(uiFontFamily())
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

            Text(T('人员匹配策略：')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: Spacing.M, bottom: 6 })
            Row() {
              ForEach([['auto', '智能匹配'], ['skip', '跳过'], ['replace', '覆盖'], ['newId', '另编号']],
                (item: string[]) => {
                Text(T(item[1])).fontFamily(uiFontFamily())
                  .fontSize(12)
                  .fontColor(this.mergeStrategy === item[0] ? Theme.onPrimary : Theme.inkSecondary)
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
                Text(T('已解析 ' + this.parsedCount.toString() + ' 条记录')).fontFamily(uiFontFamily())
                  .fontSize(13)
                  .fontColor(Theme.alive)
                if (this.pendingBook !== null) {
                  Text(T('族谱信息：' + this.pendingBook.title +
                    (this.pendingBook.hallName.length > 0 ? ' · ' + this.pendingBook.hallName : ''))).fontFamily(uiFontFamily())
                    .fontSize(11)
                    .fontColor(Theme.inkSecondary)
                    .margin({ top: 4 })
                }
                if (!this.svc().hasBook()) {
                  Text(T('当前没有族谱，确认导入时会自动新建')).fontFamily(uiFontFamily())
                    .fontSize(11)
                    .fontColor(Theme.gold)
                    .margin({ top: 4 })
                }
                if (this.pendingPeople.length > 0) {
                  Text(T('示例：' + this.pendingPeople[0].name + '（' + this.pendingPeople[0].uid + '）')).fontFamily(uiFontFamily())
                    .fontSize(11)
                    .fontColor(Theme.inkTertiary)
                    .margin({ top: 4 })
                }
                Button(T('确认导入')).fontFamily(uiFontFamily())
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
            TS({ title: T('内容预览'), icon: '👁' })
            Column() {
              Text(T(this.previewText)).fontFamily(uiFontFamily())
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

          TS({ title: T('字段规范'), subtitle: '与族人编辑表单一一对应', icon: '📋' })
          Column() {
            Text(T('身份标识：世代、唯一ID、谱名、字、号、曾用名/小名、性别、辈分/字派、在世状态（在世/已故/失联/不详）、身份（未记/嫡出/庶出/婢生/奸生/嗣子/养子/随母；妻妾可记元配/继室/侧室/偏房等名分）')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
            Text(T('时间信息：出生日期、逝世日期（支持公历/农历双标）、出生地（省-市-县-乡镇-村）、现居地')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text(T('亲属关系：父亲ID/父名（未收录）、母亲ID/母名（未收录）、配偶关系（元配/继室/侧室/偏房等名分，格式 UID:名分;UID:名分）、排行、过继/出嗣')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text(T('生平履历：学历/学位、职业/职务、生平简介、墓葬信息（含GPS经纬度海拔）')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text(T('联系方式：手机号、微信号（隐私字段）')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: 4 })
            Text(T('图像信息：头像、照片视频（相片、视频资料）')).fontFamily(uiFontFamily())
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
