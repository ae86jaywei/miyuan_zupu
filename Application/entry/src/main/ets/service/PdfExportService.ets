import { pdfService } from '@kit.PDFKit';
import { Font } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Person, SpouseRelation, childStatusLabel, spouseRelationLabel } from '../model/Person';
import { Genealogy } from '../model/Genealogy';
import { generationLabel } from '../model/Enums';
import { displayDate } from '../util/DateUtil';

/**
 * 族谱 PDF 导出服务（端侧原生排版，矢量文本）。
 *
 * 链路：OffscreenCanvas 仅用于 measureText 断行/居中度量
 *      → pdfService 逐页 insertBlankPage + addTextObject（真实文本对象）
 *      → saveDocument
 *
 * 产出 PDF 的文字可选中、可搜索、可编辑，且为矢量输出，印刷无锯齿、无 300dpi 位图限制。
 * 排版为两遍：第一遍分页确定每人页码，第二遍回填「亲属/子嗣」页码互引。
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

// ─── 度量画布常量（px = pt × S） ──────────────────────────
const S: number = 2;
const CANVAS_W: number = 1191;
const CANVAS_H: number = 1684;

// ─── 颜色（打印固定浅色） ─────────────────────────────────
const C_INK: string = '#1a1a1a';
const C_INK2: string = '#444444';
const C_INK3: string = '#888888';
const C_GOLD: string = '#9c7c2e';
const C_FEMALE: string = '#a0527a';
const C_BG: string = '#ffffff';

// ─── 导出选项与进度 ────────────────────────────────────────
export interface PdfExportOptions {
  includeCover: boolean;
  /** 分卷标题（如「第3卷（第十一世至第十五世）」），不传则为整谱单卷 */
  volumeTitle?: string;
  /** 关系索引数据源：分卷导出时传全量人物，跨卷亲属姓名才显示得出来 */
  kinSource?: Person[];
  /** 导出谱式：die=牒记式（默认），eu=欧式分页，su=苏式分页 */
  style?: string;
  /** 跨卷位置索引：uid →「第2卷358页」，分卷导出时由 prepareCrossRefs 预先算好 */
  crossRef?: Map<string, string>;
}

