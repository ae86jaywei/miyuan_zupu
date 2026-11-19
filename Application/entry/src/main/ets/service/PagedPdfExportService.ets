import { T } from 'common_base';
import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Font, LengthMetricsUnit } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { currentPssKb, PDF_MEMORY_HARD_LIMIT_KB, PAGED_PDF_SOFT_LIMIT_KB } from './pdf/PdfMemory';
import { MM_TO_PT, PDF_MUTED, PDF_TEXT, PDF_TEXT_2, PDF_HEADER, PDF_FOOTER } from './pdf/PdfCommon';
import { Genealogy } from 'common_base';
import { generationLabel } from 'common_base';
import { PaginationService, PrintBook, PagePlan, pageGenText } from './PaginationService';
import { GenealogyService } from './GenealogyService';
import { EuCanvas, EuBox, LineSeg, SuCanvas, SuBox } from 'common_base';
import { PersonNode } from 'common_base';
import { compactUid } from 'common_base';
import { parseYear } from 'common_dateutil';
import { paintRasterTile, C_FOOT, C_GOLD, C_INK, C_INK2, INNER_Y_MM,
  JPEG_QUALITY, PAGE_H_MM, PAGE_W_MM, PX_PER_MM, RENDER_H, RENDER_W,
  TILE_COLS, TILE_H, TILE_ROWS, TILE_W } from './PdfRasterJob';
import { renderTileJob } from './PdfTileTask';
import { PageCacheService } from './PageCacheService';
import { TreeLayoutCache } from './TreeLayoutCache';
import { RawPdfWriter, PdfTextRun, PdfInfo } from './RawPdfWriter';
import { RawPdfFont } from './RawPdfFont';
import { PdfFontUtil } from './PdfFontUtil';

// PDF 单位换算与基础色统一由 service/pdf/PdfCommon 提供
const PAGE_W_PT: number = PAGE_W_MM * MM_TO_PT;
const PAGE_H_PT: number = PAGE_H_MM * MM_TO_PT;

const TRIM_W_MM: number = 320;
const TRIM_H_MM: number = 220;

/** 矢量文字字号（pt）：页眉/页码与卡片姓名、详情 */
const HEADER_PT: number = 8;
const FOOTER_PT: number = 6.5;
const PAGE_NO_PT: number = 8;
/** 页首承接祖先文字：浅灰，弱于正文卡片 */
const C_ANCESTOR: string = PDF_MUTED;
/** 标准卡（卡高 ≥10mm）上姓名 7→8pt、详情 5.5→6.5pt，矢量文字印出来更清楚 */
const CARD_NAME_PT: number = 8;
const CARD_DETAIL_PT: number = 6.5;
const MEASURE_W: number = 1024;
const MEASURE_H: number = 256;

/**
 * 恢复 4625ab1 的 30 页/卷：当时 4800 人 ≈ 8 卷 × 30 页，导出成功。
 * 关键不在卷大小，而在每页渲染完立即删除临时图（见导出循环）。
 */
const PAGED_MAX_PAGES_PER_VOLUME: number = 30;
/** 导出过程允许的内存增长（KB）：超过只告警 */
const PAGED_MEMORY_GROWTH_LIMIT_KB: number = 1200 * 1024;
/** 每渲染多少页检查一次 PSS */
const PAGED_MEMORY_CHECK_PAGES: number = 4;

export interface PagedPdfProgress {
  current: number;
  total: number;
  message: string;
}

/** 整页渲染结果：JPEG 路径 + 不可见文本层（F2 检索用）+ 页眉标题（书签用） */
class RawPageResult {
  path: string = '';
  runs: PdfTextRun[] = [];
  header: string = '';
}

