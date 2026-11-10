import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Font } from '@kit.ArkUI';
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

/**
 * 栅格层：450dpi（320×220mm → 约 5669×3898px）。
 *
 * 450dpi 全页 RGBA 约 88MB，直接建一张整页画布在低端机上容易 OOM，
 * 因此按 2×2 分成四块独立渲染（单块约 2835×1949px、22MB），逐块编码、逐块释放。
 * 分块尺寸同时避开部分 GPU 4096px 纹理上限。
 */
const RENDER_DPI: number = 450;
const PX_PER_MM: number = RENDER_DPI / 25.4;
const RENDER_W: number = Math.round(PAGE_W_MM * PX_PER_MM);
const RENDER_H: number = Math.round(PAGE_H_MM * PX_PER_MM);
const TILE_COLS: number = 2;
const TILE_ROWS: number = 2;
const TILE_W: number = Math.ceil(RENDER_W / TILE_COLS);
const TILE_H: number = Math.ceil(RENDER_H / TILE_ROWS);

/** 页面几何（与 PrintLayout 保持一致） */
const GUTTER_MM: number = 20;
const INNER_X_MM: number = 26;
const INNER_Y_MM: number = 20;
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

const C_PAPER: string = '#FFFDF6';
const C_BIND: string = '#F4EFE3';
const C_INK: string = '#2E2A24';
const C_INK2: string = '#7A6A57';
const C_GOLD: string = '#C9A227';
const C_RED: string = '#B03A2E';
const C_FEMALE: string = '#A0527A';
const C_LINE: string = '#D8CBB2';
const C_FOOT: string = '#8C2F1E';

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
    try {
      const f: Font = new Font();
      const info = f.getFontByName('HarmonyOS Sans');
      fi.fontPath = info.path;
    } catch (_e) {
      // 取不到系统字体时交给 PDF 默认字体
    }
    fi.fontName = '';
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

