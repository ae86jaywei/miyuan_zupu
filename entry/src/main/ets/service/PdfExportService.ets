import { pdfService } from '@kit.PDFKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Person, childStatusLabel } from '../model/Person';
import { Genealogy } from '../model/Genealogy';
import { GenealogyService } from './GenealogyService';
import { generationLabel } from '../model/Enums';
import { parseYear } from '../util/DateUtil';

/**
 * 族谱 PDF 导出服务（端侧原生渲染）。
 *
 * 链路：OffscreenCanvas 离屏绘制（A4 尺寸，2 倍采样）
 *      → getImageData → image.createPixelMap → packToFile(JPEG)
 *      → pdfService 逐页 addImageObject → saveDocument
 *
 * 页面：A4 竖版 595.28 × 841.89 pt；正文区左右各 56pt 边距。
 */

// ─── 页面常量（pt） ────────────────────────────────────────
const PAGE_W: number = 595.28;
const PAGE_H: number = 841.89;
const MARGIN_LR: number = 56;
const MARGIN_TOP: number = 64;
const MARGIN_BOTTOM: number = 52;
const CONTENT_W: number = PAGE_W - MARGIN_LR * 2;
const CONTENT_H: number = PAGE_H - MARGIN_TOP - MARGIN_BOTTOM;

// ─── 画布常量（px = pt × S 超采样） ────────────────────────
const S: number = 2;
const CANVAS_W: number = 1191;
const CANVAS_H: number = 1684;
const JPEG_QUALITY: number = 92;

// ─── 颜色（打印固定浅色） ─────────────────────────────────
const C_INK: string = '#1a1a1a';
const C_INK2: string = '#444444';
const C_INK3: string = '#888888';
const C_GOLD: string = '#9c7c2e';
const C_FEMALE: string = '#a0527a';
const C_LINE: string = '#cccccc';
const C_BG: string = '#ffffff';

// ─── 导出选项与进度 ────────────────────────────────────────
export interface PdfExportOptions {
  includeCover: boolean;
}

export interface PdfExportProgress {
  current: number;
  total: number;
  message: string;
}

// ─── 排版中间结构 ─────────────────────────────────────────
interface TextLine {
  text: string;
  font: number;   // pt
  lineH: number;  // pt
  color: string;
  bold: boolean;
  indent: number; // pt，左缩进
  center: boolean;
}

/** 行高：字号 × 1.75（中文留白） */
function lineHOf(font: number): number {
  return Math.round(font * 1.75 * 10) / 10;
}

function spacerLine(): TextLine {
  return { text: ' ', font: 10, lineH: 16, color: C_BG, bold: false, indent: 0, center: false };
}

function bigSpacerLine(): TextLine {
  return { text: ' ', font: 20, lineH: 34, color: C_BG, bold: false, indent: 0, center: false };
}

function pushAll(dst: TextLine[], src: TextLine[]): void {
  for (let i: number = 0; i < src.length; i++) {
    dst.push(src[i]);
  }
}

/** 中文环境按字符宽度逐字断行（依赖 ctx.measureText 实测宽度） */
function wrapLines(ctx: OffscreenCanvasRenderingContext2D, text: string, font: number,
  indent: number, color: string): TextLine[] {
  const out: TextLine[] = [];
  const maxW: number = (CONTENT_W - indent) * S;
  ctx.save();
  ctx.font = (font * S).toString() + 'px sans-serif';
  const paras: string[] = text.split('\n');
  for (let pi: number = 0; pi < paras.length; pi++) {
    const para: string = paras[pi];
    let cur: string = '';
    for (let i: number = 0; i < para.length; i++) {
      const ch: string = para.charAt(i);
      if (ch === ' ') {
        cur = cur + ch;
        continue;
      }
      const test: string = cur + ch;
      if (cur.length > 0 && ctx.measureText(test).width > maxW) {
        out.push({ text: cur, font: font, lineH: lineHOf(font), color: color, bold: false, indent: indent, center: false });
        cur = ch;
      } else {
        cur = test;
      }
    }
    out.push({ text: cur.length > 0 ? cur : ' ', font: font, lineH: lineHOf(font), color: color, bold: false, indent: indent, center: false });
  }
  ctx.restore();
  return out;
}

