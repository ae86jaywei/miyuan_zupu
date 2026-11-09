import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Genealogy } from '../model/Genealogy';
import { generationLabel } from '../model/Enums';
import { PaginationService, PrintBook, PagePlan } from './PaginationService';
import { GenealogyService } from './GenealogyService';
import { EuCanvas, EuBox, LineSeg, SuCanvas, SuBox } from './TreeLayout';
import { PersonNode } from '../model/PersonNode';

/** 成品纸张：横版 320×220mm，与分页画布完全一致 */
const PAGE_W_MM: number = 320;
const PAGE_H_MM: number = 220;
/** PDF 点：1mm = 72/25.4 pt */
const MM_TO_PT: number = 72 / 25.4;
const PAGE_W_PT: number = PAGE_W_MM * MM_TO_PT;
const PAGE_H_PT: number = PAGE_H_MM * MM_TO_PT;

/** 位图渲染：200dpi，2520×1732，印刷线条足够清晰，单页内存约 17MB，逐页释放 */
const RENDER_W: number = 2520;
const RENDER_H: number = 1732;
const PX_PER_MM: number = RENDER_W / PAGE_W_MM;

/** 页面几何（与 PrintLayout 保持一致） */
const GUTTER_MM: number = 20;
const INNER_X_MM: number = 26;
const INNER_Y_MM: number = 20;
const TRIM_W_MM: number = 320;
const TRIM_H_MM: number = 220;

const C_PAPER: string = '#FFFDF6';
const C_BIND: string = '#F4EFE3';
const C_INK: string = '#2E2A24';
const C_INK2: string = '#7A6A57';
const C_GOLD: string = '#C9A227';
const C_RED: string = '#B03A2E';
const C_FEMALE: string = '#A0527A';
const C_LINE: string = '#D8CBB2';

export interface PagedPdfProgress {
  current: number;
  total: number;
  message: string;
}

class RootBook {
  rootUid: string = '';
  rootName: string = '';
  book: PrintBook | null = null;
}

/**
 * 欧式 / 苏式分页画布导出 PDF。
 *
 * PDFKit 的 PdfPage 只有文字与图片对象，没有矢量线条/路径 API，所以每一页画布
 * 先用 OffscreenCanvas 2D 按 200dpi 完整画好（纸面、装订口、页眉、连线、卡片、页脚、页码），
 * 再编码为 JPEG 作为整页图插入 PDF。页数与分页画布完全一致，不会出现跨页悬空线。
 */
export class PagedPdfExportService {