/**
 * 欧式 / 苏式分页画布导出 PDF（混合型）。
 *
 * PDFKit 的 PdfPage 只有文本、图片与批注对象，没有矢量线条 / 矩形 API，因此：
 *  - 纸面、装订口、页框、世系连线、卡片底色与描边 → 450dpi 栅格层（2×2 分块，PNG 无损，不支持时降级 JPEG 96）；
 *  - 页眉、页码、接续文案、卡片姓名与世次/UID → addTextObject 真实文本对象。
 *
 * 产出 PDF 的文字可选中、可搜索、放大不糊；栅格层只保留为线条与卡片框，
 * 以 450dpi 落位，印刷时线条与卡片边缘依旧锐利。页数与分页画布完全一致。
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

    // 栅格画布复用：只申请一块分块大小的画布，逐块重绘，避免整页 450dpi 的内存峰值
    const tileCanvas: OffscreenCanvas = new OffscreenCanvas(TILE_W, TILE_H);
    const tileCtx: OffscreenCanvasRenderingContext2D = tileCanvas.getContext('2d');
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(MEASURE_W, MEASURE_H);
    const measureCtx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');
    const packer: image.ImagePacker = image.createImagePacker();

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
            tileCtx, canvas, style, pageNo, book.profile.lineWidth, context, packer);
          try {
            const page: pdfService.PdfPage = doc.insertBlankPage(doc.getPageCount(), PAGE_W_PT, PAGE_H_PT);
            // 先铺 450dpi 栅格层（线条/卡片框），再写矢量文字，文字位于最上层
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
      packer.release();
    }
    return outPath;
  }

  /** 一块栅格图按 pt 落位：PDF 的 y 原点在左下角，需要从顶部像素换算 */
  private static addTile(page: pdfService.PdfPage, tile: TileImage): void {
    // 用整页像素比例换算，避免 450dpi 取整后按 PX_PER_MM 反算出现 0.02mm 的溢页/接缝
    const xPt: number = PAGE_W_PT * tile.xPx / RENDER_W;
    const wPt: number = PAGE_W_PT * tile.wPx / RENDER_W;
    const hPt: number = PAGE_H_PT * tile.hPx / RENDER_H;
    const yPt: number = PAGE_H_PT - PAGE_H_PT * (tile.yPx + tile.hPx) / RENDER_H;
    page.addImageObject(tile.path, xPt, yPt, wPt, hPt);
  }

  /** 把一页拆成 2×2 栅格块，逐块渲染成 PNG，返回落位信息 */
  private static async renderTiles(
    g: OffscreenCanvasRenderingContext2D,
    canvas: EuCanvas | SuCanvas,
    style: string,
    pageNo: number,
    lineWidthMm: number,
    context: common.UIAbilityContext,
    packer: image.ImagePacker
  ): Promise<TileImage[]> {
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
          PagedPdfExportService.paintTile(g, canvas, style, x0, y0, lineWidthMm);

          const pm: image.PixelMap = g.getPixelMap(0, 0, w, h);
          // PNG 无损优先；个别机型 ImagePacker 不支持 PNG 时降级 JPEG 96，
          // 避免整页只剩文字、线条与卡片框全部丢失
          let ext: string = '.png';
          let buf: ArrayBuffer;
          try {
            buf = await packer.packing(pm, { format: 'image/png' });
          } catch (_e) {
            ext = '.jpg';
            buf = await packer.packing(pm, { format: 'image/jpeg', quality: 96 });
          } finally {
            pm.release();
          }
          const imgPath: string = context.cacheDir + '/paged_pdf_' + pageNo.toString() +
            '_' + r.toString() + '_' + c.toString() + ext;
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
        }
      }
    } catch (e) {
      PagedPdfExportService.cleanupTiles(out);
      throw new Error('栅格渲染失败：' + (e as Error).message);
    }
    return out;
  }

  /** 在一块画布上画出整页的栅格内容（只画线条与卡片框，文字全部留给 PDF 文本对象） */
  private static paintTile(g: OffscreenCanvasRenderingContext2D, canvas: EuCanvas | SuCanvas,
    style: string, x0: number, y0: number, lineWidthMm: number): void {
    g.clearRect(0, 0, TILE_W, TILE_H);

    // 纸面与装订口：整页尺寸绘制，靠画布边缘裁切，分块之间接缝严格对齐
    g.fillStyle = C_PAPER;
    g.fillRect(-x0, -y0, RENDER_W, RENDER_H);
    g.fillStyle = C_BIND;
    g.fillRect(-x0, -y0, GUTTER_MM * PX_PER_MM, RENDER_H);
    g.strokeStyle = C_LINE;
    g.lineWidth = 1;
    g.strokeRect(0.5 - x0, 0.5 - y0, RENDER_W - 1, RENDER_H - 1);

    // 连线：红色婚约双线 / 金色世系线
    const lw: number = Math.max(1, lineWidthMm * PX_PER_MM);
    for (let i: number = 0; i < canvas.lines.length; i++) {
      const seg: LineSeg = canvas.lines[i];
      g.strokeStyle = seg.red ? C_RED : C_GOLD;
      g.lineWidth = lw;
      g.beginPath();
      g.moveTo((INNER_X_MM + seg.x1) * PX_PER_MM - x0, (INNER_Y_MM + seg.y1) * PX_PER_MM - y0);
      g.lineTo((INNER_X_MM + seg.x2) * PX_PER_MM - x0, (INNER_Y_MM + seg.y2) * PX_PER_MM - y0);
      g.stroke();
    }

    // 卡片：底色 + 描边（姓名等文字不画，交给矢量文本层）
    const boxes: Array<EuBox | SuBox> = style === 'su' ? (canvas as SuCanvas).boxes : (canvas as EuCanvas).boxes;
    for (let i: number = 0; i < boxes.length; i++) {
      const b: EuBox | SuBox = boxes[i];
      PagedPdfExportService.drawCard(g, b.node, b.x, b.y, b.w, b.h, x0, y0);
    }
  }

  /** 写入本页全部矢量文本：页眉、卡片姓名/世次、页脚接续文案、页码 */
  private static addTextObjects(page: pdfService.PdfPage, rootName: string, plan: PagePlan,
    canvas: EuCanvas | SuCanvas, style: string, pageNo: number, total: number,
    fonts: CardFonts, measureCtx: OffscreenCanvasRenderingContext2D): void {
    // 页眉
    const genText: string = (plan.genFrom > 0 && plan.genTo > 0)
      ? '第' + generationLabel(plan.genFrom) + (plan.genFrom === plan.genTo ? '' : '—' + generationLabel(plan.genTo))
      : '';
    const header: string = '世系图' + (genText.length > 0 ? ' · ' + genText : '') + (rootName.length > 0 ? ' · ' + rootName : '');
    page.addTextObject(header, INNER_X_MM * MM_TO_PT, baselineOfMm(6, HEADER_PT),
      pdfTextStyle(HEADER_PT, C_INK2, false));

    // 卡片文字
    const boxes: Array<EuBox | SuBox> = style === 'su' ? (canvas as SuCanvas).boxes : (canvas as EuCanvas).boxes;
    for (let i: number = 0; i < boxes.length; i++) {
      const b: EuBox | SuBox = boxes[i];
      const name: string = b.node.person.name.length > 0 ? b.node.person.name : b.node.uid;
      if (name.length > 0) {
        page.addTextObject(name,
          (INNER_X_MM + b.x + 1) * MM_TO_PT,
          baselineOfMm(INNER_Y_MM + b.y + 1.1, fonts.namePt),
          pdfTextStyle(fonts.namePt, C_INK, true));
      }
      let detail: string = generationLabel(b.node.person.generation);
      if (b.node.uid.length > 0) {
        detail += ' · ' + b.node.uid;
      }
      if (detail.length > 0) {
        page.addTextObject(detail,
          (INNER_X_MM + b.x + 1) * MM_TO_PT,
          baselineOfMm(INNER_Y_MM + b.y + 5.2, fonts.detailPt),
          pdfTextStyle(fonts.detailPt, C_INK2, false));
      }
    }

    // 页脚接续文案
    if (plan.footerText.length > 0) {
      page.addTextObject(plan.footerText, INNER_X_MM * MM_TO_PT,
        baselineOfMm(TRIM_H_MM - 8, FOOTER_PT), pdfTextStyle(FOOTER_PT, C_FOOT, false));
    }

    // 页码：居中，字号比接续文案大，印出来能看清
    const footer: string = '第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页';
    const fw: number = measurePt(measureCtx, footer, PAGE_NO_PT);
    page.addTextObject(footer, PAGE_W_PT / 2 - fw / 2,
      baselineOfMm(TRIM_H_MM - 8, PAGE_NO_PT), pdfTextStyle(PAGE_NO_PT, C_INK2, false));
  }

  /** 一张人物卡的底色与描边，女卡用绛紫描边；坐标为整页像素坐标，按分块原点平移 */
  private static drawCard(g: OffscreenCanvasRenderingContext2D, node: PersonNode,
    x: number, y: number, w: number, h: number, x0: number, y0: number): void {
    const px: number = (INNER_X_MM + x) * PX_PER_MM - x0;
    const py: number = (INNER_Y_MM + y) * PX_PER_MM - y0;
    const w0: number = w * PX_PER_MM;
    const h0: number = h * PX_PER_MM;
    const female: boolean = node.person.gender === '女';
    g.fillStyle = female ? '#FBF1F5' : '#FFFFFF';
    g.fillRect(px, py, w0, h0);
    g.strokeStyle = female ? C_FEMALE : C_GOLD;
    g.lineWidth = Math.max(1, 0.2 * PX_PER_MM);
    g.strokeRect(px + 0.5, py + 0.5, w0 - 1, h0 - 1);
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