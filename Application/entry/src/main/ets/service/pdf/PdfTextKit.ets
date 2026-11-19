import { A4_W_PT, A4_H_PT, PDF_INK, PDF_INK_2, PDF_MUTED, PDF_GOLD, PDF_FEMALE, PDF_BG } from './PdfCommon';
import { DieJiNameRange, DIE_SPACE } from '../DieJiText';
import { TextLine, TextRun, charWidth, lineHOf } from './PdfTextCompose';

// ─── 页面常量（pt） ────────────────────────────────────────
export const PAGE_W: number = A4_W_PT;
export const PAGE_H: number = A4_H_PT;
/** 旧 PDFKit 导出路径（exportPdf）使用的固定版心，保留以兼容未调用代码 */
export const MARGIN_LR: number = 56;
export const MARGIN_TOP: number = 64;
export const MARGIN_BOTTOM: number = 52;
export const CONTENT_W: number = PAGE_W - MARGIN_LR * 2;
export const CONTENT_H: number = PAGE_H - MARGIN_TOP - MARGIN_BOTTOM;

// ─── 颜色（打印固定浅色） ─────────────────────────────────
export const C_INK: string = PDF_INK;
export const C_INK2: string = PDF_INK_2;
export const C_INK3: string = PDF_MUTED;
export const C_GOLD: string = PDF_GOLD;
export const C_FEMALE: string = PDF_FEMALE;
export const C_BG: string = PDF_BG;

/**
 * 牒记版标点：现代横排圆括号保持（ ）、书名号《》→『』；
 * 仿古竖排圆括号（ ）→﹇﹈、书名号《》→﹃﹄。
 */
export function replaceParens(text: string, classic: boolean = false): string {
  // 现代横排：圆括号保持（ ），书名号《》→『』
  if (!classic) {
    return text.split('《').join('『').split('》').join('』');
  }
  // 仿古竖排：圆括号（ ）→﹇﹈，书名号《》→﹃﹄
  return text.split('（').join('﹇').split('）').join('﹈')
    .split('《').join('﹃').split('》').join('﹄');
}

export function spacerLine(): TextLine {
  return { text: ' ', font: 10, lineH: 16, color: C_BG, bold: false, indent: 0, center: false };
}

export function bigSpacerLine(): TextLine {
  return { text: ' ', font: 20, lineH: 34, color: C_BG, bold: false, indent: 0, center: false, columnGap: true };
}

export function pushAll(dst: TextLine[], src: TextLine[]): void {
  for (let i: number = 0; i < src.length; i++) {
    dst.push(src[i]);
  }
}

/** 页内容结构（封面/谱序/正文共用） */
export interface PageSpec {
  lines: TextLine[];
  chapter: string;
  /** 页内分栏：0/1/2；缺省 0（整页一栏） */
  column?: number;
  /** 单栏宽度（pt）；缺省用整页版心宽 */
  columnW?: number;
  /** 页号（1 起，含前置页偏移）；exportRawTextPdf 统一分配 */
  pageNo?: number;
}

export function pushAllPages(dst: PageSpec[], src: PageSpec[]): void {
  for (let i: number = 0; i < src.length; i++) {
    dst.push(src[i]);
  }
}

/** 中文按字符宽度断行（不逐字 measureText，避免数万人大谱卡死主线程） */
export function wrapLines(text: string, font: number, indent: number, color: string,
  maxW: number = CONTENT_W): TextLine[] {
  const out: TextLine[] = [];
  const maxChars: number = Math.max(1, Math.floor((maxW - indent) / font * 0.98));
  const paras: string[] = text.split('\n');
  for (let pi: number = 0; pi < paras.length; pi++) {
    const para: string = paras[pi];
    if (para.length === 0) {
      out.push({ text: ' ', font: font, lineH: lineHOf(font), color: color, bold: false, indent: indent, center: false });
      continue;
    }
    let start: number = 0;
    while (start < para.length) {
      const end: number = Math.min(start + maxChars, para.length);
      out.push({
        text: para.substring(start, end),
        font: font, lineH: lineHOf(font), color: color, bold: false, indent: indent, center: false
      });
      start = end;
    }
  }
  return out;
}