/** 分卷单元 */
export interface PdfVolume {
  title: string;
  people: Person[];
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

function pushAllPages(dst: PageSpec[], src: PageSpec[]): void {
  for (let i: number = 0; i < src.length; i++) {
    dst.push(src[i]);
  }
}

/** 中文按字符宽度断行（不逐字 measureText，避免数万人大谱卡死主线程） */
function wrapLines(text: string, font: number, indent: number, color: string): TextLine[] {
  const out: TextLine[] = [];
  const maxChars: number = Math.floor((CONTENT_W - indent) / font * 0.98);
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

/** 条目块：uid 用于页码互引（世代分隔头的 uid 为空串） */
interface EntryBlock {
  uid: string;
  lines: TextLine[];
}

/** 分页结果：页内容 + 人物所在页码（1 起，含前置页偏移） */
interface PaginateResult {
  pages: PageSpec[];
  uidPage: Map<string, number>;
}

/** 导出用关系索引：一次性建表，避免逐人 filter 全表导致 O(n²) 卡死主线程 */
class KinshipIndex {
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

/** 跨卷位置：uid →「第2卷358页」。由 prepareCrossRefs 在生成 PDF 前算好并回填 */
let gCrossRef: Map<string, string> | null = null;

/** 关系人标注：姓名（UID·第N页）；第一遍排版用等宽占位页码，保证两遍折行数可比 */
function refText(name: string, uid: string, refs: Map<string, number> | null): string {
  const id: string = uid.trim().toUpperCase();
  let text: string = name + '（' + id;
  if (refs !== null) {
    const n: number | undefined = refs.get(id);
    if (n !== undefined) {
      text += '·第' + n.toString() + '页';
    } else if (gCrossRef !== null) {
      // 分卷导出：本卷 refs 查不到时，用预先算好的跨卷「第N卷M页」
      const cross: string | undefined = gCrossRef.get(id);
      text += cross === undefined ? '·另卷' : '·' + cross;
    } else {
      text += '·另卷';
    }
  } else {
    // 第一遍：占位串不短于真实页码，第二遍折行只会更少，再补空行对齐
    text += '·第00卷0000页';
  }
  return text + '）';
}

/** 配偶文本：名分（含正妻/平妻等层级）+ 姓名（UID·页码） */
function spouseText(idx: KinshipIndex, p: Person, refs: Map<string, number> | null): string {
  const parts: string[] = [];
  for (let i: number = 0; i < p.spouses.length; i++) {
    const r: SpouseRelation = p.spouses[i];
    const rel: string = r.relation.length > 0 ? spouseRelationLabel(r.relation) : '配偶';
    const sp: Person | null = idx.person(r.uid);
    if (sp === null) {
      parts.push(rel + ' ' + r.uid + '（未录入）');
    } else {
      parts.push(rel + ' ' + refText(sp.name, sp.uid, refs));
    }
  }
  return parts.join('、');
}

// ─── 条目字号 ─────────────────────────────────────────────
// PDF 默认 100% 缩放时原字号偏小；姓名加大一档，详情加大到原姓名的字号
const F_NAME: number = 14;
const H_NAME: number = 26;
const F_DETAIL: number = 12.5;
const H_DETAIL: number = 22;

/** 普通详情行（可折行，内容不丢） */
function detailLine(text: string, color: string): TextLine {
  return { text: text, font: F_DETAIL, lineH: H_DETAIL, color: color, bold: false, indent: 10, center: false };
}

/** 补齐行：只占高度，不写文本对象（用于对齐两遍排版的行数） */
function padLine(): TextLine {
  return { text: ' ', font: F_DETAIL, lineH: H_DETAIL, color: C_BG, bold: false, indent: 0, center: false };
}

/** 一个人物的条目：字段与「个人信息」详情页一致 */
function personEntryLines(ctx: OffscreenCanvasRenderingContext2D, p: Person,
  kinIndex: KinshipIndex, refs: Map<string, number> | null): TextLine[] {
  const lines: TextLine[] = [];
  const uid: string = p.uid.trim().toUpperCase();
  let head: string = p.name + '（' + generationLabel(p.generation);
  if (uid.length > 0) {
    head += '，' + uid;
  }
  head += '）';
  if (p.gender === '女') {
    head += '，女';
  }
  if (p.generationChar.length > 0) {
    head += '，字派“' + p.generationChar + '”';
  }
  lines.push({
    text: head, font: F_NAME, lineH: H_NAME,
    color: p.gender === '女' ? C_FEMALE : C_INK, bold: true, indent: 0, center: false
  });
  // 配偶：名分 + 姓名（UID·页码）
  if (p.spouses.length > 0) {
    pushAll(lines, wrapLines('配偶：' + spouseText(kinIndex, p, refs), F_DETAIL, 10, C_FEMALE));
  }
  // 亲属：父/母 + 页码互引
  const kinParts: string[] = [];
  if (p.fatherId.trim().length > 0) {
    const f: Person | null = kinIndex.person(p.fatherId);
    if (f !== null) {
      kinParts.push('父 ' + refText(f.name, f.uid, refs));
    }
  }
  if (p.motherId.trim().length > 0) {
    const m: Person | null = kinIndex.person(p.motherId);
    if (m !== null) {
      kinParts.push('母 ' + refText(m.name, m.uid, refs));
    }
  }
  if (kinParts.length > 0) {
    pushAll(lines, wrapLines('亲属：' + kinParts.join('　'), F_DETAIL, 10, C_INK2));
  }
  // 子嗣：全部列出，一行放不下自动换行
  const kids: Person[] = kinIndex.childrenOf(p.uid);
  if (kids.length > 0) {
    const parts: string[] = [];
    for (let i: number = 0; i < kids.length; i++) {
      parts.push(refText(kids[i].name, kids[i].uid, refs));
    }
    const txt: string = '子嗣：' + parts.join('、') + '（共' + kids.length.toString() + '人）';
    pushAll(lines, wrapLines(txt, F_DETAIL, 10, C_INK2));
  }
  if (p.alias.length > 0) {
    lines.push(detailLine('曾用名/小名：' + p.alias, C_INK2));
  }
  // 身份：性别 / 排行 / 子女身份 / 过继 / 在世状态
  const idParts: string[] = ['性别 ' + p.gender];
  if (p.rank.length > 0) {
    idParts.push('排行 ' + p.rank);
  }
  if (p.childStatus.length > 0 && p.childStatus !== '未记') {
    idParts.push(childStatusLabel(p.childStatus, p.gender));
  }
  if (p.adoption.length > 0) {
    idParts.push('过继/出嗣 ' + p.adoption);
  }
  if (p.lifeStatus.length > 0) {
    idParts.push(p.lifeStatus);
  }
  pushAll(lines, wrapLines('身份：' + idParts.join('　'), F_DETAIL, 10, C_INK2));
  // 生卒：完整日期，保留公历/农历标注
  const life: string[] = [];
  const bd: string = displayDate(p.birthDate, p.birthCalendar);
  const dd: string = displayDate(p.deathDate, p.deathCalendar);
  if (bd.length > 0) {
    life.push('生于 ' + bd);
  }
  if (dd.length > 0) {
    life.push('卒于 ' + dd);
  }
  if (life.length > 0) {
    pushAll(lines, wrapLines(life.join('　'), F_DETAIL, 10, C_INK2));
  }
  // 出生地 / 现居地
  const places: string[] = [];
  if (p.birthPlace.length > 0) {
    places.push('出生地 ' + p.birthPlace);
  }
  if (p.residence.length > 0) {
    places.push('现居 ' + p.residence);
  }
  if (places.length > 0) {
    pushAll(lines, wrapLines(places.join('　'), F_DETAIL, 10, C_INK2));
  }
  // 学历 / 职业
  const career: string[] = [];
  if (p.education.length > 0) {
    career.push('学历/学位 ' + p.education);
  }
  if (p.occupation.length > 0) {
    career.push('职业/职务 ' + p.occupation);
  }
  if (career.length > 0) {
    pushAll(lines, wrapLines(career.join('　'), F_DETAIL, 10, C_INK2));
  }
  // 墓葬（含 GPS 经纬度与海拔）
  const grave: string[] = [];
  if (p.graveInfo.length > 0) {
    grave.push(p.graveInfo);
  }
  if (p.graveLat !== 0) {
    grave.push('GPS 东经 ' + p.graveLng.toFixed(6) + '° 北纬 ' + p.graveLat.toFixed(6)
      + '° 海拔 ' + p.graveAltitude.toFixed(1) + 'm');
  }
  if (grave.length > 0) {
    pushAll(lines, wrapLines('墓葬：' + grave.join('　'), F_DETAIL, 10, C_INK2));
  }
  // 生平简介
  if (p.biography.length > 0) {
    pushAll(lines, wrapLines('生平：' + p.biography, F_DETAIL, 10, C_INK));
  }
  // 联系方式（与 JSON/CSV 导出一致，默认包含）
  const contact: string[] = [];
  if (p.phone.length > 0) {
    contact.push('手机 ' + p.phone);
  }
  if (p.wechat.length > 0) {
    contact.push('微信 ' + p.wechat);
  }
  if (contact.length > 0) {
    pushAll(lines, wrapLines('联系：' + contact.join('　'), F_DETAIL, 10, C_INK2));
  }
  lines.push({ text: ' ', font: 8, lineH: 12, color: C_BG, bold: false, indent: 0, center: false });
  return lines;
}

/**
 * 排序：世代升序；同一世代内把夫妻排在一起。
 * 配偶在数据里是独立人物条目，按 UID 排序会把「夫在第2页、妻排到第100页」，
 * 这里以夫（被配偶引用的那一方）为锚点，先出夫条目，紧接着把它在本卷内的配偶条目全部输出。
 */
function orderPeopleByFamily(people: Person[]): Person[] {
  const sorted: Person[] = people.slice().sort((a: Person, b: Person): number => {
    if (a.generation !== b.generation) {
      return a.generation - b.generation;
    }
    return a.uid.localeCompare(b.uid);
  });
  const out: Person[] = [];
  let start: number = 0;
  while (start < sorted.length) {
    const gen: number = sorted[start].generation;
    let end: number = start;
    while (end < sorted.length && sorted[end].generation === gen) {
      end++;
    }
    const group: Person[] = sorted.slice(start, end);
    const byUid: Map<string, Person> = new Map<string, Person>();
    for (let i: number = 0; i < group.length; i++) {
      byUid.set(group[i].uid.trim().toUpperCase(), group[i]);
    }
    const anchorOf: Map<string, string> = new Map<string, string>();
    for (let i: number = 0; i < group.length; i++) {
      const p: Person = group[i];
      for (let j: number = 0; j < p.spouses.length; j++) {
        const spUid: string = p.spouses[j].uid.trim().toUpperCase();
        if (byUid.has(spUid) && !anchorOf.has(spUid)) {
          anchorOf.set(spUid, p.uid.trim().toUpperCase());
        }
      }
    }
    const emitted: Set<string> = new Set<string>();
    const emitOne = (p: Person): void => {
      const uid: string = p.uid.trim().toUpperCase();
      if (emitted.has(uid)) {
        return;
      }
      emitted.add(uid);
      out.push(p);
      for (let k: number = 0; k < p.spouses.length; k++) {
        const sp: Person | undefined = byUid.get(p.spouses[k].uid.trim().toUpperCase());
        if (sp !== undefined) {
          const spUid: string = sp.uid.trim().toUpperCase();
          if (!emitted.has(spUid) && anchorOf.get(spUid) === uid) {
            emitted.add(spUid);
            out.push(sp);
          }
        }
      }
    };
    for (let i: number = 0; i < group.length; i++) {
      const p: Person = group[i];
      const uid: string = p.uid.trim().toUpperCase();
      const anchor: string | undefined = anchorOf.get(uid);
      // 被配偶引用的一方先等锚点（夫）输出，避免妻先出现、夫被甩到后面
      if (anchor !== undefined && anchor !== uid && byUid.has(anchor) && !emitted.has(anchor)) {
        continue;
      }
      emitOne(p);
    }
    // 锚点不在本卷（跨卷分家）时，配偶仍要输出，不能漏人
    for (let i: number = 0; i < group.length; i++) {
      emitOne(group[i]);
    }
    start = end;
  }
  return out;
}

/** 世系条目：世代分隔头 + 逐人条目（同世代夫妻相邻） */
function buildGenealogyEntries(ctx: OffscreenCanvasRenderingContext2D, people: Person[],
  kinIndex: KinshipIndex, refs: Map<string, number> | null): EntryBlock[] {
  const sorted: Person[] = orderPeopleByFamily(people);
  const entries: EntryBlock[] = [];
  let lastGen: number = -1;
  for (let i: number = 0; i < sorted.length; i++) {
    const p: Person = sorted[i];
    if (p.generation !== lastGen) {
      lastGen = p.generation;
      entries.push({
        uid: '',
        lines: [{
          text: generationLabel(p.generation) + '（' + countOfGeneration(people, p.generation).toString() + '人）',
          font: 16, lineH: 32, color: C_GOLD, bold: true, indent: 0, center: false
        }]
      });
    }
    entries.push({ uid: p.uid.trim().toUpperCase(), lines: personEntryLines(ctx, p, kinIndex, refs) });
  }
  return entries;
}

/** 封面 */
function buildCover(book: Genealogy, count: number, volumeTitle: string): TextLine[] {
  const lines: TextLine[] = [];
  for (let i: number = 0; i < 5; i++) {
    lines.push(bigSpacerLine());
  }
  lines.push({ text: book.title, font: 30, lineH: 46, color: C_GOLD, bold: true, indent: 0, center: true });
  if (volumeTitle.length > 0) {
    lines.push({ text: volumeTitle, font: 16, lineH: 30, color: C_INK, bold: true, indent: 0, center: true });
  }
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
  lines.push({ text: (volumeTitle.length > 0 ? '本卷共 ' : '全谱共 ') + count.toString() + ' 人',
    font: 12, lineH: 20, color: C_INK, bold: false, indent: 0, center: true });
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
    pushAll(lines, wrapLines(book.preface, 12, 0, C_INK));
    has = true;
  }
  if (book.editingNotes.trim().length > 0) {
    if (has) {
      lines.push(spacerLine());
    }
    lines.push({ text: '凡 例', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(book.editingNotes, 12, 0, C_INK));
  }
  return lines;
}

/** 家训 + 落款 */
function buildBack(ctx: OffscreenCanvasRenderingContext2D, book: Genealogy): TextLine[] {
  const lines: TextLine[] = [];
  if (book.familyRules.trim().length > 0) {
    lines.push({ text: '家 训', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(book.familyRules, 12, 0, C_INK));
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
 * 条目整体不拆页（一人一条不跨页），同时记录每人的最终页码。
 */
function paginateEntries(entries: EntryBlock[], pageOffset: number): PaginateResult {
  const pages: PageSpec[] = [];
  const uidPage: Map<string, number> = new Map<string, number>();
  let cur: TextLine[] = [];
  let used: number = 0;
  const keepHead: number = 36; // 顶部保留页眉区
  for (let i: number = 0; i < entries.length; i++) {
    const block: TextLine[] = entries[i].lines;
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
    if (entries[i].uid.length > 0) {
      uidPage.set(entries[i].uid, pageOffset + pages.length + 1);
    }
    pushAll(cur, block);
    used += bh;
  }
  if (cur.length > 0) {
    pages.push({ lines: cur, chapter: '世 系' });
  }
  return { pages: pages, uidPage: uidPage };
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

/** #RRGGBB → PDF 颜色数值 */
function hexToNum(hex: string): number {
  return parseInt(hex.replace('#', ''), 16);
}

/** 系统字体信息（进程内缓存，避免逐行取字体路径） */
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
function textStyle(size: number, color: string, bold: boolean): pdfService.TextStyle {
  return {
    textSize: size,
    textColor: hexToNum(color),
    isBold: bold,
    fontInfo: pdfFontInfo()
  };
}

/** 用离屏 ctx 量出文本在页面上的宽度（pt） */
function measurePt(ctx: OffscreenCanvasRenderingContext2D, text: string, font: number): number {
  ctx.save();
  ctx.font = (font * S).toString() + 'px sans-serif';
  const w: number = ctx.measureText(text).width / S;
  ctx.restore();
  return w;
}

/**
 * 把「距页面顶部的行顶 y」换算成 PDF 文本基线。
 * PDF 坐标原点在页面左下角、y 向上，与本文自上而下的排版坐标相反，
 * 不做换算会导致行序上下颠倒、内容从底部往上堆并溢出页顶。
 */
function baselineOf(yTop: number, font: number): number {
  return PAGE_H - yTop - font;
}

/**
 * 绘制一行：直接写入 PDF 文本对象（矢量文字，可选中、可编辑、印刷无损）。
 */
function addTextLine(ctx: OffscreenCanvasRenderingContext2D, page: pdfService.PdfPage,
  ln: TextLine, yTop: number): void {
  if (ln.text.trim().length === 0) {
    return; // 空白占位行不写对象，保持 PDF 干净
  }
  const style: pdfService.TextStyle = textStyle(ln.font, ln.color, ln.bold);
  let x: number = MARGIN_LR + ln.indent;
  if (ln.center) {
    x = PAGE_W / 2 - measurePt(ctx, ln.text, ln.font) / 2;
  }
  page.addTextObject(ln.text, x, baselineOf(yTop, ln.font), style);
}

/**
 * 让出主线程一个时间片。
 * 必须给非零延时：0ms 定时器会被连续排满，事件队列里没有空档，
 * 系统看门狗与输入事件仍然得不到执行，最终仍会报 THREAD_BLOCK_6S。
 */
function yieldToUi(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(() => {
      resolve();
    }, 16);
  });
}

/** 新增一页并把整页文本写入（封面不排页眉页脚） */
function drawPageToPdf(ctx: OffscreenCanvasRenderingContext2D, doc: pdfService.PdfDocument,
  spec: PageSpec, pageNo: number, total: number, isCover: boolean): void {
  const page: pdfService.PdfPage = doc.insertBlankPage(doc.getPageCount(), PAGE_W, PAGE_H);
  let y: number = isCover ? 0 : MARGIN_TOP;
  if (!isCover && spec.chapter.length > 0) {
    const style: pdfService.TextStyle = textStyle(9, C_INK3, false);
    page.addTextObject(spec.chapter,
      PAGE_W - MARGIN_LR - measurePt(ctx, spec.chapter, 9), baselineOf(MARGIN_TOP - 16, 9), style);
  }
  for (let i: number = 0; i < spec.lines.length; i++) {
    const ln: TextLine = spec.lines[i];
    addTextLine(ctx, page, ln, y);
    y += ln.lineH;
  }
  if (!isCover) {
    const footer: string = '第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页';
    const style: pdfService.TextStyle = textStyle(9, C_INK3, false);
    page.addTextObject(footer,
      PAGE_W - MARGIN_LR - measurePt(ctx, footer, 9), MARGIN_BOTTOM / 2, style);
  }
}

// ─── 主服务 ───────────────────────────────────────────────

/**
 * 族谱 PDF 导出主服务。
 */
export class PdfExportService {

  /**
   * 分卷规划：按世代顺序聚合，单卷人数不超过 maxPerVolume；
   * 单个世代本身超限时按人数硬切（同世代可分多卷）。
   * 返回空数组表示无需分卷（人数未超限）。
   */
  static planVolumes(people: Person[], maxPerVolume: number): PdfVolume[] {
    if (people.length <= maxPerVolume || maxPerVolume <= 0) {
      return [];
    }
    const sorted: Person[] = people.slice().sort((a: Person, b: Person): number => {
      if (a.generation !== b.generation) {
        return a.generation - b.generation;
      }
      return a.uid.localeCompare(b.uid);
    });
    const volumes: PdfVolume[] = [];
    let start: number = 0;
    while (start < sorted.length) {
      let end: number = start;
      while (end < sorted.length) {
        const g: number = sorted[end].generation;
        let k: number = end;
        while (k < sorted.length && sorted[k].generation === g) {
          k++;
        }
        if (end === start && k - start > maxPerVolume) {
          end = start + maxPerVolume; // 首个世代自身就超限，只能按人数硬切
          break;
        }
        if (end > start && k - start > maxPerVolume) {
          break; // 再加一个完整世代就超限，收卷
        }
        end = k;
        if (end - start >= maxPerVolume || k >= sorted.length) {
          break;
        }
      }
      const gStart: number = sorted[start].generation;
      const gEnd: number = sorted[end - 1].generation;
      const seq: string = (volumes.length + 1).toString();
      const title: string = gStart === gEnd
        ? '第' + seq + '卷（' + generationLabel(gStart) + '）'
        : '第' + seq + '卷（' + generationLabel(gStart) + '至' + generationLabel(gEnd) + '）';
      volumes.push({ title: title, people: sorted.slice(start, end) });
      start = end;
    }
    return volumes;
  }

  /**
   * 生成跨卷位置索引：先把每一卷排一遍版，得到 uid →「第2卷358页」。
   * 必须在导出 PDF 之前调用，导出的第二遍才能把「父xxx(Fxxx·第2卷358页)」写实。
   * 每一卷只算页位不写 PDF，所用占位串与正式导出第一遍一致，页数稳定。
   */
  static prepareCrossRefs(
    people: Person[],
    book: Genealogy,
    jobs: PdfVolume[],
    includeCover: boolean
  ): Map<string, string> {
    const out: Map<string, string> = new Map<string, string>();
    if (jobs.length === 0) {
      return out;
    }
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(CANVAS_W, CANVAS_H);
    const ctx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');
    const kinIndex: KinshipIndex = new KinshipIndex(people);
    for (let i: number = 0; i < jobs.length; i++) {
      const vol: PdfVolume = jobs[i];
      const coverPages: PageSpec[] = includeCover
        ? paginateLines(ctx, buildCover(book, vol.people.length, vol.title), '封 面', 0) : [];
      const prefacePages: PageSpec[] = paginateLines(ctx, buildPreface(ctx, book), '谱 序', 36);
      const offset: number = coverPages.length + prefacePages.length;
      const entries: EntryBlock[] = buildGenealogyEntries(ctx, vol.people, kinIndex, null);
      const pg: PaginateResult = paginateEntries(entries, offset);
      const multi: boolean = jobs.length > 1;
      pg.uidPage.forEach((pageNo: number, uid: string): void => {
        out.set(uid, multi
          ? '第' + (i + 1).toString() + '卷' + pageNo.toString() + '页'
          : '第' + pageNo.toString() + '页');
      });
    }
    return out;
  }

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

    // 2. 排版（需要一个离屏 ctx 做 measureText）
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(CANVAS_W, CANVAS_H);
    const ctx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');
    const ts: number = Date.now();
    // 分卷导出时用全量人物建索引，本卷只负责排版
    const kinPeople: Person[] = (options.kinSource !== undefined && options.kinSource.length > 0)
      ? options.kinSource : people;
    const kinIndex: KinshipIndex = new KinshipIndex(kinPeople);
    console.info('[PdfExport] index ' + (Date.now() - ts) + 'ms, kin=' + kinPeople.length + ', volume=' + people.length);

    const coverPages: PageSpec[] = options.includeCover
      ? paginateLines(ctx, buildCover(book, people.length, options.volumeTitle ?? ''), '封 面', 0) : [];
    const prefacePages: PageSpec[] = paginateLines(ctx, buildPreface(ctx, book), '谱 序', 36);
    const offset: number = coverPages.length + prefacePages.length;

    // 第一遍：用等宽页码占位排版，确定「每人落在第几页」
    const tA: number = Date.now();
    const entries1: EntryBlock[] = buildGenealogyEntries(ctx, people, kinIndex, null);
    const firstPass: PaginateResult = paginateEntries(entries1, offset);
    console.info('[PdfExport] pass1 ' + (Date.now() - tA) + 'ms, pages=' + firstPass.pages.length);
    // 第二遍：回填真实页码。占位串比真实页码长，折行数可能变少，
    // 用空行补齐到第一遍的行数，保证分页结果与页码互引完全一致
    const tB: number = Date.now();
    gCrossRef = (options.crossRef !== undefined) ? options.crossRef : null;
    const heights: Map<string, number> = new Map<string, number>();
    for (let i: number = 0; i < entries1.length; i++) {
      heights.set(entries1[i].uid, entries1[i].lines.length);
    }
    const entries2: EntryBlock[] = buildGenealogyEntries(ctx, people, kinIndex, firstPass.uidPage);
    for (let i: number = 0; i < entries2.length; i++) {
      const e: EntryBlock = entries2[i];
      const want: number | undefined = heights.get(e.uid);
      if (want !== undefined) {
        while (e.lines.length < want) {
          e.lines.push(padLine());
        }
      }
    }
    const genealogyPages: PageSpec[] = paginateEntries(entries2, offset).pages;
    console.info('[PdfExport] pass2 ' + (Date.now() - tB) + 'ms, pages=' + genealogyPages.length);
    gCrossRef = null;
    const backPages: PageSpec[] = paginateLines(ctx, buildBack(ctx, book), '家 训', 36);

    const all: PageSpec[] = [];
    pushAllPages(all, coverPages);
    pushAllPages(all, prefacePages);
    pushAllPages(all, genealogyPages);
    pushAllPages(all, backPages);
    const total: number = all.length;
    if (total === 0) {
      throw new Error('排版结果为空');
    }

    // 3. 逐页写入 PDF 文本对象（矢量文字，可选中、可搜索、可编辑）
    const d: Date = new Date();
    const stamp: string = d.getFullYear().toString() +
      (d.getMonth() + 1).toString().padStart(2, '0') +
      d.getDate().toString().padStart(2, '0');
    const vol: string = (options.volumeTitle !== undefined && options.volumeTitle.length > 0)
      ? '_' + options.volumeTitle : '';
    const outPath: string = outDir + '/' + book.title + vol + '_' + stamp + '.pdf';

    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    if (!doc.createDocument(PAGE_W, PAGE_H)) {
      throw new Error('PDF 文档创建失败');
    }
    // createDocument 会自带一个空白页，不删掉会让导出的 PDF 首页空白、后续内容整体后移一页
    if (doc.getPageCount() === 1) {
      doc.deletePage(0, 1);
    }
    const t0: number = Date.now();
    for (let i: number = 0; i < total; i++) {
      drawPageToPdf(ctx, doc, all[i], i + 1, total, i < coverPages.length);
      if (onProgress && (i % 5 === 0 || i === total - 1)) {
        onProgress({ current: i + 1, total: total, message: '排版第 ' + (i + 1) + '/' + total + ' 页' });
      }
      if (i % 50 === 0) {
        console.info('[PdfExport] page ' + i + '/' + total + ' cost ' + (Date.now() - t0) + 'ms');
      }
      await yieldToUi(); // 每页让出一个时间片，避免主线程被看门狗判定无响应
    }
    const t1: number = Date.now();
    const saved: boolean = doc.saveDocument(outPath);
    let savedSize: number = -1;
    try {
      savedSize = fileIo.statSync(outPath).size;
    } catch (_e) {
      savedSize = -1;
    }
    console.info('[PdfExport] save ' + saved + ' cost ' + (Date.now() - t1) + 'ms, pages=' + total
      + ', size=' + savedSize);
    doc.releaseDocument();
    if (!saved) {
      throw new Error('PDF 保存失败');
    }

    if (onProgress) {
      onProgress({ current: total + 1, total: total + 1, message: '完成' });
    }
    return outPath;
  }
}
