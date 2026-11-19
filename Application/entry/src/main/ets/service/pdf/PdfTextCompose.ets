import { Person } from 'common_base';
import { RawPdfFont } from '../RawPdfFont';
import { PdfFontUtil } from '../PdfFontUtil';

// ─── 排版中间结构 ─────────────────────────────────────────
export interface TextRun {
  text: string;
  font: number;   // pt
  color: string;
  bold: boolean;
}

export interface TextLine {
  text: string;
  font: number;   // pt
  lineH: number;  // pt
  color: string;
  bold: boolean;
  indent: number; // pt，左缩进
  center: boolean;
  /** 混排片段：姓名 30pt、正文 12.5pt 时按片段绘制，text 仍保留整行文本用于分页/书签 */
  runs?: TextRun[];
  /** 仿古竖排：该空行在段内占一列空白（封面 spacer）；正文人物间空行不设此值 */
  columnGap?: boolean;
}

/** 行高：字号 × 1.75（中文留白） */
export function lineHOf(font: number): number {
  return Math.round(font * 1.75 * 10) / 10;
}

/**
 * 度量用字体（进程内缓存）。必须与 PDF 嵌入字体同源：
 * 排版推进宽度只有和 PDF /W 字宽表一致，逐字定位的数字/英文才不会叠在一起。
 */
let measureFontCache: RawPdfFont | null = null;

export function measureFont(): RawPdfFont | null {
  if (measureFontCache === null) {
    measureFontCache = PdfFontUtil.rawFont();
  }
  return measureFontCache;
}

/** 全角字符（CJK 汉字、假名、韩文、全角标点）：嵌入字体 advance 就是 1em */
export function isWideChar(cp: number): boolean {
  return (cp >= 0x2e80 && cp <= 0x9fff) || (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xff00 && cp <= 0xff60) || (cp >= 0x20000 && cp <= 0x3ffff);
}

/** 半角字符 advance 缓存：Unicode 码点 → advance/1000 */
const halfWidthRatio: Map<number, number> = new Map<number, number>();

/**
 * 单字宽度（pt）。
 * 不能用 OffscreenCanvas.measureText：本机实测它只返回真实字宽的两成左右，
 * 逐字定位时英文/数字会全部挤在同一点，右对齐的页眉也会被推过装订线。
 * 全角按 1em；半角（数字/字母/标点）查嵌入字体 hmtx，缺字回退 0.5em。
 */
export function charWidth(ctx: OffscreenCanvasRenderingContext2D, ch: string, font: number): number {
  const cp: number = ch.codePointAt(0) ?? 0;
  if (isWideChar(cp)) {
    return font;
  }
  let ratio: number | undefined = halfWidthRatio.get(cp);
  if (ratio === undefined) {
    const f: RawPdfFont | null = measureFont();
    const gid: number = f === null ? 0 : f.gidOf(cp);
    const adv: number = (f !== null && gid > 0) ? f.advance1000(gid) : 0;
    ratio = adv > 0 ? adv / 1000 : 0.5;
    halfWidthRatio.set(cp, ratio);
  }
  return font * ratio;
}

// ─── 族谱结构索引 ─────────────────────────────────────────

/** 房支索引项：用于按房分卷与卷名生成 */
export class BranchInfo {
  branchName: string = '';
  rootUid: string = '';
  rootName: string = '';
}

/** 一个家庭单元：一名本支成员（锚点）+ 其配偶（配偶世代即使录错也跟随锚点） */
export class FamilyUnit {
  generation: number = 0;
  anchorUid: string = '';
  members: Person[] = [];
}

/** 导出用关系索引：一次性建表，避免逐人 filter 全表导致 O(n²) 卡死主线程 */
export class KinshipIndex {
  private byUid: Map<string, Person> = new Map<string, Person>();
  private kids: Map<string, Person[]> = new Map<string, Person[]>();

  constructor(people: Person[]) {
    for (let i: number = 0; i < people.length; i++) {
      this.byUid.set(people[i].uid.trim().toUpperCase(), people[i]);
    }
    for (let i: number = 0; i < people.length; i++) {
      const p: Person = people[i];
      this.link(p.fatherId, p);
      this.link(p.motherId, p);
    }
  }

  private link(parentUid: string, child: Person): void {
    const k: string = parentUid.trim().toUpperCase();
    if (k.length === 0) {
      return;
    }
    const arr: Person[] | undefined = this.kids.get(k);
    if (arr === undefined) {
      this.kids.set(k, [child]);
    } else {
      arr.push(child);
    }
  }

  person(uid: string): Person | null {
    const p: Person | undefined = this.byUid.get(uid.trim().toUpperCase());
    return p === undefined ? null : p;
  }

  childrenOf(uid: string): Person[] {
    const arr: Person[] | undefined = this.kids.get(uid.trim().toUpperCase());
    return arr === undefined ? [] : arr;
  }
}