/**
 * 混排行：正文 14pt、姓名 18pt 加粗、括号引用 10.5pt 常规。
 * 按字符宽度折行，行内按 runs 记录不同字号片段；只有含姓名/引用的行才带 runs。
 */
export function wrapStyledLines(ctx: OffscreenCanvasRenderingContext2D, text: string,
  nameRanges: DieJiNameRange[], refRanges: DieJiNameRange[],
  baseFont: number, baseColor: string, nameFont: number, nameColor: string,
  refFont: number, refColor: string, indent: number = 0,
  maxW: number = CONTENT_W, hangingIndent: number = 0): TextLine[] {
  const out: TextLine[] = [];
  const lineChars: string[] = [];
  let lineRuns: TextRun[] = [];
  let lineW: number = 0;
  let maxFont: number = baseFont;
  // 首行用 indent，发生折行后改用悬挂缩进，让正文与项目符号后的文字对齐
  let lineIndent: number = indent;
  const flush = (): void => {
    if (lineChars.length === 0) {
      return;
    }
    const onlyBase: boolean = lineRuns.length === 1 && lineRuns[0].font === baseFont &&
      !lineRuns[0].bold;
    const ln: TextLine = {
      text: lineChars.join(''), font: maxFont, lineH: lineHOf(maxFont), color: baseColor,
      bold: false, indent: lineIndent, center: false
    };
    if (!onlyBase) {
      ln.runs = lineRuns.slice();
    }
    out.push(ln);
    lineChars.length = 0;
    lineRuns = [];
    lineW = 0;
    maxFont = baseFont;
    lineIndent = hangingIndent;
  };
  let i: number = 0;
  while (i < text.length) {
    const cp: number = text.codePointAt(i) ?? 0;
    const step: number = cp > 0xffff ? 2 : 1;
    const ch: string = text.substring(i, i + step);
    if (ch === '\n') {
      flush();
      i = i + step;
      continue;
    }
    let inName: boolean = false;
    // relative：亲属姓名只加粗，字号仍用正文四号
    let relative: boolean = false;
    for (let r: number = 0; r < nameRanges.length; r++) {
      if (i >= nameRanges[r].start && i < nameRanges[r].end) {
        inName = true;
        relative = nameRanges[r].relative;
        break;
      }
    }
    let inRef: boolean = false;
    if (!inName) {
      for (let r: number = 0; r < refRanges.length; r++) {
        if (i >= refRanges[r].start && i < refRanges[r].end) {
          inRef = true;
          break;
        }
      }
    }
    // 全角空格断句符排在行首会形成假缩进，直接吞掉
    if (ch === DIE_SPACE && lineChars.length === 0) {
      i = i + step;
      continue;
    }
    const font: number = inName ? (relative ? baseFont : nameFont) : (inRef ? refFont : baseFont);
    const color: string = inName ? (relative ? baseColor : nameColor) : (inRef ? refColor : baseColor);
    const bold: boolean = inName;
    const w: number = charWidth(ctx, ch, font);
    // 留 0.5pt 余量：折行判定是浮点累加，贴边时会压到版心边线与装订口
    if (lineChars.length > 0 && lineW + w > maxW - lineIndent - 0.5) {
      flush();
    }
    lineChars.push(ch);
    const last: TextRun | null = lineRuns.length > 0 ? lineRuns[lineRuns.length - 1] : null;
    if (last !== null && last.font === font && last.color === color && last.bold === bold) {
      last.text = last.text + ch;
    } else {
      const run: TextRun = { text: ch, font: font, color: color, bold: bold };
      lineRuns.push(run);
    }
    lineW = lineW + w;
    if (font > maxFont) {
      maxFont = font;
    }
    i = i + step;
  }
  flush();
  return out;
}

export function todayStr(): string {
  const d: Date = new Date();
  return d.getFullYear().toString() + '年' + (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
}
