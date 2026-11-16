import { pdfService } from '@kit.PDFKit';
import { Font } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { Person, SpouseRelation, childStatusLabel, spouseRelationLabel } from '../model/Person';
import { PersonNode } from '../model/PersonNode';
import { Genealogy } from '../model/Genealogy';
import { generationLabel } from '../model/Enums';
import { displayDate } from '../util/DateUtil';
import { GenealogyService } from './GenealogyService';
import { TreeLayoutCache } from './TreeLayoutCache';
import { RawPdfWriter, PdfTextLine, PdfInfo } from './RawPdfWriter';
import { RawPdfFont } from './RawPdfFont';
import { PdfFontUtil } from './PdfFontUtil';
import { PageSpec as PrintPageSpec } from './PrintLayout';

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
 * 页面：A4 竖版 210×297mm；版心由 PrintLayout.PageSpec 计算，
 * 装订侧可在左/右之间选择，双面印刷时随卷内奇偶页镜像。
 */

// ─── 页面常量（pt） ────────────────────────────────────────
const PAGE_W: number = 595.28;
const PAGE_H: number = 841.89;
/** 旧 PDFKit 导出路径（exportPdf）使用的固定版心，保留以兼容未调用代码 */
const MARGIN_LR: number = 56;
const MARGIN_TOP: number = 64;
const MARGIN_BOTTOM: number = 52;
const CONTENT_W: number = PAGE_W - MARGIN_LR * 2;
const CONTENT_H: number = PAGE_H - MARGIN_TOP - MARGIN_BOTTOM;

/** 牒记式 A4 页面规格：每次导出时读取最新的装订方向与单双面设置 */
function dieSpec(): PrintPageSpec {
  return PrintPageSpec.portraitA4();
}

/** 版心宽（pt）：左右装订切换时宽度不变，只改版心起点 */
function dieContentW(spec: PrintPageSpec): number {
  return PrintPageSpec.mmToPt(spec.contentWidth());
}

/** 版心高（pt） */
function dieContentH(spec: PrintPageSpec): number {
  return PrintPageSpec.mmToPt(spec.contentHeight());
}

/**
 * 牒记版心左边界（pt）。
 * 装订侧固定留 gutter + safeInset，翻口侧为剩余宽度，正反面以纸张中心镜像：
 * 双面印刷时同一张纸正反两面的文字区严格对齐，不会一面偏内、一面偏外。
 */
function dieInnerX(spec: PrintPageSpec, recto: boolean): number {
  const bindInset: number = spec.gutter + spec.safeInset;
  const innerMm: number = spec.bindOnRight(recto)
    ? spec.trimW - spec.contentWidth() - bindInset
    : bindInset;
  return PrintPageSpec.mmToPt(innerMm);
}

// ─── 度量画布常量（px = pt × S） ──────────────────────────
const S: number = 2;
const CANVAS_W: number = 1191;
const CANVAS_H: number = 1684;

