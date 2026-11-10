import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Font, LengthMetricsUnit } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { Genealogy } from '../model/Genealogy';
import { generationLabel } from '../model/Enums';
import { PaginationService, PrintBook, PagePlan } from './PaginationService';
import { GenealogyService } from './GenealogyService';
import { EuCanvas, EuBox, LineSeg, SuCanvas, SuBox } from './TreeLayout';
import { PersonNode } from '../model/PersonNode';
import { compactUid } from '../util/StringUtil';
import { paintRasterTile, C_FOOT, C_GOLD, C_INK, C_INK2, INNER_X_MM, INNER_Y_MM,
  PAGE_H_MM, PAGE_W_MM, RENDER_H, RENDER_W, TILE_COLS, TILE_H, TILE_ROWS, TILE_W } from './PdfRasterJob';
import { renderTileJob } from './PdfTileTask';

/** PDF 点：1mm = 72/25.4 pt */
const MM_TO_PT: number = 72 / 25.4;
const PAGE_W_PT: number = PAGE_W_MM * MM_TO_PT;
const PAGE_H_PT: number = PAGE_H_MM * MM_TO_PT;

const TRIM_W_MM: number = 320;
const TRIM_H_MM: number = 220;

/** 矢量文字字号（pt）：页眉/页码与卡片姓名、详情 */
const HEADER_PT: number = 8;
const FOOTER_PT: number = 6.5;
const PAGE_NO_PT: number = 8;
/** 标准卡（卡高 ≥10mm）上姓名 7→8pt、详情 5.5→6.5pt，矢量文字印出来更清楚 */
const CARD_NAME_PT: number = 8;
const CARD_DETAIL_PT: number = 6.5;
/** 文本宽度测量倍率：pt → px，避免小数精度损失 */
const MEASURE_SCALE: number = 4;
const MEASURE_W: number = 1024;
const MEASURE_H: number = 256;

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

/** 一块栅格图：记录它在整页像素坐标系中的位置，供 PDF 按 pt 精确落位 */
class TileImage {
  path: string = '';
  xPx: number = 0;
  yPx: number = 0;
  wPx: number = 0;
  hPx: number = 0;
}

/** 卡片矢量字号：取自印刷档位，标准卡可适当放大 */
class CardFonts {
  namePt: number = 7;
  detailPt: number = 5.5;
}

/** #RRGGBB → PDF 颜色数值 */
function hexToNum(hex: string): number {
  return parseInt(hex.replace('#', ''), 16);
}

/** 系统字体信息（进程内缓存，避免逐页取字体路径） */
let cachedFontInfo: pdfService.FontInfo | null = null;

function pdfFontInfo(): pdfService.FontInfo {
  if (cachedFontInfo === null) {
    const fi: pdfService.FontInfo = new pdfService.FontInfo();
    const names: string[] = ['HarmonyOS Sans SC', 'HarmonyOS Sans', 'HarmonyOS_Sans_SC'];
    for (let i: number = 0; i < names.length; i++) {
      try {
        const f: Font = new Font();
        const info = f.getFontByName(names[i]);
        if (info.path.length > 0) {
          fi.fontPath = info.path;
          fi.fontName = names[i];
          break;
        }
      } catch (_e) {
        // 换下一个家族名再试，全部失败时交给 PDF 默认字体
      }
    }
    cachedFontInfo = fi;
  }
  return cachedFontInfo;
}

/** 统一的 PDF 文本样式 */
function pdfTextStyle(size: number, color: string, bold: boolean): pdfService.TextStyle {
  return {
    textSize: size,
    textColor: hexToNum(color),
    isBold: bold,
    fontInfo: pdfFontInfo()
  };
}

/**
 * 「距页面顶部毫米数」换算成 PDF 文本基线。
 * PDF 坐标原点在页面左下角、y 向上，与自上而下的排版坐标相反。
 */
function baselineOfMm(topMm: number, sizePt: number): number {
  return PAGE_H_PT - topMm * MM_TO_PT - sizePt;
}

/** 用离屏 ctx 量出文本宽度（pt） */
function measurePt(ctx: OffscreenCanvasRenderingContext2D, text: string, sizePt: number): number {
  ctx.save();
  ctx.font = (sizePt * MEASURE_SCALE).toString() + 'px sans-serif';
  const w: number = ctx.measureText(text).width / MEASURE_SCALE;
  ctx.restore();
  return w;
}