  /** 把某一宗支的整本分页画布渲染成 PDF；多宗支依次追加到同一个 PDF */
  static async exportPdf(
    context: common.UIAbilityContext,
    genealogy: Genealogy,
    style: string,
    onProgress?: (p: PagedPdfProgress) => void
  ): Promise<string> {
    const svc: PaginationService = PaginationService.getInstance();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    if (roots.length === 0) {
      throw new Error('没有可导出的宗支');
    }

    // 先建册拿到总页数，页脚才能写「第N页/共N页」
    const version: number = Date.now();
    const books: RootBook[] = [];
    let total: number = 0;
    for (let i: number = 0; i < roots.length; i++) {
      const rb: RootBook = new RootBook();
      rb.rootUid = roots[i].uid;
      rb.rootName = roots[i].person.name.length > 0 ? roots[i].person.name : roots[i].uid;
      rb.book = svc.book(roots[i].uid, style, version, 'standard');
      total += rb.book.pages.length;
      books.push(rb);
    }
    if (total === 0) {
      throw new Error('分页结果为空');
    }

    const outDir: string = context.filesDir + '/pdf_export';
    if (!fileIo.accessSync(outDir)) {
      fileIo.mkdirSync(outDir);
    }
    const d: Date = new Date();
    const stamp: string = d.getFullYear().toString() +
      (d.getMonth() + 1).toString().padStart(2, '0') +
      d.getDate().toString().padStart(2, '0');
    const styleName: string = style === 'su' ? '苏式谱' : '欧式谱';
    const outPath: string = outDir + '/' + genealogy.title + '_' + styleName + '_' + stamp + '.pdf';

    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    if (!doc.createDocument(PAGE_W_PT, PAGE_H_PT)) {
      throw new Error('PDF 文档创建失败');
    }
    if (doc.getPageCount() === 1) {
      doc.deletePage(0, 1);
    }

    let pageNo: number = 0;
    try {
      for (let bi: number = 0; bi < books.length; bi++) {
        const rb: RootBook = books[bi];
        // 多宗支：重新取回该宗支的分页册，euPage/suPage 的缓存才指向当前册
        rb.book = svc.book(rb.rootUid, style, version, 'standard');
        const book: PrintBook = rb.book as PrintBook;
        for (let i: number = 1; i <= book.pages.length; i++) {
          const plan: PagePlan | null = book.page(i);
          if (plan === null) {
            continue;
          }
          pageNo++;
          const canvas: EuCanvas | SuCanvas | null = style === 'su' ? svc.suPage(i) : svc.euPage(i);
          if (canvas === null) {
            throw new Error('第 ' + i.toString() + ' 页布局为空');
          }
          const imgPath: string = await PagedPdfExportService.renderPage(context, rb.rootName, plan, canvas, pageNo, total, style);
          const page: pdfService.PdfPage = doc.insertBlankPage(doc.getPageCount(), PAGE_W_PT, PAGE_H_PT);
          page.addImageObject(imgPath, 0, 0, PAGE_W_PT, PAGE_H_PT);
          fileIo.unlinkSync(imgPath);
          if (onProgress) {
            onProgress({ current: pageNo, total: total, message: '渲染分页 ' + pageNo.toString() + '/' + total.toString() });
          }
          await PagedPdfExportService.yieldToUi();
        }
      }
      const saved: boolean = doc.saveDocument(outPath);
      if (!saved) {
        throw new Error('PDF 保存失败');
      }
    } finally {
      doc.releaseDocument();
    }
    return outPath;
  }