class RootBook {
  rootUid: string = '';
  rootName: string = '';
  book: PrintBook | null = null;
  /** 本次分页本是否来自持久化缓存（命中时不再重建） */
  fromCache: boolean = false;
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

/**
 * 全角字符判断：CJK 汉字、假名、韩文与全角标点，系统字体里都是 1em 宽。
 */
function isWideChar(cp: number): boolean {
  return (cp >= 0x2e80 && cp <= 0x9fff) || (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xff00 && cp <= 0xff60) || (cp >= 0x20000 && cp <= 0x3ffff);
}

/** 半角字符宽度比例：系统字体数字/字母约 0.55em，取 0.6 按宽估，宁截断不压框 */
const HALF_WIDTH_RATIO: number = 0.6;

/**
 * 按字号比例累加文本宽度（px）。
 * 不能用 OffscreenCanvas.measureText：本机实测只返回真实宽度的两成左右，
 * 卡片文字的缩字号/截断判断会全部失效，文字直接压出卡片边框和装订线。
 */
function measurePx(text: string, fontPx: number): number {
  let w: number = 0;
  let i: number = 0;
  while (i < text.length) {
    const cp: number = text.codePointAt(i) ?? 0;
    w = w + (isWideChar(cp) ? fontPx : fontPx * HALF_WIDTH_RATIO);
    i = i + (cp > 0xffff ? 2 : 1);
  }
  return w;
}

/** 量出文本宽度（pt）：与 measurePx 同一比例，只是单位不同 */
function measurePt(ctx: OffscreenCanvasRenderingContext2D, text: string, sizePt: number): number {
  return measurePx(text, sizePt);
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

/** 卡片文字安全系数：宽度已按字宽比例估，只留 2% 余量吸收取整误差 */
const CARD_TEXT_SAFETY: number = 1.02;

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

  /**
   * 方案 F：自写 PDF（RawPdfWriter + JPEG 直嵌）。
   *
   * 与 PDFKit 路径的关键区别：
   *  - 每页 1 张 300dpi 整页 JPEG（不分块），文字直接画进栅格，清晰度不降；
   *  - JPEG 以 DCTDecode 原样写入 PDF，**不解码 PixelMap**，内存只与单页有关；
   *  - 逐页 append 写文件，写完即删临时图，内存不随页数累积。
   * 代价：PDF 文字暂不可搜索（文字在图片内），后续可加字体层。
   */
  static async exportRawPdf(
    context: common.UIAbilityContext,
    genealogy: Genealogy,
    style: string,
    onProgress?: (p: PagedPdfProgress) => void
  ): Promise<string[]> {
    const svc: PaginationService = PaginationService.getInstance();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    if (roots.length === 0) {
      throw new Error('没有可导出的人物数据');
    }
    const peopleCount: number = GenealogyService.getInstance().getPeople().length;
    const profileName: string = peopleCount > 15000 ? 'compact' : 'standard';
    // F3：嵌入系统 HarmonyOS Sans；读取失败时 RawPdfWriter 自动回退 STSong-Light
    const fontPath: string = PdfFontUtil.fontPath();
    const rawFont: RawPdfFont | null = PdfFontUtil.rawFont();
    const version: number = Date.now();
    const books: PrintBook[] = [];
    let total: number = 0;
    for (let i: number = 0; i < roots.length; i = i + 1) {
      const b: PrintBook = await svc.book(roots[i].uid, style, version, profileName,
        (pct: number): void => {
          if (onProgress) {
            onProgress({ current: 0, total: 0, message: T('正在排版 ') + pct.toString() + '%' });
          }
        });
      books.push(b);
      total = total + b.pages.length;
    }
    if (total === 0) {
      throw new Error('分页结果为空');
    }
    const outDir: string = context.filesDir + '/pdf_export';
    try {
      if (!fileIo.accessSync(outDir)) {
        fileIo.mkdirSync(outDir);
      }
    } catch (_e) {
    }
    const now: Date = new Date();
    const stamp: string = now.getFullYear().toString() +
      (now.getMonth() + 1).toString().padStart(2, '0') +
      now.getDate().toString().padStart(2, '0') + '_' +
      now.getHours().toString().padStart(2, '0') +
      now.getMinutes().toString().padStart(2, '0');
    const styleName: string = style === 'su' ? '苏式' : '欧式';
    const maxPages: number = 30;
    const volumeCount: number = Math.max(1, Math.ceil(total / maxPages));

    const pageBook: number[] = [];
    const pageLocal: number[] = [];
    for (let bi: number = 0; bi < books.length; bi = bi + 1) {
      const n: number = books[bi].pages.length;
      for (let pi: number = 1; pi <= n; pi = pi + 1) {
        pageBook.push(bi);
        pageLocal.push(pi);
      }
    }

    const outPaths: string[] = [];
    let globalPage: number = 0;
    for (let v: number = 0; v < volumeCount; v = v + 1) {
      const startG: number = v * maxPages;
      const endG: number = Math.min(total, startG + maxPages);
      const volCount: number = endG - startG;
      const title: string = PagedPdfExportService.safeName(genealogy.title);
      const outPath: string = volumeCount > 1
        ? outDir + '/' + title + '_' + styleName + '_' + stamp + '_第' + (v + 1).toString() + '卷.pdf'
        : outDir + '/' + title + '_' + styleName + '_' + stamp + '.pdf';
      const info: PdfInfo = new PdfInfo(genealogy.title +
        (volumeCount > 1 ? ' 第' + (v + 1).toString() + '卷' : ''));
      const writer: RawPdfWriter = new RawPdfWriter(outPath, PAGE_W_PT, PAGE_H_PT, RENDER_W, RENDER_H,
        rawFont, info);
      let lastBook: number = -1;
      let currentBook: PrintBook | null = null;
      let currentRootName: string = '';
      for (let g: number = startG; g < endG; g = g + 1) {
        const bi: number = pageBook[g];
        const localIdx: number = pageLocal[g];
        if (bi !== lastBook) {
          currentBook = books[bi];
          svc.adoptBook(currentBook);
          currentRootName = roots[bi].person.name.length > 0 ? roots[bi].person.name : roots[bi].uid;
          lastBook = bi;
        }
        if (currentBook === null) {
          continue;
        }
        const plan: PagePlan | null = currentBook.page(localIdx);
        if (plan === null) {
          continue;
        }
        const canvas: EuCanvas | SuCanvas | null =
          style === 'su' ? svc.suPage(localIdx) : svc.euPage(localIdx);
        if (canvas === null) {
          throw new Error('第 ' + localIdx.toString() + ' 页布局为空');
        }
        // 双面印刷按「卷内页序」交替装订侧：每卷单独装订，不能按宗支内页码判断
        const recto: boolean = ((g - startG + 1) % 2) === 1;
        const innerXMm: number = currentBook.spec.innerX(recto);
        const contentWMm: number = currentBook.spec.contentWidth();
        const gutterXMm: number = currentBook.spec.gutterX(recto);
        const gutterWMm: number = currentBook.spec.gutter;
        const raw: RawPageResult = await PagedPdfExportService.renderRawPage(canvas, plan, genealogy,
          style, currentRootName, v + 1, g - startG + 1, volCount, context, innerXMm, contentWMm,
          gutterXMm, gutterWMm);
        writer.addJpegPage(raw.path, raw.runs, raw.header);
        try {
          fileIo.unlinkSync(raw.path);
        } catch (_e) {
        }
        globalPage = globalPage + 1;
        if (onProgress) {
          const volTag: string = volumeCount > 1
            ? '（第' + (v + 1).toString() + '/' + volumeCount.toString() + '卷）' : '';
          onProgress({ current: globalPage, total: total,
            message: T('渲染分页 ') + globalPage.toString() + '/' + total.toString() + volTag });
        }
        await PagedPdfExportService.yieldToUi();
      }
      writer.finish();
      outPaths.push(outPath);
      await PagedPdfExportService.yieldToUi();
    }
    return outPaths;
  }

  /** 渲染整页 300dpi JPEG：线条/卡片框 + 中文文字都画进图，同时收集不可见文本层 */
  private static async renderRawPage(canvas: EuCanvas | SuCanvas, plan: PagePlan,
    genealogy: Genealogy, style: string, rootName: string, volumeNo: number, pageNo: number,
    totalPages: number, context: common.UIAbilityContext, innerXMm: number, contentWMm: number,
    gutterXMm: number, gutterWMm: number): Promise<RawPageResult> {
    const lineData: number[] = packLineData(canvas);
    const boxData: number[] = packBoxData(canvas, style);
    const off: OffscreenCanvas = new OffscreenCanvas(RENDER_W, RENDER_H, LengthMetricsUnit.PX);
    const ctx: OffscreenCanvasRenderingContext2D = off.getContext('2d');
    paintRasterTile(ctx, 0, 0, RENDER_W, RENDER_H, 0.2, lineData, boxData,
      innerXMm, gutterXMm, gutterWMm);
    const runs: PdfTextRun[] = PagedPdfExportService.drawRawText(ctx, canvas, plan, genealogy,
      style, rootName, volumeNo, pageNo, totalPages, innerXMm, contentWMm);
    const pm: image.PixelMap = ctx.getPixelMap(0, 0, RENDER_W, RENDER_H);
    const packer: image.ImagePacker = image.createImagePacker();
    const opt: image.PackingOption = { format: 'image/jpeg', quality: 95 };
    const buf: ArrayBuffer = await packer.packing(pm, opt);
    const path: string = context.cacheDir + '/raw_pdf_' + pageNo.toString() + '_' +
      Date.now().toString() + '.jpg';
    const fh: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(fh.fd, buf);
    } finally {
      fileIo.closeSync(fh);
    }
    pm.release();
    packer.release();
    const result: RawPageResult = new RawPageResult();
    result.path = path;
    result.runs = runs;
    result.header = PagedPdfExportService.rawHeader(genealogy, rootName, plan);
    return result;
  }