/** 按最大宽度截断文本，超出部分用省略号，避免卡片文字压出边框 */
function fitText(ctx: OffscreenCanvasRenderingContext2D, text: string, maxW: number, sizePt: number): string {
  if (text.length === 0 || measurePt(ctx, text, sizePt) <= maxW) {
    return text;
  }
  let cut: string = text;
  while (cut.length > 0 && measurePt(ctx, cut + '…', sizePt) > maxW) {
    cut = cut.substring(0, cut.length - 1);
  }
  return cut.length > 0 ? cut + '…' : '';
}

/** 卡片文字安全系数：PDF 内嵌字体比 canvas 的 sans-serif 略宽，按 1.18 预留 */
const CARD_TEXT_SAFETY: number = 1.18;

function cardTextWidth(ctx: OffscreenCanvasRenderingContext2D, text: string, sizePt: number): number {
  return measurePt(ctx, text, sizePt) * CARD_TEXT_SAFETY;
}

/** 先整体缩小字号塞进卡片，缩到下限仍放不下再由调用方截断 */
function fitCardSize(ctx: OffscreenCanvasRenderingContext2D, text: string, maxW: number,
  sizePt: number, minPt: number): number {
  const w: number = cardTextWidth(ctx, text, sizePt);
  if (w <= maxW) {
    return sizePt;
  }
  return Math.max(minPt, sizePt * maxW / w);
}

function fitCardText(ctx: OffscreenCanvasRenderingContext2D, text: string, maxW: number,
  sizePt: number): string {
  if (text.length === 0 || cardTextWidth(ctx, text, sizePt) <= maxW) {
    return text;
  }
  let cut: string = text;
  while (cut.length > 0 && cardTextWidth(ctx, cut + '…', sizePt) > maxW) {
    cut = cut.substring(0, cut.length - 1);
  }
  return cut.length > 0 ? cut + '…' : '';
}

/** 按卡高决定矢量字号：标准/大字档放大一档，紧凑档保持原字号避免压框 */
function cardFontsOf(book: PrintBook): CardFonts {
  const out: CardFonts = new CardFonts();
  const p = book.profile;
  if (p.cardH >= 10) {
    out.namePt = Math.max(p.nameFontPt, CARD_NAME_PT);
    out.detailPt = Math.max(p.detailFontPt, CARD_DETAIL_PT);
  } else {
    out.namePt = p.nameFontPt;
    out.detailPt = p.detailFontPt;
  }
  return out;
}

/** 把连线压平成可跨线程传输的数字数组：[x1,y1,x2,y2,是否婚约线] × n */
function packLineData(canvas: EuCanvas | SuCanvas): number[] {
  const out: number[] = [];
  for (let i: number = 0; i < canvas.lines.length; i++) {
    const s: LineSeg = canvas.lines[i];
    out.push(s.x1, s.y1, s.x2, s.y2, s.red ? 1 : 0);
  }
  return out;
}

/** 把卡片压平：[x,y,w,h,是否女卡] × n，避免把 PersonNode 传进 TaskPool */
function packBoxData(canvas: EuCanvas | SuCanvas, style: string): number[] {
  const boxes: Array<EuBox | SuBox> = style === 'su' ? (canvas as SuCanvas).boxes : (canvas as EuCanvas).boxes;
  const out: number[] = [];
  for (let i: number = 0; i < boxes.length; i++) {
    const b: EuBox | SuBox = boxes[i];
    out.push(b.x, b.y, b.w, b.h, b.node.person.gender === '女' ? 1 : 0);
  }
  return out;
}