function todayStr(): string {
  const d: Date = new Date();
  return d.getFullYear().toString() + '年' + (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
}

// ─── 内容构建 ─────────────────────────────────────────────

/** 单个世代的条目数 */
function countOfGeneration(people: Person[], gen: number): number {
  let n: number = 0;
  people.forEach((p: Person): void => {
    if (p.generation === gen) {
      n++;
    }
  });
  return n;
}

/** 一个人物的牒记条目（与 Markdown 谱文字段对齐） */
function personEntryLines(ctx: OffscreenCanvasRenderingContext2D, p: Person,
  svc: GenealogyService): TextLine[] {
  const lines: TextLine[] = [];
  let head: string = p.name + '（' + generationLabel(p.generation) + '）';
  if (p.generationChar.length > 0) {
    head += '，字派“' + p.generationChar + '”';
  }
  lines.push({
    text: head, font: 12.5, lineH: 23,
    color: p.gender === '女' ? C_FEMALE : C_INK, bold: true, indent: 0, center: false
  });
  const sp: string = svc.spouseTextOf(p.uid);
  if (sp.length > 0) {
    lines.push({ text: '配偶：' + sp, font: 10.5, lineH: 19, color: C_FEMALE, bold: false, indent: 10, center: false });
  }
  if (p.alias.length > 0) {
    lines.push({ text: '曾用名/小名：' + p.alias, font: 10.5, lineH: 19, color: C_INK2, bold: false, indent: 10, center: false });
  }
  const facts: string[] = [];
  const by: number = parseYear(p.birthDate);
  const dy: number = parseYear(p.deathDate);
  if (by > 0) {
    facts.push('生于' + by + '年');
  }
  if (dy > 0) {
    facts.push('卒于' + dy + '年');
  }
  if (p.lifeStatus.length > 0) {
    facts.push(p.lifeStatus);
  }
  if (p.childStatus.length > 0 && p.childStatus !== '未记') {
    facts.push(childStatusLabel(p.childStatus, p.gender));
  }
  if (p.birthPlace.length > 0) {
    facts.push('籍' + p.birthPlace);
  }
  if (p.residence.length > 0) {
    facts.push('居' + p.residence);
  }
  if (p.rank.length > 0) {
    facts.push(p.rank);
  }
  if (p.education.length > 0) {
    facts.push(p.education);
  }
  if (p.occupation.length > 0) {
    facts.push(p.occupation);
  }
  if (p.adoption.length > 0) {
    facts.push(p.adoption);
  }
  if (facts.length > 0) {
    lines.push({ text: facts.join(' · '), font: 10.5, lineH: 18, color: C_INK2, bold: false, indent: 10, center: false });
  }
  if (p.graveInfo.length > 0) {
    pushAll(lines, wrapLines(ctx, '墓葬：' + p.graveInfo, 10.5, 10, C_INK2));
  }
  if (p.biography.length > 0) {
    pushAll(lines, wrapLines(ctx, p.biography, 11, 10, C_INK));
  }
  lines.push({ text: ' ', font: 8, lineH: 12, color: C_BG, bold: false, indent: 0, center: false });
  return lines;
}

/** 世系条目：世代分隔头 + 逐人条目（按世代、UID 排序） */
function buildGenealogyEntries(ctx: OffscreenCanvasRenderingContext2D, people: Person[],
  svc: GenealogyService): TextLine[][] {
  const sorted: Person[] = people.slice().sort((a: Person, b: Person): number => {
    if (a.generation !== b.generation) {
      return a.generation - b.generation;
    }
    return a.uid.localeCompare(b.uid);
  });
  const entries: TextLine[][] = [];
  let lastGen: number = -1;
  for (let i: number = 0; i < sorted.length; i++) {
    const p: Person = sorted[i];
    if (p.generation !== lastGen) {
      lastGen = p.generation;
      entries.push([{
        text: generationLabel(p.generation) + '（' + countOfGeneration(people, p.generation).toString() + '人）',
        font: 14, lineH: 30, color: C_GOLD, bold: true, indent: 0, center: false
      }]);
    }
    entries.push(personEntryLines(ctx, p, svc));
  }
  return entries;
}

/** 封面 */
function buildCover(book: Genealogy, count: number): TextLine[] {
  const lines: TextLine[] = [];
  for (let i: number = 0; i < 5; i++) {
    lines.push(bigSpacerLine());
  }
  lines.push({ text: book.title, font: 30, lineH: 46, color: C_GOLD, bold: true, indent: 0, center: true });
  lines.push(bigSpacerLine());
  if (book.hallName.length > 0 || book.junwang.length > 0) {
    lines.push({ text: book.hallName + ' · ' + book.junwang, font: 13, lineH: 22, color: C_INK2, bold: false, indent: 0, center: true });
  }
  if (book.ancestorName.length > 0) {
    lines.push({ text: '始迁祖：' + book.ancestorName, font: 13, lineH: 22, color: C_INK2, bold: false, indent: 0, center: true });
  }
  if (book.generationPoem.trim().length > 0) {
    lines.push(bigSpacerLine());
    const poem: string[] = [];
    book.generationPoem.split(' ').forEach((t: string): void => {
      if (t.trim().length > 0) {
        poem.push(t.trim());
      }
    });
    for (let i: number = 0; i < poem.length; i += 8) {
      const seg: string[] = poem.slice(i, i + 8);
      lines.push({ text: seg.join('  '), font: 12, lineH: 24, color: C_INK2, bold: false, indent: 0, center: true });
    }
  }
  lines.push(bigSpacerLine(), bigSpacerLine(), bigSpacerLine());
  lines.push({ text: '全谱共 ' + count.toString() + ' 人', font: 12, lineH: 20, color: C_INK, bold: false, indent: 0, center: true });
  lines.push({ text: '修于 ' + todayStr(), font: 11, lineH: 18, color: C_INK3, bold: false, indent: 0, center: true });
  return lines;
}

/** 谱序 + 凡例（无内容时返回空数组，不占页） */
function buildPreface(ctx: OffscreenCanvasRenderingContext2D, book: Genealogy): TextLine[] {
  const lines: TextLine[] = [];
  let has: boolean = false;
  if (book.preface.trim().length > 0) {
    lines.push({ text: '谱 序', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(ctx, book.preface, 12, 0, C_INK));
    has = true;
  }
  if (book.editingNotes.trim().length > 0) {
    if (has) {
      lines.push(spacerLine());
    }
    lines.push({ text: '凡 例', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(ctx, book.editingNotes, 12, 0, C_INK));
  }
  return lines;
}

/** 家训 + 落款 */
function buildBack(ctx: OffscreenCanvasRenderingContext2D, book: Genealogy): TextLine[] {
  const lines: TextLine[] = [];
  if (book.familyRules.trim().length > 0) {
    lines.push({ text: '家 训', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(ctx, book.familyRules, 12, 0, C_INK));
  }
  lines.push(bigSpacerLine(), bigSpacerLine());
  lines.push({
    text: book.surname + '氏家族 修于 ' + todayStr(),
    font: 11, lineH: 19, color: C_INK3, bold: false, indent: 0, center: true
  });
  return lines;
}

// ─── 分页与绘制 ───────────────────────────────────────────

interface PageSpec {
  lines: TextLine[];
  chapter: string;
}

/**
 * 流式分页：把「世代分隔头 + 条目」按自然断点切到 A4 页内。
 * 条目整体不拆页（一人一条不跨页）。
 */
function paginateEntries(ctx: OffscreenCanvasRenderingContext2D,
  entries: TextLine[][]): PageSpec[] {
  const pages: PageSpec[] = [];
  let cur: TextLine[] = [];
  let used: number = 0;
  const keepHead: number = 36; // 顶部保留页眉区
  for (let i: number = 0; i < entries.length; i++) {
    const block: TextLine[] = entries[i];
    let bh: number = 0;
    for (let j: number = 0; j < block.length; j++) {
      bh += block[j].lineH;
    }
    const need: number = (used === 0 ? keepHead : 8) + bh;
    if (used + need > CONTENT_H && cur.length > 0) {
      pages.push({ lines: cur, chapter: '世 系' });
      cur = [];
      used = 0;
    }
    pushAll(cur, block);
    used += bh;
  }
  if (cur.length > 0) {
    pages.push({ lines: cur, chapter: '世 系' });
  }
  return pages;
}

/**
 * 普通段落分页（封面/谱序/家训）。
 */
function paginateLines(ctx: OffscreenCanvasRenderingContext2D,
  lines: TextLine[], chapter: string, keepHead: number): PageSpec[] {
  if (lines.length === 0) {
    return [];
  }
  const pages: PageSpec[] = [];
  let cur: TextLine[] = [];
  let used: number = 0;
  for (let i: number = 0; i < lines.length; i++) {
    const ln: TextLine = lines[i];
    if (used + ln.lineH > CONTENT_H && cur.length > 0) {
      pages.push({ lines: cur, chapter: chapter });
      cur = [];
      used = keepHead;
    }
    cur.push(ln);
    used += ln.lineH;
  }
  if (cur.length > 0) {
    pages.push({ lines: cur, chapter: chapter });
  }
  return pages;
}

/** 绘制一行文本 */
function drawLine(ctx: OffscreenCanvasRenderingContext2D, ln: TextLine, yPt: number): void {
  ctx.fillStyle = ln.color;
  ctx.font = ln.bold ? 'bold ' + (ln.font * S).toString() + 'px sans-serif' : (ln.font * S).toString() + 'px sans-serif';
  let x: number = (MARGIN_LR + ln.indent) * S;
  if (ln.center) {
    const w: number = ctx.measureText(ln.text).width;
    x = (PAGE_W / 2) * S - w / 2;
  }
  ctx.fillText(ln.text, x, yPt * S);
}

/** 绘制整页：白底 → 页眉（封面除外）→ 行 → 页脚页码 */
function drawPage(ctx: OffscreenCanvasRenderingContext2D, spec: PageSpec,
  pageNo: number, total: number, isCover: boolean): void {
  ctx.fillStyle = C_BG;
  ctx.fillRect(0, 0, CANVAS_W, CANVAS_H);
  let y: number = isCover ? 0 : MARGIN_TOP;
  if (!isCover && spec.chapter.length > 0) {
    // 页眉：谱名左、章节右、分隔线
    ctx.fillStyle = C_INK3;
    ctx.font = (9 * S).toString() + 'px sans-serif';
    const cw: number = ctx.measureText(spec.chapter).width;
    ctx.fillText(spec.chapter, (PAGE_W - MARGIN_LR) * S - cw, (MARGIN_TOP - 24) * S);
    ctx.strokeStyle = C_LINE;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(MARGIN_LR * S, MARGIN_TOP * S - 12);
    ctx.lineTo((PAGE_W - MARGIN_LR) * S, MARGIN_TOP * S - 12);
    ctx.stroke();
  }
  for (let i: number = 0; i < spec.lines.length; i++) {
    const ln: TextLine = spec.lines[i];
    drawLine(ctx, ln, y + ln.lineH / 2);
    y += ln.lineH;
  }
  if (!isCover) {
    ctx.fillStyle = C_INK3;
    ctx.font = (9 * S).toString() + 'px sans-serif';
    const footer: string = pageNo.toString() + ' / ' + total.toString();
    const fw: number = ctx.measureText(footer).width;
    ctx.fillText(footer, (PAGE_W - MARGIN_LR) * S - fw, (PAGE_H - MARGIN_BOTTOM / 2) * S);
    // 页脚分隔线
    ctx.strokeStyle = C_LINE;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(MARGIN_LR * S, (PAGE_H - MARGIN_BOTTOM + 8) * S);
    ctx.lineTo((PAGE_W - MARGIN_LR) * S, (PAGE_H - MARGIN_BOTTOM + 8) * S);
    ctx.stroke();
  }
}

/** 整页 → JPEG 文件 */
async function renderPageToJpeg(spec: PageSpec, pageNo: number, total: number,
  isCover: boolean, outPath: string): Promise<void> {
  const canvas: OffscreenCanvas = new OffscreenCanvas(CANVAS_W, CANVAS_H);
  const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d');
  drawPage(ctx, spec, pageNo, total, isCover);
  const data: ImageData = ctx.getImageData(0, 0, CANVAS_W, CANVAS_H);
  const buf: ArrayBuffer = data.data.slice().buffer;
  const opts: image.InitializationOptions = {
    size: { width: CANVAS_W, height: CANVAS_H },
    srcPixelFormat: image.PixelMapFormat.RGBA_8888,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: false
  };
  const pm: image.PixelMap = await image.createPixelMap(buf, opts);
  const file: fileIo.File = fileIo.openSync(outPath,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    await packer.packToFile(pm, file.fd, { format: 'image/jpeg', quality: JPEG_QUALITY });
  } finally {
    packer.release();
    pm.release();
    fileIo.closeSync(file);
  }
}

// ─── 主服务 ───────────────────────────────────────────────

/**
 * 族谱 PDF 导出主服务。
 */
export class PdfExportService {

  /**
   * 导出整本族谱为 PDF，返回沙箱文件路径。
   */
  static async exportPdf(
    context: common.UIAbilityContext,
    people: Person[],
    book: Genealogy,
    options: PdfExportOptions,
    onProgress?: (p: PdfExportProgress) => void
  ): Promise<string> {
    if (people.length === 0) {
      throw new Error('没有可导出的人物数据');
    }

    // 1. 输出目录
    const outDir: string = context.filesDir + '/pdf_export';
    if (!fileIo.accessSync(outDir)) {
      fileIo.mkdirSync(outDir);
    }
    const imgDir: string = outDir + '/pages';
    if (!fileIo.accessSync(imgDir)) {
      fileIo.mkdirSync(imgDir);
    }

    // 2. 排版（需要一个离屏 ctx 做 measureText）
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(CANVAS_W, CANVAS_H);
    const ctx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');
    const svc: GenealogyService = GenealogyService.getInstance();

    const coverPages: PageSpec[] = options.includeCover
      ? paginateLines(ctx, buildCover(book, people.length), '封 面', 0) : [];
    const prefacePages: PageSpec[] = paginateLines(ctx, buildPreface(ctx, book), '谱 序', 36);
    const genealogyPages: PageSpec[] = paginateEntries(ctx, buildGenealogyEntries(ctx, people, svc));
    const backPages: PageSpec[] = paginateLines(ctx, buildBack(ctx, book), '家 训', 36);

    const all: PageSpec[] = [];
    pushAll(all, coverPages);
    pushAll(all, prefacePages);
    pushAll(all, genealogyPages);
    pushAll(all, backPages);
    const total: number = all.length;
    if (total === 0) {
      throw new Error('排版结果为空');
    }

    // 3. 逐页渲染为 JPEG
    const imagePaths: string[] = [];
    for (let i: number = 0; i < total; i++) {
      if (onProgress) {
        onProgress({ current: i + 1, total: total, message: '渲染第 ' + (i + 1) + '/' + total + ' 页' });
      }
      const path: string = imgDir + '/page_' + i.toString().padStart(3, '0') + '.jpg';
      await renderPageToJpeg(all[i], i + 1, total, i < coverPages.length, path);
      imagePaths.push(path);
    }

    // 4. 组装 PDF
    if (onProgress) {
      onProgress({ current: total + 1, total: total + 1, message: '生成 PDF 文件' });
    }
    const d: Date = new Date();
    const stamp: string = d.getFullYear().toString() +
      (d.getMonth() + 1).toString().padStart(2, '0') +
      d.getDate().toString().padStart(2, '0');
    const outPath: string = outDir + '/' + book.title + '_' + stamp + '.pdf';

    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    if (!doc.createDocument(PAGE_W, PAGE_H)) {
      throw new Error('PDF 文档创建失败');
    }
    for (let i: number = 0; i < imagePaths.length; i++) {
      const page: pdfService.PdfPage = doc.insertBlankPage(doc.getPageCount(), PAGE_W, PAGE_H);
      page.addImageObject(imagePaths[i], 0, 0, PAGE_W, PAGE_H);
    }
    const saved: boolean = doc.saveDocument(outPath);
    doc.releaseDocument();
    if (!saved) {
      throw new Error('PDF 保存失败');
    }

    // 5. 清理临时图片
    PdfExportService.cleanup(imgDir);

    if (onProgress) {
      onProgress({ current: total + 1, total: total + 1, message: '完成' });
    }
    return outPath;
  }

  private static cleanup(dir: string): void {
    try {
      const list: string[] = fileIo.listFileSync(dir);
      list.forEach((f: string): void => {
        try {
          fileIo.unlinkSync(dir + '/' + f);
        } catch (_e) {
        }
      });
      fileIo.rmdirSync(dir);
    } catch (_e) {
    }
  }
}