  /** 页眉文本（页面上画出，同时作为书签标题） */
  private static rawHeader(genealogy: Genealogy, rootName: string, plan: PagePlan): string {
    return genealogy.title + (rootName.length > 0 ? ' · ' + rootName : '') + ' · ' + pageGenText(plan);
  }

  /** 画页眉、卡片姓名/UID、页脚，并收集不可见文本层（F2 检索） */
  private static drawRawText(ctx: OffscreenCanvasRenderingContext2D, canvas: EuCanvas | SuCanvas,
    plan: PagePlan, genealogy: Genealogy, style: string, rootName: string,
    volumeNo: number, pageNo: number, totalPages: number, innerXMm: number,
    contentWMm: number): PdfTextRun[] {
    const runs: PdfTextRun[] = [];
    const maxTextW: number = contentWMm * PX_PER_MM;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = PDF_HEADER;
    let headerSize: number = 28;
    const header: string = T(PagedPdfExportService.rawHeader(genealogy, rootName, plan));
    ctx.font = headerSize.toString() + 'px sans-serif';
    while (headerSize > 14 && measurePx(header, headerSize) > maxTextW) {
      headerSize = headerSize - 2;
      ctx.font = headerSize.toString() + 'px sans-serif';
    }
    ctx.fillText(header, RENDER_W / 2, 46);
    const headerW: number = measurePx(header, headerSize);
    runs.push(PagedPdfExportService.textRun(header, RENDER_W / 2 - headerW / 2, 46, headerSize));

    if (style === 'su') {
      const su: SuCanvas = canvas as SuCanvas;
      for (let i: number = 0; i < su.boxes.length; i = i + 1) {
        const b: SuBox = su.boxes[i];
        PagedPdfExportService.drawBoxText(ctx, b.node, b.x, b.y, b.w, b.h, runs, innerXMm);
      }
    } else {
      const eu: EuCanvas = canvas as EuCanvas;
      for (let i: number = 0; i < eu.boxes.length; i = i + 1) {
        const b: EuBox = eu.boxes[i];
        PagedPdfExportService.drawBoxText(ctx, b.node, b.x, b.y, b.w, b.h, runs, innerXMm);
      }
    }

    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = PDF_FOOTER;
    ctx.font = '22px sans-serif';
    const foot: string = T('第 ' + volumeNo.toString() + ' 卷 · 第 ' + pageNo.toString() +
      ' 页 / 共 ' + totalPages.toString() + ' 页');
    ctx.fillText(foot, RENDER_W / 2, RENDER_H - 24);
    const footW: number = measurePx(foot, 22);
    runs.push(PagedPdfExportService.textRun(foot, RENDER_W / 2 - footW / 2, RENDER_H - 24, 22));
    return runs;
  }