// ─── 导出内存看门狗常量 ───────────────────────────────────
// 逐页写 PDF 时监控进程 PSS，超过软上限就主动抛可捕获错误并提示分卷，
// 避免 PDFKit 在 native 层耗尽内存被系统直接杀死（进程级崩溃，HiLog 无记录）。
// 软上限按设备内存可调；设为 0 表示关闭监控。
// 绝对软上限保护异常增长；同时用「导出增量」判断，避免大谱基础占用高被误判。
const MEMORY_SOFT_LIMIT_KB: number = 2200 * 1024;
const MEMORY_CHECK_EVERY_PAGES: number = 16;
/** 硬上限：仅进程接近系统限制时才中止 */
const MEMORY_HARD_LIMIT_KB: number = 2600 * 1024;
/** 导出过程允许的内存增长（KB）：超过只告警 */
const MEMORY_GROWTH_LIMIT_KB: number = 1000 * 1024;

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
function wrapLines(text: string, font: number, indent: number, color: string,
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

function todayStr(): string {
  const d: Date = new Date();
  return d.getFullYear().toString() + '年' + (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
}

// ─── 内容构建 ─────────────────────────────────────────────

/** 房支索引项：用于按房分卷与卷名生成 */
class BranchInfo {
  branchName: string = '';
  rootUid: string = '';
  rootName: string = '';
}

/** 一个家庭单元：一名本支成员（锚点）+ 其配偶（配偶世代即使录错也跟随锚点） */
class FamilyUnit {
  generation: number = 0;
  anchorUid: string = '';
  members: Person[] = [];
}

/** 并查集查找（带路径压缩，避免大谱递归爆栈） */
function ufFind(parent: number[], x: number): number {
  let root: number = x;
  while (parent[root] !== root) {
    root = parent[root];
  }
  let cur: number = x;
  while (parent[cur] !== root) {
    const next: number = parent[cur];
    parent[cur] = root;
    cur = next;
  }
  return root;
}

/**
 * 把人物按「家庭」聚合并排序：
 * 1. 配偶关系用并查集合并成家庭单元，夫妻永远相邻；
 *    配偶的 generation 录成别的世代也不会被甩到相隔上百页去；
 * 2. 锚点优先选有父母的本支成员，其次男性，保证「夫在前、妻在后」；
 * 3. 单元按「锚点世代 + 锚点 UID」排序，阅读顺序仍是世代升序。
 */
function buildFamilyUnits(people: Person[]): FamilyUnit[] {
  const n: number = people.length;
  if (n === 0) {
    return [];
  }
  const parent: number[] = [];
  for (let i: number = 0; i < n; i++) {
    parent.push(i);
  }
  const idxByUid: Map<string, number> = new Map<string, number>();
  for (let i: number = 0; i < n; i++) {
    const key: string = people[i].uid.trim().toUpperCase();
    if (key.length > 0 && !idxByUid.has(key)) {
      idxByUid.set(key, i);
    }
  }
  for (let i: number = 0; i < n; i++) {
    const spouses: SpouseRelation[] = people[i].spouses;
    for (let j: number = 0; j < spouses.length; j++) {
      const sp: number | undefined = idxByUid.get(spouses[j].uid.trim().toUpperCase());
      if (sp === undefined) {
        continue;
      }
      const ra: number = ufFind(parent, i);
      const rb: number = ufFind(parent, sp);
      if (ra !== rb) {
        parent[rb] = ra;
      }
    }
  }
  const groups: Map<number, number[]> = new Map<number, number[]>();
  for (let i: number = 0; i < n; i++) {
    const r: number = ufFind(parent, i);
    const arr: number[] | undefined = groups.get(r);
    if (arr === undefined) {
      groups.set(r, [i]);
    } else {
      arr.push(i);
    }
  }
  const units: FamilyUnit[] = [];
  groups.forEach((idxs: number[]): void => {
    idxs.sort((a: number, b: number): number => people[a].uid.localeCompare(people[b].uid));
    let anchor: number = idxs[0];
    let bestScore: number = -1;
    for (let i: number = 0; i < idxs.length; i++) {
      const p: Person = people[idxs[i]];
      let score: number = 0;
      if (p.fatherId.trim().length > 0 || p.motherId.trim().length > 0) {
        score += 2;
      }
      if (p.gender === '男') {
        score += 1;
      }
      if (score > bestScore) {
        bestScore = score;
        anchor = idxs[i];
      }
    }
    const unit: FamilyUnit = new FamilyUnit();
    unit.generation = people[anchor].generation;
    if (unit.generation <= 0) {
      let minGen: number = 0;
      for (let i: number = 0; i < idxs.length; i++) {
        const g: number = people[idxs[i]].generation;
        if (g > 0 && (minGen === 0 || g < minGen)) {
          minGen = g;
        }
      }
      unit.generation = minGen;
    }
    unit.anchorUid = people[anchor].uid.trim().toUpperCase();
    unit.members.push(people[anchor]);
    // 其余成员：男在前、女在后，同性别按 UID，保证每次排版顺序稳定
    const rest: number[] = [];
    for (let i: number = 0; i < idxs.length; i++) {
      if (idxs[i] !== anchor) {
        rest.push(idxs[i]);
      }
    }
    rest.sort((a: number, b: number): number => {
      const ga: number = people[a].gender === '男' ? 0 : 1;
      const gb: number = people[b].gender === '男' ? 0 : 1;
      if (ga !== gb) {
        return ga - gb;
      }
      return people[a].uid.localeCompare(people[b].uid);
    });
    for (let i: number = 0; i < rest.length; i++) {
      unit.members.push(people[rest[i]]);
    }
    units.push(unit);
  });
  units.sort((a: FamilyUnit, b: FamilyUnit): number => {
    if (a.generation !== b.generation) {
      return a.generation - b.generation;
    }
    return a.anchorUid.localeCompare(b.anchorUid);
  });
  return units;
}

/** 条目块：uid 用于页码互引（世代分隔头的 uid 为空串） */
interface EntryBlock {
  uid: string;
  /** 同一家庭单元（本人+配偶）共用一个 unitId：分页时整单元一起换页，夫妻不会被拆到两页 */
  unitId: string;
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
  kinIndex: KinshipIndex, refs: Map<string, number> | null,
  contentW: number = CONTENT_W): TextLine[] {
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
    pushAll(lines, wrapLines('配偶：' + spouseText(kinIndex, p, refs), F_DETAIL, 10, C_FEMALE, contentW));
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
    pushAll(lines, wrapLines('亲属：' + kinParts.join('　'), F_DETAIL, 10, C_INK2, contentW));
  }
  // 子嗣：全部列出，一行放不下自动换行
  const kids: Person[] = kinIndex.childrenOf(p.uid);
  if (kids.length > 0) {
    const parts: string[] = [];
    for (let i: number = 0; i < kids.length; i++) {
      parts.push(refText(kids[i].name, kids[i].uid, refs));
    }
    const txt: string = '子嗣：' + parts.join('、') + '（共' + kids.length.toString() + '人）';
    pushAll(lines, wrapLines(txt, F_DETAIL, 10, C_INK2, contentW));
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
  pushAll(lines, wrapLines('身份：' + idParts.join('　'), F_DETAIL, 10, C_INK2, contentW));
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
    pushAll(lines, wrapLines(life.join('　'), F_DETAIL, 10, C_INK2, contentW));
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
    pushAll(lines, wrapLines(places.join('　'), F_DETAIL, 10, C_INK2, contentW));
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
    pushAll(lines, wrapLines(career.join('　'), F_DETAIL, 10, C_INK2, contentW));
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
    pushAll(lines, wrapLines('墓葬：' + grave.join('　'), F_DETAIL, 10, C_INK2, contentW));
  }
  // 生平简介
  if (p.biography.length > 0) {
    pushAll(lines, wrapLines('生平：' + p.biography, F_DETAIL, 10, C_INK, contentW));
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
    pushAll(lines, wrapLines('联系：' + contact.join('　'), F_DETAIL, 10, C_INK2, contentW));
  }
  lines.push({ text: ' ', font: 8, lineH: 12, color: C_BG, bold: false, indent: 0, center: false });
  return lines;
}

/**
 * 世系条目：世代分隔头 + 逐人条目。
 * 排序以「家庭单元」为单位（见 buildFamilyUnits）：夫妻无论世代是否录得一致都紧挨着输出，
 * 条目带上 unitId，分页时整单元一起换页，不会出现「夫在第2页、妻在第100页」。
 */
async function buildGenealogyEntries(ctx: OffscreenCanvasRenderingContext2D, people: Person[],
  kinIndex: KinshipIndex, refs: Map<string, number> | null,
  contentW: number = CONTENT_W): Promise<EntryBlock[]> {
  const units: FamilyUnit[] = buildFamilyUnits(people);
  // 每个展示世代的人数按锚点世代统计，配偶世代录错也归入同一节
  const genCount: Map<number, number> = new Map<number, number>();
  for (let i: number = 0; i < units.length; i++) {
    const cur: number | undefined = genCount.get(units[i].generation);
    genCount.set(units[i].generation, (cur === undefined ? 0 : cur) + units[i].members.length);
  }
  const entries: EntryBlock[] = [];
  let lastGen: number = -1;
  let written: number = 0;
  for (let i: number = 0; i < units.length; i++) {
    const unit: FamilyUnit = units[i];
    if (unit.generation !== lastGen) {
      lastGen = unit.generation;
      const c: number | undefined = genCount.get(unit.generation);
      const total: number = c === undefined ? unit.members.length : c;
      entries.push({
        uid: '',
        unitId: '',
        lines: [{
          text: generationLabel(unit.generation) + '（' + total.toString() + '人）',
          font: 16, lineH: 32, color: C_GOLD, bold: true, indent: 0, center: false
        }]
      });
    }
    const unitId: string = unit.anchorUid + '#' + unit.generation.toString();
    for (let j: number = 0; j < unit.members.length; j++) {
      const p: Person = unit.members[j];
      entries.push({
        uid: p.uid.trim().toUpperCase(),
        unitId: unitId,
        lines: personEntryLines(ctx, p, kinIndex, refs, contentW)
      });
    }
    // 每 100 人让出一次主线程：逐字断行 + measureText 是同步 Native 调用，
    // 数万人的谱一次跑完会被系统看门狗判定无响应（THREAD_BLOCK_6S）。
    written = written + unit.members.length;
    if (written >= 100) {
      written = 0;
      await yieldToUi();
    }
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
  // 分支谱上承：写明本支从哪部谱、哪一世、哪一位先人分出，便于跨谱追溯
  if (book.parentBookTitle.length > 0 || book.parentName.length > 0 || book.parentUid.length > 0) {
    const src: string = book.parentBookTitle.length > 0 ? book.parentBookTitle : '母谱';
    const gen: string = book.parentGeneration > 0 ? ('第' + book.parentGeneration.toString() + '世 ') : '';
    const who: string = book.parentName.length > 0 ? book.parentName :
      (book.parentUid.length > 0 ? book.parentUid : '先祖');
    lines.push({
      text: '承自《' + src + '》' + gen + who,
      font: 12, lineH: 20, color: C_INK2, bold: false, indent: 0, center: true
    });
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
function buildPreface(ctx: OffscreenCanvasRenderingContext2D, book: Genealogy,
  contentW: number = CONTENT_W): TextLine[] {
  const lines: TextLine[] = [];
  let has: boolean = false;
  // 分支谱先写「上承」：即使没有谱序/凡例，也要留下跨谱来源
  if (book.parentBookTitle.length > 0 || book.parentName.length > 0 || book.parentUid.length > 0) {
    const src: string = book.parentBookTitle.length > 0 ? book.parentBookTitle : '母谱';
    const gen: string = book.parentGeneration > 0 ? ('第' + book.parentGeneration.toString() + '世 ') : '';
    const who: string = book.parentName.length > 0 ? book.parentName :
      (book.parentUid.length > 0 ? book.parentUid : '先祖');
    lines.push({ text: '本支承自《' + src + '》' + gen + who,
      font: 12, lineH: 24, color: C_INK, bold: false, indent: 0, center: false });
    lines.push(spacerLine());
    has = true;
  }
  if (book.preface.trim().length > 0) {
    lines.push({ text: '谱 序', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(book.preface, 12, 0, C_INK, contentW));
    has = true;
  }
  if (book.editingNotes.trim().length > 0) {
    if (has) {
      lines.push(spacerLine());
    }
    lines.push({ text: '凡 例', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(book.editingNotes, 12, 0, C_INK, contentW));
  }
  return lines;
}

/** 家训 + 落款 */
function buildBack(ctx: OffscreenCanvasRenderingContext2D, book: Genealogy,
  contentW: number = CONTENT_W): TextLine[] {
  const lines: TextLine[] = [];
  if (book.familyRules.trim().length > 0) {
    lines.push({ text: '家 训', font: 14, lineH: 28, color: C_GOLD, bold: true, indent: 0, center: false });
    lines.push(spacerLine());
    pushAll(lines, wrapLines(book.familyRules, 12, 0, C_INK, contentW));
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
async function paginateEntries(entries: EntryBlock[], pageOffset: number,
  contentH: number = CONTENT_H): Promise<PaginateResult> {
  const pages: PageSpec[] = [];
  const uidPage: Map<string, number> = new Map<string, number>();
  let cur: TextLine[] = [];
  let used: number = 0;
  const keepHead: number = 36; // 顶部保留页眉区
  const blockHeight = (lines: TextLine[]): number => {
    let h: number = 0;
    for (let j: number = 0; j < lines.length; j++) {
      h += lines[j].lineH;
    }
    return h;
  };
  let i: number = 0;
  let processed: number = 0;
  let nextYield: number = 200;
  while (i < entries.length) {
    // 同一家庭单元（本人+配偶）作为一个整体判断换页，夫妻不会被页尾拆散
    const unitId: string = entries[i].unitId;
    let groupEnd: number = i + 1;
    let groupH: number = blockHeight(entries[i].lines);
    if (unitId.length > 0) {
      while (groupEnd < entries.length && entries[groupEnd].unitId === unitId) {
        groupH += blockHeight(entries[groupEnd].lines);
        groupEnd++;
      }
    } else if (entries[i].uid.length === 0 && groupEnd < entries.length
      && entries[groupEnd].unitId.length > 0) {
      // 世代分隔头跟随本节第一个家庭单元，避免只剩一个标题孤零零留在页尾
      const nextUnit: string = entries[groupEnd].unitId;
      while (groupEnd < entries.length && entries[groupEnd].unitId === nextUnit) {
        groupH += blockHeight(entries[groupEnd].lines);
        groupEnd++;
      }
    }
    const need: number = (used === 0 ? keepHead : 8) + groupH;
    if (used + need > contentH && cur.length > 0) {
      pages.push({ lines: cur, chapter: '世 系' });
      cur = [];
      used = 0;
    }
    for (let k: number = i; k < groupEnd; k++) {
      if (entries[k].uid.length > 0) {
        uidPage.set(entries[k].uid, pageOffset + pages.length + 1);
      }
      pushAll(cur, entries[k].lines);
      used += blockHeight(entries[k].lines);
    }
    processed += groupEnd - i;
    i = groupEnd;
    // 与条目构建同样分片让出，避免大谱一次分页长时间占住主线程
    if (processed >= nextYield) {
      nextYield += 200;
      await yieldToUi();
    }
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
  lines: TextLine[], chapter: string, keepHead: number,
  contentH: number = CONTENT_H): PageSpec[] {
  if (lines.length === 0) {
    return [];
  }
  const pages: PageSpec[] = [];
  let cur: TextLine[] = [];
  let used: number = 0;
  for (let i: number = 0; i < lines.length; i++) {
    const ln: TextLine = lines[i];
    if (used + ln.lineH > contentH && cur.length > 0) {
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

/** 关系索引跨卷复用：全量索引（数万人）每卷重建一次是分卷导出的主要固定开销 */
let cachedKinIndex: KinshipIndex | null = null;
let cachedKinSource: Person[] | null = null;

function kinshipFor(people: Person[]): KinshipIndex {
  if (cachedKinIndex !== null && cachedKinSource === people) {
    return cachedKinIndex;
  }
  const idx: KinshipIndex = new KinshipIndex(people);
  cachedKinIndex = idx;
  cachedKinSource = people;
  return idx;
}

function pdfFontInfo(): pdfService.FontInfo {
  if (cachedFontInfo === null) {
    const fi: pdfService.FontInfo = new pdfService.FontInfo();
    // 统一走 PdfFontUtil：只认含 CJK 的字体，避免命中 342KB 的拉丁字体导致整卷中文缺字
    const p: string = PdfFontUtil.fontPath();
    if (p.length > 0) {
      fi.fontPath = p;
      fi.fontName = 'HarmonyOS Sans SC';
    }
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

/** 读取当前进程 PSS（单位 KB），失败返回 -1。hidebug.getPss() 返回 bigint。 */
function currentPssKb(): number {
  try {
    return Number(hidebug.getPss());
  } catch (_e) {
    return -1;
  }
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
    // 页码居中放在页脚，颜色比正文浅一档但保证可读：第 X 页 / 共 Y 页
    const footer: string = '第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页';
    const style: pdfService.TextStyle = textStyle(9.5, C_INK2, false);
    page.addTextObject(footer,
      PAGE_W / 2 - measurePt(ctx, footer, 9.5) / 2, MARGIN_BOTTOM / 2, style);
  }
}

// ─── 主服务 ───────────────────────────────────────────────

/**
 * 族谱 PDF 导出主服务。
 */
export class PdfExportService {

  /**
   * 分卷规划：优先按「房支」自然分卷（长房/二房/三房各成卷），
   * 单房超限时再按世代 + 家庭单元续切；无法取得房支信息时回退旧的世代分卷。
   * 以「家庭单元」为最小切分单位，夫妻永远不会被分到两卷。
   * 返回空数组表示无需分卷（人数未超限）。
   */
  static planVolumes(people: Person[], maxPerVolume: number): PdfVolume[] {
    if (people.length <= maxPerVolume || maxPerVolume <= 0) {
      return [];
    }
    const index: Map<string, BranchInfo> = PdfExportService.branchIndex();
    if (index.size > 0) {
      const byBranch: PdfVolume[] = PdfExportService.planBranchVolumes(people, maxPerVolume, index);
      if (byBranch.length > 0) {
        return byBranch;
      }
    }
    return PdfExportService.slicePeopleByGeneration(people, maxPerVolume);
  }

  /** 组装 uid → 房支信息（从当前宗支树一次性提取） */
  private static branchIndex(): Map<string, BranchInfo> {
    const infos: Map<string, BranchInfo> = new Map<string, BranchInfo>();
    const nameOf: Map<string, string> = new Map<string, string>();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    const stack: PersonNode[] = [];
    for (let i: number = 0; i < roots.length; i = i + 1) {
      stack.push(roots[i]);
    }
    while (stack.length > 0) {
      const n: PersonNode = stack.pop() as PersonNode;
      if (infos.has(n.uid.trim().toUpperCase())) {
        continue;
      }
      const info: BranchInfo = new BranchInfo();
      info.branchName = n.branchName.length > 0 ? n.branchName : '本支';
      info.rootUid = n.branchRootUid.length > 0 ? n.branchRootUid : n.uid;
      infos.set(n.uid.trim().toUpperCase(), info);
      nameOf.set(n.uid.trim().toUpperCase(), n.person.name.length > 0 ? n.person.name : n.uid);
      // 配偶卡跟随主卡房支，导出名单里配偶也不会被算作「未识别」
      for (let s: number = 0; s < n.spouses.length; s = s + 1) {
        const sp: PersonNode = n.spouses[s];
        const spKey: string = sp.uid.trim().toUpperCase();
        if (!infos.has(spKey)) {
          infos.set(spKey, info);
          nameOf.set(spKey, sp.person.name.length > 0 ? sp.person.name : sp.uid);
        }
      }
      for (let k: number = 0; k < n.children.length; k = k + 1) {
        stack.push(n.children[k]);
      }
    }
    infos.forEach((info: BranchInfo): void => {
      const rootName: string | undefined = nameOf.get(info.rootUid.trim().toUpperCase());
      info.rootName = rootName !== undefined ? rootName : '';
    });
    return infos;
  }

  /** 按房支分卷；覆盖度不足（导出子集不属于当前树）时返回空数组由调用方回退 */
  private static planBranchVolumes(people: Person[], maxPerVolume: number,
    index: Map<string, BranchInfo>): PdfVolume[] {
    let hit: number = 0;
    const order: string[] = [];
    const groups: Map<string, Person[]> = new Map<string, Person[]>();
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      const info: BranchInfo | undefined = index.get(p.uid.trim().toUpperCase());
      if (info === undefined) {
        continue;
      }
      hit = hit + 1;
      const key: string = info.rootUid.length > 0 ? info.rootUid : p.uid;
      let arr: Person[] | undefined = groups.get(key);
      if (arr === undefined) {
        arr = [];
        groups.set(key, arr);
        order.push(key);
      }
      arr.push(p);
    }
    if (hit < Math.floor(people.length * 0.8)) {
      return [];
    }
    const volumes: PdfVolume[] = [];
    // 小房不单独成卷：几十个「一房一卷」会让每卷都建文档/保存，导出时间成倍增加，
    // 也更容易在中途触发系统内存回收。这里只让大房独立成卷，小房合并为合卷。
    const minSingle: number = Math.max(200, Math.floor(maxPerVolume / 2));
    let mergePeople: Person[] = [];
    let mergeNameCount: number = 0;
    for (let g: number = 0; g < order.length; g = g + 1) {
      const key: string = order[g];
      const list: Person[] | undefined = groups.get(key);
      if (list === undefined || list.length === 0) {
        continue;
      }
      const firstInfo: BranchInfo | undefined = index.get(list[0].uid.trim().toUpperCase());
      const branchName: string = firstInfo !== undefined ? firstInfo.branchName : '本支';
      const rootName: string = firstInfo !== undefined ? firstInfo.rootName : '';
      const name: string = branchName + (rootName.length > 0 ? '·' + rootName : '');
      if (list.length >= minSingle) {
        if (list.length <= maxPerVolume) {
          const vol: PdfVolume = {
            title: '第' + (volumes.length + 1).toString() + '卷（' + name + '）',
            people: list
          };
          volumes.push(vol);
        } else {
          const subs: PdfVolume[] = PdfExportService.slicePeopleByGeneration(list, maxPerVolume);
          for (let s: number = 0; s < subs.length; s = s + 1) {
            subs[s].title = '第' + (volumes.length + 1).toString() + '卷（' + name +
              (s > 0 ? '·续' : '') + '）';
            volumes.push(subs[s]);
          }
        }
        continue;
      }
      // 小房累积：超过单卷容量先落一卷，避免超限
      if (mergePeople.length > 0 && mergePeople.length + list.length > maxPerVolume) {
        const merged: PdfVolume = {
          title: '第' + (volumes.length + 1).toString() + '卷（合卷·' +
            mergeNameCount.toString() + '房）',
          people: mergePeople
        };
        volumes.push(merged);
        mergePeople = [];
        mergeNameCount = 0;
      }
      for (let k: number = 0; k < list.length; k = k + 1) {
        mergePeople.push(list[k]);
      }
      mergeNameCount = mergeNameCount + 1;
    }
    if (mergePeople.length > 0) {
      const merged: PdfVolume = {
        title: '第' + (volumes.length + 1).toString() + '卷（合卷·' +
          mergeNameCount.toString() + '房）',
        people: mergePeople
      };
      volumes.push(merged);
    }
    return volumes;
  }

  /** 世代 + 家庭单元分卷（旧逻辑保留，作为房支信息缺失时的回退） */
  private static slicePeopleByGeneration(people: Person[], maxPerVolume: number): PdfVolume[] {
    const units: FamilyUnit[] = buildFamilyUnits(people);
    const volumes: PdfVolume[] = [];
    let i: number = 0;
    while (i < units.length) {
      // 先把当前世代整个装进来
      const startGen: number = units[i].generation;
      let end: number = i;
      let count: number = 0;
      while (end < units.length && units[end].generation === startGen) {
        count += units[end].members.length;
        end++;
      }
      if (count > maxPerVolume) {
        // 单个世代自身就超限：按家庭单元硬切，夫妻不拆卷
        let k: number = i;
        while (k < end) {
          const from: number = k;
          let c: number = 0;
          while (k < end && (c === 0 || c + units[k].members.length <= maxPerVolume)) {
            c += units[k].members.length;
            k++;
          }
          volumes.push(PdfExportService.sliceVolume(units, from, k, volumes.length + 1));
        }
        i = end;
        continue;
      }
      // 在容量允许时继续并入后面完整的世代
      let scan: number = end;
      while (scan < units.length) {
        const g: number = units[scan].generation;
        let gEnd: number = scan;
        let gCount: number = 0;
        while (gEnd < units.length && units[gEnd].generation === g) {
          gCount += units[gEnd].members.length;
          gEnd++;
        }
        if (gCount > maxPerVolume || count + gCount > maxPerVolume) {
          break;
        }
        count += gCount;
        scan = gEnd;
      }
      volumes.push(PdfExportService.sliceVolume(units, i, scan, volumes.length + 1));
      i = scan;
    }
    return volumes;
  }

  /** 把家庭单元区间 [from, to) 落成一卷（保持夫妻相邻顺序） */
  private static sliceVolume(units: FamilyUnit[], from: number, to: number, seq: number): PdfVolume {
    const people: Person[] = [];
    for (let i: number = from; i < to; i++) {
      for (let j: number = 0; j < units[i].members.length; j++) {
        people.push(units[i].members[j]);
      }
    }
    const gStart: number = units[from].generation;
    const gEnd: number = units[to - 1].generation;
    const title: string = gStart === gEnd
      ? '第' + seq.toString() + '卷（' + generationLabel(gStart) + '）'
      : '第' + seq.toString() + '卷（' + generationLabel(gStart) + '至' + generationLabel(gEnd) + '）';
    return { title: title, people: people };
  }

  /**
   * 生成跨卷位置索引：先把每一卷排一遍版，得到 uid →「第2卷358页」。
   * 必须在导出 PDF 之前调用，导出的第二遍才能把「父xxx(Fxxx·第2卷358页)」写实。
   * 每一卷只算页位不写 PDF，所用占位串与正式导出第一遍一致，页数稳定。
   */
  static async prepareCrossRefs(
    people: Person[],
    book: Genealogy,
    jobs: PdfVolume[],
    includeCover: boolean
  ): Promise<Map<string, string>> {
    const out: Map<string, string> = new Map<string, string>();
    if (jobs.length === 0) {
      return out;
    }
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(CANVAS_W, CANVAS_H);
    const ctx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');
    const printSpec: PrintPageSpec = dieSpec();
    const contentW: number = dieContentW(printSpec);
    const contentH: number = dieContentH(printSpec);
    const kinIndex: KinshipIndex = kinshipFor(people);
    for (let i: number = 0; i < jobs.length; i++) {
      const vol: PdfVolume = jobs[i];
      const coverPages: PageSpec[] = includeCover
        ? paginateLines(ctx, buildCover(book, vol.people.length, vol.title), '封 面', 0, contentH) : [];
      const prefacePages: PageSpec[] = paginateLines(ctx, buildPreface(ctx, book, contentW), '谱 序', 36,
        contentH);
      const offset: number = coverPages.length + prefacePages.length;
      const entries: EntryBlock[] =
        await buildGenealogyEntries(ctx, vol.people, kinIndex, null, contentW);
      const pg: PaginateResult = await paginateEntries(entries, offset, contentH);
      const multi: boolean = jobs.length > 1;
      pg.uidPage.forEach((pageNo: number, uid: string): void => {
        out.set(uid, multi
          ? '第' + (i + 1).toString() + '卷' + pageNo.toString() + '页'
          : '第' + pageNo.toString() + '页');
      });
    }
    return out;
  }

  /**
   * 牒记式：方案 F 文本 PDF（嵌入 HarmonyOS Sans TTF，文字可搜索/复制）。
   * 复用现有断行与分页结果，只把「写 PDF」从 PDFKit 换成 RawPdfWriter。
   */
  static async exportRawTextPdf(
    context: common.UIAbilityContext,
    people: Person[],
    book: Genealogy,
    options: PdfExportOptions,
    onProgress?: (p: PdfExportProgress) => void
  ): Promise<string> {
    if (people.length === 0) {
      throw new Error('没有可导出的人物数据');
    }
    const outDir: string = context.filesDir + '/pdf_export';
    if (!fileIo.accessSync(outDir)) {
      fileIo.mkdirSync(outDir);
    }
    const measureCanvas: OffscreenCanvas = new OffscreenCanvas(CANVAS_W, CANVAS_H);
    const ctx: OffscreenCanvasRenderingContext2D = measureCanvas.getContext('2d');
    // 每次导出读取最新的左右装订与单双面设置
    const printSpec: PrintPageSpec = dieSpec();
    const contentW: number = dieContentW(printSpec);
    const contentH: number = dieContentH(printSpec);
    const kinPeople: Person[] = (options.kinSource !== undefined && options.kinSource.length > 0)
      ? options.kinSource : people;
    const kinIndex: KinshipIndex = kinshipFor(kinPeople);
    const coverPages: PageSpec[] = options.includeCover
      ? paginateLines(ctx, buildCover(book, people.length, options.volumeTitle ?? ''), '封 面', 0,
        contentH) : [];
    const prefacePages: PageSpec[] = paginateLines(ctx, buildPreface(ctx, book, contentW), '谱 序', 36,
      contentH);
    const offset: number = coverPages.length + prefacePages.length;

    await yieldToUi();
    let entries1: EntryBlock[] = await buildGenealogyEntries(ctx, people, kinIndex, null, contentW);
    const firstPass: PaginateResult = await paginateEntries(entries1, offset, contentH);
    const uidPageMap: Map<string, number> = firstPass.uidPage;
    gCrossRef = (options.crossRef !== undefined) ? options.crossRef : null;
    const heights: Map<string, number> = new Map<string, number>();
    for (let i: number = 0; i < entries1.length; i = i + 1) {
      heights.set(entries1[i].uid, entries1[i].lines.length);
    }
    entries1 = [];
    firstPass.pages = [];
    let entries2: EntryBlock[] =
      await buildGenealogyEntries(ctx, people, kinIndex, uidPageMap, contentW);
    for (let i: number = 0; i < entries2.length; i = i + 1) {
      const e: EntryBlock = entries2[i];
      const want: number | undefined = heights.get(e.uid);
      if (want !== undefined) {
        while (e.lines.length < want) {
          e.lines.push(padLine());
        }
      }
    }
    let genealogyPages: PageSpec[] = (await paginateEntries(entries2, offset, contentH)).pages;
    gCrossRef = null;
    const backPages: PageSpec[] = paginateLines(ctx, buildBack(ctx, book, contentW), '家 训', 36,
      contentH);
    const all: PageSpec[] = [];
    pushAllPages(all, coverPages);
    pushAllPages(all, prefacePages);
    pushAllPages(all, genealogyPages);
    pushAllPages(all, backPages);
    entries2 = [];
    genealogyPages = [];
    const total: number = all.length;
    if (total === 0) {
      throw new Error('排版结果为空');
    }

    const d: Date = new Date();
    const stamp: string = d.getFullYear().toString() +
      (d.getMonth() + 1).toString().padStart(2, '0') +
      d.getDate().toString().padStart(2, '0');
    const vol: string = (options.volumeTitle !== undefined && options.volumeTitle.length > 0)
      ? '_' + options.volumeTitle : '';
    const outPath: string = outDir + '/' + book.title + vol + '_' + stamp + '.pdf';

    const fontPath: string = pdfFontInfo().fontPath ?? '';
    const rawFont: RawPdfFont | null = PdfFontUtil.rawFont();
    console.info('[PdfExport] raw text pdf font=' +
      (rawFont === null ? 'fallback:STSong-Light' : fontPath) + ', pages=' + total.toString());
    const info: PdfInfo = new PdfInfo(book.title +
      (options.volumeTitle !== undefined && options.volumeTitle.length > 0
        ? ' ' + options.volumeTitle : ''));
    const writer: RawPdfWriter = new RawPdfWriter(outPath,
      PrintPageSpec.mmToPt(printSpec.trimW), PrintPageSpec.mmToPt(printSpec.trimH),
      0, 0, rawFont, info);
    const gutterW: number = PrintPageSpec.mmToPt(printSpec.gutter);
    for (let i: number = 0; i < total; i = i + 1) {
      // 双面印刷按「卷内页序」交替装订侧：每卷单独装订，不按整谱页码判断
      const recto: boolean = ((i + 1) % 2) === 1;
      const lines: PdfTextLine[] = PdfExportService.buildRawTextLines(ctx, printSpec, all[i],
        i + 1, total, i < coverPages.length, recto);
      writer.addTextLinePage(lines, PdfExportService.rawBookmark(all[i], i, coverPages.length),
        PrintPageSpec.mmToPt(printSpec.gutterX(recto)), gutterW);
      if (onProgress && (i % 5 === 0 || i === total - 1)) {
        onProgress({ current: i + 1, total: total, message: '排版第 ' + (i + 1) + '/' + total + ' 页' });
      }
      await yieldToUi();
    }
    writer.finish();
    return outPath;
  }

  /** 书签标题：封面用章节名，正文用「章节 · 页内首行」 */
  private static rawBookmark(spec: PageSpec, index: number, coverPages: number): string {
    if (index < coverPages) {
      return '封面';
    }
    for (let i: number = 0; i < spec.lines.length; i = i + 1) {
      const t: string = spec.lines[i].text.trim();
      if (t.length > 0) {
        return spec.chapter + ' · ' + t.substring(0, 24);
      }
    }
    return spec.chapter;
  }

  /** 把 PageSpec 的文本行转换为 RawPdfWriter 的绝对坐标（pt） */
  private static buildRawTextLines(ctx: OffscreenCanvasRenderingContext2D,
    printSpec: PrintPageSpec, spec: PageSpec, pageNo: number, total: number, isCover: boolean,
    recto: boolean): PdfTextLine[] {
    const out: PdfTextLine[] = [];
    // 版心起点随装订侧变化：装订侧留 gutter + safeInset，双面时奇偶页镜像
    const contentW: number = dieContentW(printSpec);
    const innerX: number = dieInnerX(printSpec, recto);
    const innerY: number = PrintPageSpec.mmToPt(printSpec.innerY());
    const centerX: number = innerX + contentW / 2;
    let y: number = isCover ? 0 : innerY;
    if (!isCover && spec.chapter.length > 0) {
      const r: PdfTextLine = new PdfTextLine();
      r.text = spec.chapter;
      r.xPt = innerX + contentW - measurePt(ctx, spec.chapter, 9);
      r.yPt = baselineOf(innerY - 16, 9);
      r.sizePt = 9;
      r.color = C_INK3;
      out.push(r);
    }
    for (let i: number = 0; i < spec.lines.length; i = i + 1) {
      const ln: TextLine = spec.lines[i];
      if (ln.text.trim().length > 0) {
        const r: PdfTextLine = new PdfTextLine();
        r.text = ln.text;
        r.xPt = ln.center ? centerX - measurePt(ctx, ln.text, ln.font) / 2
          : innerX + ln.indent;
        r.yPt = baselineOf(y, ln.font);
        r.sizePt = ln.font;
        r.color = ln.color;
        out.push(r);
      }
      y = y + ln.lineH;
    }
    if (!isCover) {
      const footer: string = '第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页';
      const r: PdfTextLine = new PdfTextLine();
      r.text = footer;
      r.xPt = centerX - measurePt(ctx, footer, 9.5) / 2;
      r.yPt = PrintPageSpec.mmToPt(printSpec.foot) / 2;
      r.sizePt = 9.5;
      r.color = C_INK2;
      out.push(r);
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
    // 导出前释放连续视图的布局画布缓存，给 PDFKit 腾出内存
    TreeLayoutCache.getInstance().invalidate();

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
    // 先让进度条跑完一帧，再进入耗时的同步断行与分页
    await yieldToUi();
    let entries1: EntryBlock[] = await buildGenealogyEntries(ctx, people, kinIndex, null);
    const firstPass: PaginateResult = await paginateEntries(entries1, offset);
    console.info('[PdfExport] pass1 ' + (Date.now() - tA) + 'ms, pages=' + firstPass.pages.length);
    // 第一遍整页排版仅用于页码映射与行数校验，取出 uidPage 后即可释放，
    // 避免其与第二遍数据同时常驻，降低大数据导出时的内存峰值
    const uidPageMap: Map<string, number> = firstPass.uidPage;
    // 第二遍：回填真实页码。占位串比真实页码长，折行数可能变少，
    // 用空行补齐到第一遍的行数，保证分页结果与页码互引完全一致
    const tB: number = Date.now();
    gCrossRef = (options.crossRef !== undefined) ? options.crossRef : null;
    const heights: Map<string, number> = new Map<string, number>();
    for (let i: number = 0; i < entries1.length; i++) {
      heights.set(entries1[i].uid, entries1[i].lines.length);
    }
    // 第一遍的 entries1 与整页数据到此不再需要，主动置空让 GC 回收（约一整份渲染文本）
    entries1 = [];
    firstPass.pages = [];
    let entries2: EntryBlock[] = await buildGenealogyEntries(ctx, people, kinIndex, uidPageMap);
    for (let i: number = 0; i < entries2.length; i++) {
      const e: EntryBlock = entries2[i];
      const want: number | undefined = heights.get(e.uid);
      if (want !== undefined) {
        while (e.lines.length < want) {
          e.lines.push(padLine());
        }
      }
    }
    let genealogyPages: PageSpec[] = (await paginateEntries(entries2, offset)).pages;
    console.info('[PdfExport] pass2 ' + (Date.now() - tB) + 'ms, pages=' + genealogyPages.length);
    gCrossRef = null;
    const backPages: PageSpec[] = paginateLines(ctx, buildBack(ctx, book), '家 训', 36);

    const all: PageSpec[] = [];
    pushAllPages(all, coverPages);
    pushAllPages(all, prefacePages);
    pushAllPages(all, genealogyPages);
    pushAllPages(all, backPages);
    // 至此所有页面已并入 all（共享同一批 PageSpec/文本对象），第二遍的 entries2 与 genealogyPages 数组本身不再需要，主动释放
    entries2 = [];
    genealogyPages = [];
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
    let saved: boolean = false;
    try {
      // createDocument 会自带一个空白页，不删掉会让导出的 PDF 首页空白、后续内容整体后移一页
      if (doc.getPageCount() === 1) {
        doc.deletePage(0, 1);
      }
      const t0: number = Date.now();
      // 大谱基础 PSS 可能已有几百 MB，用「导出增量」比绝对阈值更准确
      const basePssKb: number = currentPssKb();
      for (let i: number = 0; i < total; i++) {
        drawPageToPdf(ctx, doc, all[i], i + 1, total, i < coverPages.length);
        if (onProgress && (i % 5 === 0 || i === total - 1)) {
          onProgress({ current: i + 1, total: total, message: '排版第 ' + (i + 1) + '/' + total + ' 页' });
        }
        if (i % 50 === 0) {
          console.info('[PdfExport] page ' + i + '/' + total + ' pss=' + Math.round(currentPssKb() / 1024)
            + 'MB cost ' + (Date.now() - t0) + 'ms');
        }
        // 内存监控：软上限只告警并继续，硬上限才中止，避免大谱基础占用高被误判
        if (i > 0 && i % MEMORY_CHECK_EVERY_PAGES === 0) {
          const pssKb: number = currentPssKb();
          const growthKb: number = basePssKb > 0 && pssKb > 0 ? pssKb - basePssKb : -1;
          if (pssKb > 0 && (pssKb > MEMORY_SOFT_LIMIT_KB ||
            growthKb > MEMORY_GROWTH_LIMIT_KB)) {
            console.info('[PdfExport] memory high, pss=' + Math.round(pssKb / 1024) +
              'MB base=' + Math.round(basePssKb / 1024) + 'MB growth=' +
              Math.round(growthKb / 1024) + 'MB, page=' + i + '/' + total);
          }
          if (pssKb > MEMORY_HARD_LIMIT_KB) {
            throw new Error('导出内存占用过高（PSS ' + Math.round(pssKb / 1024) +
              'MB，较导出开始增长 ' + Math.round(growthKb / 1024) +
              'MB，第 ' + i + '/' + total + ' 页）。请减少单卷人数后重试');
          }
        }
        await yieldToUi(); // 每页让出一个时间片，避免主线程被看门狗判定无响应
      }
      const t1: number = Date.now();
      // 保存是同步 Native 调用，先让最后一页进度渲染出来
      await yieldToUi();
      saved = doc.saveDocument(outPath);
      let savedSize: number = -1;
      try {
        savedSize = fileIo.statSync(outPath).size;
      } catch (_e) {
        savedSize = -1;
      }
      console.info('[PdfExport] save ' + saved + ' cost ' + (Date.now() - t1) + 'ms, pages=' + total
        + ', size=' + savedSize);
    } finally {
      // 无论正常结束、抛错还是内存中止，都释放 native 文档，避免 native 内存泄漏累积
      doc.releaseDocument();
    }
    if (!saved) {
      throw new Error('PDF 保存失败');
    }

    if (onProgress) {
      onProgress({ current: total + 1, total: total + 1, message: '完成' });
    }
    return outPath;
  }
}