  /** 单页渲染成 JPEG，返回临时文件路径 */
  private static async renderPage(
    context: common.UIAbilityContext,
    rootName: string,
    plan: PagePlan,
    canvas: EuCanvas | SuCanvas,
    pageNo: number,
    total: number,
    style: string
  ): Promise<string> {
    const off: OffscreenCanvas = new OffscreenCanvas(RENDER_W, RENDER_H);
    const g: OffscreenCanvasRenderingContext2D = off.getContext('2d');
    // 纸面与装订口
    g.fillStyle = C_PAPER;
    g.fillRect(0, 0, RENDER_W, RENDER_H);
    g.fillStyle = C_BIND;
    g.fillRect(0, 0, GUTTER_MM * PX_PER_MM, RENDER_H);
    g.strokeStyle = C_LINE;
    g.lineWidth = 1;
    g.strokeRect(0.5, 0.5, RENDER_W - 1, RENDER_H - 1);

    // 页眉
    g.fillStyle = C_INK2;
    g.textAlign = 'left';
    g.textBaseline = 'top';
    g.font = Math.round(8 * 0.3527778 * PX_PER_MM).toString() + 'px sans-serif';
    const genText: string = (plan.genFrom > 0 && plan.genTo > 0)
      ? '第' + generationLabel(plan.genFrom) + (plan.genFrom === plan.genTo ? '' : '—' + generationLabel(plan.genTo))
      : '';
    const header: string = '世系图' + (genText.length > 0 ? ' · ' + genText : '') + (rootName.length > 0 ? ' · ' + rootName : '');
    g.fillText(header, INNER_X_MM * PX_PER_MM, 6 * PX_PER_MM);

    // 连线：红色婚约双线 / 金色世系线
    for (let i: number = 0; i < canvas.lines.length; i++) {
      const seg: LineSeg = canvas.lines[i];
      g.strokeStyle = seg.red ? C_RED : C_GOLD;
      g.lineWidth = Math.max(1, 0.25 * PX_PER_MM);
      g.beginPath();
      g.moveTo((INNER_X_MM + seg.x1) * PX_PER_MM, (INNER_Y_MM + seg.y1) * PX_PER_MM);
      g.lineTo((INNER_X_MM + seg.x2) * PX_PER_MM, (INNER_Y_MM + seg.y2) * PX_PER_MM);
      g.stroke();
    }

    // 卡片
    const boxes: Array<EuBox | SuBox> = style === 'su' ? (canvas as SuCanvas).boxes : (canvas as EuCanvas).boxes;
    for (let i: number = 0; i < boxes.length; i++) {
      const b: EuBox | SuBox = boxes[i];
      PagedPdfExportService.drawCard(g, b.node, b.x, b.y, b.w, b.h);
    }

    // 页脚接续文案
    g.fillStyle = '#8C2F1E';
    g.textAlign = 'left';
    g.textBaseline = 'top';
    g.font = Math.round(6.5 * 0.3527778 * PX_PER_MM).toString() + 'px sans-serif';
    if (plan.footerText.length > 0) {
      g.fillText(plan.footerText, INNER_X_MM * PX_PER_MM, (TRIM_H_MM - 8) * PX_PER_MM);
    }

    // 页码：居中，字号比接续文案大，印出来能看清
    g.fillStyle = C_INK2;
    g.textAlign = 'center';
    g.font = Math.round(8 * 0.3527778 * PX_PER_MM).toString() + 'px sans-serif';
    g.fillText('第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页',
      TRIM_W_MM * PX_PER_MM / 2, (TRIM_H_MM - 8) * PX_PER_MM);
    g.textAlign = 'left';

    const pm: image.PixelMap = g.getPixelMap(0, 0, RENDER_W, RENDER_H);
    const packer: image.ImagePacker = image.createImagePacker();
    const buf: ArrayBuffer = await packer.packing(pm, { format: 'image/jpeg', quality: 86 });
    const imgPath: string = context.cacheDir + '/paged_pdf_' + pageNo.toString() + '.jpg';
    const fd: fileIo.File = fileIo.openSync(imgPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(fd.fd, buf);
    fileIo.closeSync(fd);
    pm.release();
    return imgPath;
  }

  /** 一张人物卡：姓名 + 世次/UID，女卡用绛紫描边 */
  private static drawCard(g: OffscreenCanvasRenderingContext2D, node: PersonNode,
    x: number, y: number, w: number, h: number): void {
    const x0: number = (INNER_X_MM + x) * PX_PER_MM;
    const y0: number = (INNER_Y_MM + y) * PX_PER_MM;
    const w0: number = w * PX_PER_MM;
    const h0: number = h * PX_PER_MM;
    const female: boolean = node.person.gender === '女';
    g.fillStyle = female ? '#FBF1F5' : '#FFFFFF';
    g.fillRect(x0, y0, w0, h0);
    g.strokeStyle = female ? C_FEMALE : C_GOLD;
    g.lineWidth = Math.max(1, 0.2 * PX_PER_MM);
    g.strokeRect(x0 + 0.5, y0 + 0.5, w0 - 1, h0 - 1);

    const name: string = node.person.name.length > 0 ? node.person.name : node.uid;
    g.fillStyle = C_INK;
    g.textAlign = 'left';
    g.textBaseline = 'top';
    g.font = 'bold ' + Math.round(7 * 0.3527778 * PX_PER_MM).toString() + 'px sans-serif';
    g.fillText(name, x0 + 1 * PX_PER_MM, y0 + 1.1 * PX_PER_MM);

    let detail: string = generationLabel(node.person.generation);
    if (node.uid.length > 0) {
      detail += ' · ' + node.uid;
    }
    g.fillStyle = C_INK2;
    g.font = Math.round(5.5 * 0.3527778 * PX_PER_MM).toString() + 'px sans-serif';
    g.fillText(detail, x0 + 1 * PX_PER_MM, y0 + 5.2 * PX_PER_MM);
  }

  private static yieldToUi(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(() => {
        resolve();
      }, 8);
    });
  }
}