  /** 卡片内文字：第1行「姓名 字：xxx」，第2行「ID 排行」，第3行「生卒：xxxx年-xxxx年」 */
  private static drawBoxText(ctx: OffscreenCanvasRenderingContext2D, node: PersonNode,
    xMm: number, yMm: number, wMm: number, hMm: number, runs: PdfTextRun[],
    innerXMm: number): void {
    const px: number = (innerXMm + xMm) * PX_PER_MM;
    const py: number = (INNER_Y_MM + yMm) * PX_PER_MM;
    const wPx: number = wMm * PX_PER_MM;
    const hPx: number = hMm * PX_PER_MM;
    const p = node.person;

    // 第 1 行：姓名 + 字（曾用名/小名）
    const name: string = p.name.length > 0 ? p.name : node.uid;
    const alias: string = p.alias.trim();
    const line1: string = T(alias.length > 0 ? name + ' 字：' + alias : name);
    // 第 2 行：ID + 排行（只显示「长子」这类值，不加「排行」前缀）
    const rank: string = p.rank.trim();
    const idText: string = compactUid(node.uid);
    const line2: string = T(rank.length > 0 ? idText + ' ' + rank : idText);
    // 第 3 行：生卒年份（只有生/只有卒时改用「生于/卒于」）
    const by: number = parseYear(p.birthDate);
    const dy: number = parseYear(p.deathDate);
    let line3: string = '';
    if (by > 0 && dy > 0) {
      line3 = T('生卒：' + by.toString() + '年-' + dy.toString() + '年');
    } else if (by > 0) {
      line3 = T('生于：' + by.toString() + '年');
    } else if (dy > 0) {
      line3 = T('卒于：' + dy.toString() + '年');
    }
    const all: string[] = line3.length > 0 ? [line1, line2, line3] : [line1, line2];

    // 左上对齐：顶边起排，按行数压缩字号，保证不出卡片
    const padX: number = Math.max(2, Math.round(wPx * 0.03));
    const padY: number = Math.max(1, Math.round(hPx * 0.04));
    const availW: number = Math.max(12, wPx - padX * 2);
    const availH: number = Math.max(12, hPx - padY * 2);
    const lineH: number = availH / all.length;
    const nameFs: number = Math.max(10, Math.min(Math.round(hPx * 0.26),
      Math.floor(lineH * 0.86)));
    const detailFs: number = Math.max(8, Math.round(nameFs * 0.72));

    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    for (let i: number = 0; i < all.length; i = i + 1) {
      const isName: boolean = i === 0;
      const fontOf = (size: number): string =>
        (isName ? 'bold ' : '') + size.toString() + 'px sans-serif';
      let fs: number = isName ? nameFs : detailFs;
      ctx.font = fontOf(fs);
      const raw: string = all[i];
      const need: number = measurePx(raw, fs);
      // 行太长（姓名+字、生卒串）先按比例缩字号，缩到下限仍放不下再截断
      if (need > availW && need > 0) {
        fs = Math.max(isName ? 10 : 8, Math.floor(fs * availW / need));
        ctx.font = fontOf(fs);
      }
      ctx.fillStyle = isName ? PDF_TEXT : PDF_TEXT_2;
      const text: string = PagedPdfExportService.fitTextPx(raw, availW, fs);
      const yTop: number = py + padY + lineH * i + Math.max(0, (lineH - fs) / 2);
      ctx.fillText(text, px + padX, yTop, availW);
      runs.push(PagedPdfExportService.textRun(text, px + padX, yTop + fs * 0.8, fs));
    }
  }