/**
 * 欧式 / 苏式分页画布导出 PDF（混合型）。
 *
 * PDFKit 的 PdfPage 只有文本、图片与批注对象，没有矢量线条 / 矩形 API，因此：
 *  - 纸面、装订口、页框、世系连线、卡片底色与描边 → 300dpi 栅格层（2×2 分块，JPEG q95）；
 *  - 页眉、页码、接续文案、卡片姓名与世次/UID → addTextObject 真实文本对象。
 *
 * 产出 PDF 的文字可选中、可搜索、放大不糊；栅格层只保留为线条与卡片框，
 * 以 300dpi 落位，印刷时线条与卡片边缘依旧锐利。页数与分页画布完全一致。
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
    const fonts: CardFonts = cardFontsOf(books[0].book as PrintBook);

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

    // 文本测量画布（vp 默认单位即可，只量宽度不落位）
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(MEASURE_W, MEASURE_H);
    const measureCtx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');

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
          const tiles: TileImage[] = await PagedPdfExportService.renderTiles(
            canvas, style, pageNo, book.profile.lineWidth, context);
          try {
            const page: pdfService.PdfPage = doc.insertBlankPage(doc.getPageCount(), PAGE_W_PT, PAGE_H_PT);
            // 先铺 300dpi 栅格层（线条/卡片框），再写矢量文字，文字位于最上层
            for (let ti: number = 0; ti < tiles.length; ti++) {
              PagedPdfExportService.addTile(page, tiles[ti]);
            }
            PagedPdfExportService.addTextObjects(page, rb.rootName, plan, canvas, style,
              pageNo, total, fonts, measureCtx);
          } finally {
            PagedPdfExportService.cleanupTiles(tiles);
          }
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

  /** 一块栅格图按 pt 落位：PDF 的 y 原点在左下角，需要从顶部像素换算 */
  private static addTile(page: pdfService.PdfPage, tile: TileImage): void {
    // 用整页像素比例换算，避免 300dpi 取整后按 PX_PER_MM 反算出现 0.02mm 的溢页/接缝
    const xPt: number = PAGE_W_PT * tile.xPx / RENDER_W;
    const wPt: number = PAGE_W_PT * tile.wPx / RENDER_W;
    const hPt: number = PAGE_H_PT * tile.hPx / RENDER_H;
    const yPt: number = PAGE_H_PT - PAGE_H_PT * (tile.yPx + tile.hPx) / RENDER_H;
    page.addImageObject(tile.path, xPt, yPt, wPt, hPt);
  }

  /**
   * 把一页拆成 2×2 栅格块并行渲染。
   * TaskPool 每个 worker 独立离屏绘制 + JPEG 编码；若并发任务不可用，
   * 自动回退到主线程串行渲染，保证导出不中断。
   */
  private static async renderTiles(canvas: EuCanvas | SuCanvas, style: string, pageNo: number,
    lineWidthMm: number, context: common.UIAbilityContext): Promise<TileImage[]> {
    const lineData: number[] = packLineData(canvas);
    const boxData: number[] = packBoxData(canvas, style);
    const metas: TileImage[] = [];
    const jobs: Array<Promise<Object>> = [];
    for (let r: number = 0; r < TILE_ROWS; r++) {
      const y0: number = Math.round(r * RENDER_H / TILE_ROWS);
      const y1: number = Math.round((r + 1) * RENDER_H / TILE_ROWS);
      for (let c: number = 0; c < TILE_COLS; c++) {
        const x0: number = Math.round(c * RENDER_W / TILE_COLS);
        const x1: number = Math.round((c + 1) * RENDER_W / TILE_COLS);
        const tile: TileImage = new TileImage();
        tile.path = context.cacheDir + '/paged_pdf_' + pageNo.toString() +
          '_' + r.toString() + '_' + c.toString() + '.jpg';
        tile.xPx = x0;
        tile.yPx = y0;
        tile.wPx = x1 - x0;
        tile.hPx = y1 - y0;
        metas.push(tile);
        const task: taskpool.Task = new taskpool.Task(renderTileJob, pageNo, r, c, lineWidthMm,
          lineData, boxData, context.cacheDir);
        jobs.push(taskpool.execute(task));
      }
    }
    try {
      await Promise.all(jobs);
    } catch (_e) {
      PagedPdfExportService.cleanupTiles(metas);
      return PagedPdfExportService.renderTilesSerial(canvas, style, pageNo, lineWidthMm, context);
    }
    return metas;
  }

  /** 兜底：主线程串行渲染（TaskPool 不可用时走这里） */
  private static async renderTilesSerial(canvas: EuCanvas | SuCanvas, style: string, pageNo: number,
    lineWidthMm: number, context: common.UIAbilityContext): Promise<TileImage[]> {
    const lineData: number[] = packLineData(canvas);
    const boxData: number[] = packBoxData(canvas, style);
    const off: OffscreenCanvas = new OffscreenCanvas(TILE_W, TILE_H, LengthMetricsUnit.PX);
    const g: OffscreenCanvasRenderingContext2D = off.getContext('2d');
    const packer: image.ImagePacker = image.createImagePacker();
    const out: TileImage[] = [];
    try {
      for (let r: number = 0; r < TILE_ROWS; r++) {
        const y0: number = Math.round(r * RENDER_H / TILE_ROWS);
        const y1: number = Math.round((r + 1) * RENDER_H / TILE_ROWS);
        for (let c: number = 0; c < TILE_COLS; c++) {
          const x0: number = Math.round(c * RENDER_W / TILE_COLS);
          const x1: number = Math.round((c + 1) * RENDER_W / TILE_COLS);
          const w: number = x1 - x0;
          const h: number = y1 - y0;
          paintRasterTile(g, x0, y0, x0 + w, y0 + h, lineWidthMm, lineData, boxData);
          const pm: image.PixelMap = g.getPixelMap(0, 0, w, h);
          let buf: ArrayBuffer;
          try {
            const opt: image.PackingOption = { format: 'image/jpeg', quality: 95 };
            buf = await packer.packing(pm, opt);
          } finally {
            pm.release();
          }
          const imgPath: string = context.cacheDir + '/paged_pdf_' + pageNo.toString() +
            '_' + r.toString() + '_' + c.toString() + '.jpg';
          const fd: fileIo.File = fileIo.openSync(imgPath,
            fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          try {
            fileIo.writeSync(fd.fd, buf);
          } finally {
            fileIo.closeSync(fd);
          }
          const tile: TileImage = new TileImage();
          tile.path = imgPath;
          tile.xPx = x0;
          tile.yPx = y0;
          tile.wPx = w;
          tile.hPx = h;
          out.push(tile);
          await PagedPdfExportService.yieldToUi();
        }
      }
    } catch (e) {
      PagedPdfExportService.cleanupTiles(out);
      throw new Error('栅格渲染失败：' + (e as Error).message);
    } finally {
      packer.release();
    }
    return out;
  }

  /** 写入本页全部矢量文本：页眉、卡片姓名/世次、页脚接续文案、页码 */
  private static addTextObjects(page: pdfService.PdfPage, rootName: string, plan: PagePlan,
    canvas: EuCanvas | SuCanvas, style: string, pageNo: number, total: number,
    fonts: CardFonts, measureCtx: OffscreenCanvasRenderingContext2D): void {
    // 页眉
    const genText: string = (plan.genFrom > 0 && plan.genTo > 0)
      ? generationLabel(plan.genFrom) + (plan.genFrom === plan.genTo ? '' : '—' + generationLabel(plan.genTo))
      : '';
    const header: string = '世系图' + (genText.length > 0 ? ' · ' + genText : '') + (rootName.length > 0 ? ' · ' + rootName : '');
    page.addTextObject(header, INNER_X_MM * MM_TO_PT, baselineOfMm(6, HEADER_PT),
      pdfTextStyle(HEADER_PT, C_INK2, false));

    // 卡片文字：与画布上的卡片一致，姓名 / 字辈+故 / 世代+UID / 配偶，全部限制在卡片内
    const boxes: Array<EuBox | SuBox> = style === 'su' ? (canvas as SuCanvas).boxes : (canvas as EuCanvas).boxes;
    for (let i: number = 0; i < boxes.length; i++) {
      const b: EuBox | SuBox = boxes[i];
      const maxW: number = Math.max(1, b.w - 2.4) * MM_TO_PT;
      const leftX: number = (INNER_X_MM + b.x + 1) * MM_TO_PT;
      const rightX: number = (INNER_X_MM + b.x + b.w - 1) * MM_TO_PT;
      const tall: boolean = b.h >= 11.2;
      const compact: boolean = b.h < 9.0;
      const nameTop: number = compact ? 0.5 : (tall ? 1.1 : 0.8);
      const detailTop: number = compact ? 3.1 : (tall ? 4.3 : 3.7);
      const spouseTop: number = tall ? 7.2 : 6.3;

      // 右上角字辈 / 在世状态（已故 → 故，失联/不详照原样显示）
      let badge: string = b.node.person.generationChar.length > 0 ?
        b.node.person.generationChar + '字' : '';
      let lifeText: string = '';
      if (b.node.person.lifeStatus === '已故') {
        lifeText = '故';
      } else if (b.node.person.lifeStatus === '失联') {
        lifeText = '失联';
      } else if (b.node.person.lifeStatus === '不详') {
        lifeText = '不详';
      }
      if (lifeText.length > 0) {
        badge += badge.length > 0 ? ' ' + lifeText : lifeText;
      }
      const badgeSize: number = compact ? 4.4 : 4.8;
      let badgeW: number = 0;
      if (badge.length > 0) {
        // 角标右对齐：PDF 内嵌字体比 canvas 量出的宽不少，量宽再加 3 个字符位，
        // 确保「德字 故」这类角标整体落在卡片边框内
        badgeW = cardTextWidth(measureCtx, badge, badgeSize) + 3 * badgeSize;
        page.addTextObject(badge, Math.max(leftX, rightX - badgeW),
          baselineOfMm(INNER_Y_MM + b.y + (compact ? 1.2 : 1.6), badgeSize),
          pdfTextStyle(badgeSize, C_GOLD, false));
      }

      const name: string = b.node.person.name.length > 0 ? b.node.person.name : b.node.uid;
      if (name.length > 0) {
        const nameMaxW: number = badgeW > 0 ? Math.max(4, maxW - badgeW - 1.2) : maxW;
        const nameSize: number = fitCardSize(measureCtx, name, nameMaxW,
          compact ? 7 : fonts.namePt, 6);
        page.addTextObject(fitCardText(measureCtx, name, nameMaxW, nameSize), leftX,
          baselineOfMm(INNER_Y_MM + b.y + nameTop, nameSize),
          // 不能用 isBold：PDFKit 用「填充+描边」(Tr 2) 模拟粗体，8pt 小字会被描边糊成一团
          pdfTextStyle(nameSize, C_INK, false));
      }

      let detail: string = generationLabel(b.node.person.generation);
      if (b.node.uid.length > 0) {
        detail += ' · ' + compactUid(b.node.uid);
      }
      if (detail.length > 0) {
        const detailSize: number = fitCardSize(measureCtx, detail, maxW, compact ? 5.6 : fonts.detailPt, 5.2);
        page.addTextObject(fitCardText(measureCtx, detail, maxW, detailSize), leftX,
          baselineOfMm(INNER_Y_MM + b.y + detailTop, detailSize),
          pdfTextStyle(detailSize, C_INK2, false));
      }

      // 配偶行（卡片过矮时不画，避免压框）
      const spouse: string = b.node.spouseText();
      if (!compact && spouse.length > 0) {
        const spouseSize: number = fitCardSize(measureCtx, spouse, maxW, tall ? 6 : 5.6, 5.0);
        page.addTextObject(fitCardText(measureCtx, spouse, maxW, spouseSize), leftX,
          baselineOfMm(INNER_Y_MM + b.y + spouseTop, spouseSize),
          pdfTextStyle(spouseSize, C_INK2, false));
      }
    }

    // 页脚接续文案：单独一行（距底 12mm），给下方页码留出位置
    if (plan.footerText.length > 0) {
      const footW: number = (TRIM_W_MM - INNER_X_MM - 10) * MM_TO_PT;
      page.addTextObject(fitText(measureCtx, plan.footerText, footW, FOOTER_PT),
        INNER_X_MM * MM_TO_PT,
        baselineOfMm(TRIM_H_MM - 12, FOOTER_PT), pdfTextStyle(FOOTER_PT, C_FOOT, false));
    }

    // 页码：居中放在页脚下一行（距底 6mm），与接续文案不再同一基线
    const footer: string = '第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页';
    const fw: number = measurePt(measureCtx, footer, PAGE_NO_PT);
    page.addTextObject(footer, PAGE_W_PT / 2 - fw / 2,
      baselineOfMm(TRIM_H_MM - 6, PAGE_NO_PT), pdfTextStyle(PAGE_NO_PT, C_INK2, false));
  }

  private static cleanupTiles(tiles: TileImage[]): void {
    for (let i: number = 0; i < tiles.length; i++) {
      try {
        fileIo.unlinkSync(tiles[i].path);
      } catch (_e) {
        // 临时文件可能已被清理，忽略
      }
    }
  }

  private static yieldToUi(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(() => {
        resolve();
      }, 8);
    });
  }
}