  /** 按像素宽度截断，超出加省略号（宽度按字号比例估，与绘制字号一致） */
  private static fitTextPx(text: string, maxW: number, fsPx: number): string {
    if (text.length === 0 || measurePx(text, fsPx) <= maxW) {
      return text;
    }
    let cut: string = text;
    while (cut.length > 0 && measurePx(cut + '…', fsPx) > maxW) {
      cut = cut.substring(0, cut.length - 1);
    }
    return cut.length > 0 ? cut + '…' : '';
  }

  /** 像素坐标 → PDF 点坐标（文本层不可见，只用于检索） */
  private static textRun(text: string, px: number, py: number, fsPx: number): PdfTextRun {
    const r: PdfTextRun = new PdfTextRun();
    r.text = text;
    r.xPt = px / RENDER_W * PAGE_W_PT;
    r.yPt = PAGE_H_PT - py / RENDER_H * PAGE_H_PT;
    r.sizePt = Math.max(3, fsPx / RENDER_W * PAGE_W_PT);
    r.invisible = true;
    return r;
  }

  private static safeName(s: string): string {
    let out: string = '';
    for (let i: number = 0; i < s.length; i = i + 1) {
      const c: string = s.charAt(i);
      if (c === '\\' || c === '/' || c === ':' || c === '*' || c === '?' || c === '"' ||
        c === '<' || c === '>' || c === '|') {
        out = out + '_';
      } else {
        out = out + c;
      }
    }
    return out;
  }

  /** 把某一宗支的整本分页画布渲染成 PDF；多宗支依次追加到同一个 PDF */
  static async exportPdf(
    context: common.UIAbilityContext,
    genealogy: Genealogy,
    style: string,
    onProgress?: (p: PagedPdfProgress) => void
  ): Promise<string[]> {
    const svc: PaginationService = PaginationService.getInstance();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    if (roots.length === 0) {
      throw new Error('没有可导出的宗支');
    }

    // 先建册拿到总页数；单宗支优先读持久化分页缓存，命中则跳过整树装箱
    const version: number = Date.now();
    // 导出前释放连续视图的布局画布缓存（最多 8 本/谱式），给导出腾出内存
    TreeLayoutCache.getInstance().invalidate();
    // 大谱自动用紧凑档：卡 16×8mm、字号 6/5pt，单页容量提升约 1.5 倍，
    // 页数与卷数同步下降；1.5 万人以下仍用标准档保证阅读舒适度
    const peopleCount: number = GenealogyService.getInstance().getPeople().length;
    const profileName: string = peopleCount > 15000 ? 'compact' : 'standard';
    const books: RootBook[] = [];
    let total: number = 0;
    const singleRoot: boolean = roots.length === 1;
    let cacheBook: PrintBook | null = null;
    let cacheRootUid: string = '';
    for (let i: number = 0; i < roots.length; i++) {
      const rb: RootBook = new RootBook();
      rb.rootUid = roots[i].uid;
      rb.rootName = roots[i].person.name.length > 0 ? roots[i].person.name : roots[i].uid;
      let bk: PrintBook | null = null;
      if (singleRoot) {
        bk = await PageCacheService.getInstance().loadBook(style, profileName, roots[i].uid);
        if (bk !== null) {
          rb.fromCache = true;
          svc.adoptBook(bk);
        }
      }
      if (bk === null) {
        bk = await svc.book(roots[i].uid, style, version, profileName, (pct: number): void => {
          if (onProgress) {
            onProgress({ current: 0, total: 0, message: T('正在排版 ') + pct.toString() + '%' });
          }
        });
        if (singleRoot) {
          cacheBook = bk;
          cacheRootUid = roots[i].uid;
        }
      }
      rb.book = bk;
      total += bk.pages.length;
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
    // 展开「全局页序号 → (宗支下标, 册内页码)」映射，供按页数自动分卷使用
    const pageBook: number[] = [];
    const pageLocal: number[] = [];
    for (let bi: number = 0; bi < books.length; bi++) {
      const n: number = (books[bi].book as PrintBook).pages.length;
      for (let pi: number = 1; pi <= n; pi++) {
        pageBook.push(bi);
        pageLocal.push(pi);
      }
    }

    // 单卷最大页数：欧式/苏式每页都是 300dpi 栅格图，页数太多会让 PDF 文档内存暴涨甚至崩溃，
    // 超过阈值则自动拆成多个分卷 PDF；页数未超阈值时仍合并为一个文件（与旧版行为一致）。
    const maxPagesPerVolume: number = PAGED_MAX_PAGES_PER_VOLUME > 0 ? PAGED_MAX_PAGES_PER_VOLUME : total;
    const volumeCount: number = Math.max(1, Math.ceil(total / maxPagesPerVolume));

    // 文本测量画布（vp 默认单位即可，只量宽度不落位）
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(MEASURE_W, MEASURE_H);
    const measureCtx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');

    const outPaths: string[] = [];
    let globalPage: number = 0; // 已渲染的全局页数（进度用）
    // 记录导出基线 PSS：大谱基础占用高时，用增量判断比绝对值更可靠
    const basePssKb: number = currentPssKb();

    for (let v: number = 0; v < volumeCount; v++) {
      const startG: number = v * maxPagesPerVolume;
      const endG: number = Math.min(total, startG + maxPagesPerVolume);
      const volCount: number = endG - startG;
      // 单卷沿用原文件名；多卷加「_第N卷」后缀，便于区分
      const outPath: string = volumeCount > 1
        ? outDir + '/' + genealogy.title + '_' + styleName + '_' + stamp + '_第' + (v + 1).toString() + '卷.pdf'
        : outDir + '/' + genealogy.title + '_' + styleName + '_' + stamp + '.pdf';

      const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
      if (!doc.createDocument(PAGE_W_PT, PAGE_H_PT)) {
        throw new Error('PDF 文档创建失败');
      }
      try {
        if (doc.getPageCount() === 1) {
          doc.deletePage(0, 1);
        }
        let lastBook: number = -1; // 当前 doc 内已加载的宗支下标
        let currentRootName: string = '';
        let currentBook: PrintBook | null = null;
        for (let g: number = startG; g < endG; g++) {
          // 内存监控：软上限只告警继续，硬上限才中止，避免 981 人谱被误判拦下
          if (globalPage > 0 && globalPage % PAGED_MEMORY_CHECK_PAGES === 0) {
            const pssKb: number = currentPssKb();
            const growthKb: number = basePssKb > 0 && pssKb > 0 ? pssKb - basePssKb : -1;
            if (pssKb > 0 && (pssKb > PAGED_PDF_SOFT_LIMIT_KB ||
              growthKb > PAGED_MEMORY_GROWTH_LIMIT_KB)) {
              console.warn('[PagedPdf] memory high, pss=' + Math.round(pssKb / 1024).toString() +
                'MB base=' + Math.round(basePssKb / 1024).toString() + 'MB growth=' +
                Math.round(growthKb / 1024).toString() + 'MB page=' + globalPage.toString() +
                '/' + total.toString());
            }
            if (pssKb > PDF_MEMORY_HARD_LIMIT_KB) {
              throw new Error('导出内存占用过高（PSS ' + Math.round(pssKb / 1024).toString() +
                'MB，较导出开始增长 ' + Math.round(growthKb / 1024).toString() +
                'MB，已渲染 ' + globalPage.toString() + '/' + total.toString() +
                ' 页）。请减少单卷页数或分批导出。');
            }
          }
          const bi: number = pageBook[g];
          const localIdx: number = pageLocal[g];
          if (bi !== lastBook) {
            // 跨宗支时重新取回该宗支的分页册；命中持久化缓存的本无需重建
            const rb: RootBook = books[bi];
            if (!rb.fromCache) {
              rb.book = await svc.book(rb.rootUid, style, version, profileName);
            }
            currentBook = rb.book as PrintBook;
            currentRootName = rb.rootName;
            lastBook = bi;
          }
          if (currentBook === null) {
            continue;
          }
          const plan: PagePlan | null = currentBook.page(localIdx);
          if (plan === null) {
            continue;
          }
          globalPage++;
          const pageNoInVol: number = g - startG + 1; // 卷内页码：第X页/共 volCount 页
          // 双面印刷按卷内页序交替装订侧（与屏幕分页、栅格层保持同一几何）
          const recto: boolean = (pageNoInVol % 2) === 1;
          const innerXMm: number = currentBook.spec.innerX(recto);
          const gutterXMm: number = currentBook.spec.gutterX(recto);
          const gutterWMm: number = currentBook.spec.gutter;
          const canvas: EuCanvas | SuCanvas | null = style === 'su' ? svc.suPage(localIdx) : svc.euPage(localIdx);
          if (canvas === null) {
            throw new Error('第 ' + localIdx.toString() + ' 页布局为空');
          }
          const tiles: TileImage[] = await PagedPdfExportService.renderTiles(
            canvas, style, globalPage, currentBook.profile.lineWidth, context, innerXMm, gutterXMm,
            gutterWMm);
          try {
            const page: pdfService.PdfPage = doc.insertBlankPage(doc.getPageCount(), PAGE_W_PT, PAGE_H_PT);
            // 先铺栅格层（线条/卡片框），再写矢量文字，文字位于最上层
            for (let ti: number = 0; ti < tiles.length; ti++) {
              PagedPdfExportService.addTile(page, tiles[ti]);
            }
            PagedPdfExportService.addTextObjects(page, currentRootName, plan, canvas, style,
              v + 1, pageNoInVol, volCount, fonts, measureCtx, genealogy, innerXMm,
              currentBook.spec.contentWidth());
          } finally {
            // 每页渲染完立即删除临时图：恢复 4625ab1 的成功路径。
            // 整卷累积临时图会让 PDFKit 在 saveDocument 时一次性读入全部图片，内存峰值暴涨。
            PagedPdfExportService.cleanupTiles(tiles);
          }
          if (onProgress) {
            const volTag: string = volumeCount > 1
              ? '（第' + (v + 1).toString() + '/' + volumeCount.toString() + '卷）' : '';
            onProgress({ current: globalPage, total: total,
              message: T('渲染分页 ') + globalPage.toString() + '/' + total.toString() + volTag });
          }
          await PagedPdfExportService.yieldToUi();
        }
        const saved: boolean = doc.saveDocument(outPath);
        if (!saved) {
          throw new Error('PDF 保存失败');
        }
        outPaths.push(outPath);
      } finally {
        doc.releaseDocument();
      }
      // 每卷之间让出 UI 并给 GC 回收 native 内存的机会
      await PagedPdfExportService.yieldToUi();
    }
    // 导出完成后再落缓存：不与导出争主线程，数据版本变化时自动丢弃
    if (cacheBook !== null) {
      PageCacheService.getInstance().scheduleSave(cacheBook, style, profileName, cacheRootUid,
        PAGED_MAX_PAGES_PER_VOLUME);
    }
    return outPaths;
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
    lineWidthMm: number, context: common.UIAbilityContext, innerXMm: number, gutterXMm: number,
    gutterWMm: number): Promise<TileImage[]> {
    const lineData: number[] = packLineData(canvas);
    const boxData: number[] = packBoxData(canvas, style);
    const metas: TileImage[] = [];
    try {
      for (let r: number = 0; r < TILE_ROWS; r++) {
        const y0: number = Math.round(r * RENDER_H / TILE_ROWS);
        const y1: number = Math.round((r + 1) * RENDER_H / TILE_ROWS);
        const jobs: Array<Promise<Object>> = [];
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
            lineData, boxData, context.cacheDir, innerXMm, gutterXMm, gutterWMm);
          jobs.push(taskpool.execute(task));
        }
        // 按行提交：同一时刻最多 2 个 worker，把离屏画布峰值从 4 块降到 2 块，
        // 低内存机型上明显降低被系统杀进程的概率
        await Promise.all(jobs);
      }
    } catch (_e) {
      PagedPdfExportService.cleanupTiles(metas);
      return PagedPdfExportService.renderTilesSerial(canvas, style, pageNo, lineWidthMm, context,
        innerXMm, gutterXMm, gutterWMm);
    }
    return metas;
  }

  /** 兜底：主线程串行渲染（TaskPool 不可用时走这里） */
  private static async renderTilesSerial(canvas: EuCanvas | SuCanvas, style: string, pageNo: number,
    lineWidthMm: number, context: common.UIAbilityContext, innerXMm: number, gutterXMm: number,
    gutterWMm: number): Promise<TileImage[]> {
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
          paintRasterTile(g, x0, y0, x0 + w, y0 + h, lineWidthMm, lineData, boxData,
            innerXMm, gutterXMm, gutterWMm);
          const pm: image.PixelMap = g.getPixelMap(0, 0, w, h);
          let buf: ArrayBuffer;
          try {
            const opt: image.PackingOption = { format: 'image/jpeg', quality: JPEG_QUALITY };
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
    canvas: EuCanvas | SuCanvas, style: string, volumeNo: number, pageNo: number, total: number,
    fonts: CardFonts, measureCtx: OffscreenCanvasRenderingContext2D, book: Genealogy,
    innerXMm: number, contentWMm: number): void {
    // 页眉
    const genText: string = (plan.genFrom > 0 && plan.genTo > 0)
      ? generationLabel(plan.genFrom) + (plan.genFrom === plan.genTo ? '' : '—' + generationLabel(plan.genTo))
      : '';
    const header: string = '世系图' + (genText.length > 0 ? ' · ' + genText : '') + (rootName.length > 0 ? ' · ' + rootName : '');
    page.addTextObject(header, innerXMm * MM_TO_PT, baselineOfMm(6, HEADER_PT),
      pdfTextStyle(HEADER_PT, C_INK2, false));

    // 页首先祖承接：与屏幕页首的浅灰祖先卡一致，PDF 里用一行虚线语义文字表达
    if (plan.contextAncestorNames.length > 0) {
      const names: string[] = [];
      for (let a: number = 0; a < plan.contextAncestorNames.length; a++) {
        names.push(plan.contextAncestorNames[a]);
      }
      const ancestorText: string = '承：' + names.join(' › ');
      const ancestorW: number = contentWMm * MM_TO_PT;
      page.addTextObject(fitText(measureCtx, ancestorText, ancestorW, 6),
        innerXMm * MM_TO_PT, baselineOfMm(9, 6), pdfTextStyle(6, C_ANCESTOR, false));
    }

    // 卡片文字：与画布上的卡片一致，姓名 / 字辈+故 / 世代+UID / 配偶，全部限制在卡片内
    const boxes: Array<EuBox | SuBox> = style === 'su' ? (canvas as SuCanvas).boxes : (canvas as EuCanvas).boxes;
    for (let i: number = 0; i < boxes.length; i++) {
      const b: EuBox | SuBox = boxes[i];
      const maxW: number = Math.max(1, b.w - 2.4) * MM_TO_PT;
      const leftX: number = (innerXMm + b.x + 1) * MM_TO_PT;
      const rightX: number = (innerXMm + b.x + b.w - 1) * MM_TO_PT;
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

    // 分支谱上承：写在页脚最上方一行，翻到任何一页都能看到来源
    if (book.parentBookTitle.length > 0 || book.parentName.length > 0 || book.parentUid.length > 0) {
      const src: string = book.parentBookTitle.length > 0 ? book.parentBookTitle : '母谱';
      const gen: string = book.parentGeneration > 0 ? ('第' + book.parentGeneration.toString() + '世 ') : '';
      const who: string = book.parentName.length > 0 ? book.parentName :
        (book.parentUid.length > 0 ? book.parentUid : '先祖');
      const upW: number = (contentWMm - 10) * MM_TO_PT;
      page.addTextObject(fitText(measureCtx, '承自《' + src + '》' + gen + who, upW, FOOTER_PT),
        innerXMm * MM_TO_PT, baselineOfMm(TRIM_H_MM - 24, FOOTER_PT),
        pdfTextStyle(FOOTER_PT, C_FOOT, false));
    }

    // 页脚兄弟分支软链接：屏幕页脚的「旁支 → 第 N 页」在 PDF 中落成可检索文本
    if (plan.siblingLinks.length > 0) {
      const links: string[] = [];
      for (let s: number = 0; s < plan.siblingLinks.length; s++) {
        links.push('旁支 ' + plan.siblingLinks[s].relation + ' → 第' +
          plan.siblingLinks[s].page.toString() + '页');
      }
      const linkW: number = (contentWMm - 10) * MM_TO_PT;
      page.addTextObject(fitText(measureCtx, links.join('　'), linkW, FOOTER_PT),
        innerXMm * MM_TO_PT,
        baselineOfMm(TRIM_H_MM - 19, FOOTER_PT), pdfTextStyle(FOOTER_PT, C_FOOT, false));
    }

    // 页脚接续文案：单独一行（距底 12mm），给下方页码留出位置
    if (plan.footerText.length > 0) {
      const footW: number = (contentWMm - 10) * MM_TO_PT;
      page.addTextObject(fitText(measureCtx, plan.footerText, footW, FOOTER_PT),
        innerXMm * MM_TO_PT,
        baselineOfMm(TRIM_H_MM - 12, FOOTER_PT), pdfTextStyle(FOOTER_PT, C_FOOT, false));
    }

    // 页码：居中放在页脚下一行（距底 6mm），与接续文案不再同一基线
    // 分卷后必须标出「第几卷第几页」，否则用户不知道当前文件在整套谱中的位置
    const footer: string = '第 ' + volumeNo.toString() + ' 卷 · 第 ' + pageNo.toString() +
      ' 页 / 共 ' + total.toString() + ' 页';
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

