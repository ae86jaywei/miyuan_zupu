import { pdfService } from '@kit.PDFKit';
import { T } from 'common_base';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { currentPssKb, PDF_MEMORY_HARD_LIMIT_KB } from './pdf/PdfMemory';
import { Person, SpouseRelation } from 'common_base';
import { PersonNode } from 'common_base';
import { Genealogy } from 'common_base';
import { generationLabel } from 'common_base';
import { GenealogyService } from './GenealogyService';
import { TreeLayoutCache } from 'common_base';
import { RawPdfWriter, PdfTextLine, PdfInfo, PdfRule } from './RawPdfWriter';
import { RawPdfFont } from './RawPdfFont';
import { PdfFontUtil } from './PdfFontUtil';
import { PageSpec as PrintPageSpec } from './PrintLayout';
import { DieJiIndex, DieJiText, DieJiRefOptions, DieJiNameRange, DieJiBlock, DIE_SPACE, DieJiStyle } from './DieJiText';
import {
  BranchInfo, FamilyUnit, KinshipIndex, TextLine, TextRun, charWidth, lineHOf
} from './pdf/PdfTextCompose';
import {
  C_BG, C_FEMALE, C_GOLD, C_INK, C_INK2, C_INK3, CONTENT_H, CONTENT_W, MARGIN_BOTTOM, MARGIN_LR,
  MARGIN_TOP, PAGE_H, PAGE_W, PageSpec, bigSpacerLine, pushAll, pushAllPages, replaceParens,
  spacerLine, todayStr, wrapLines, wrapStyledLines
} from './pdf/PdfTextKit';

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

// ─── 度量画布尺寸（仅用于创建 OffscreenCanvas，宽度不再参与字宽换算） ──
const CANVAS_W: number = 1191;
const CANVAS_H: number = 1684;

// ─── 导出内存看门狗常量 ───────────────────────────────────
// 逐页写 PDF 时监控进程 PSS，超过硬上限就主动抛可捕获错误并提示分卷，
// 避免 PDFKit 在 native 层耗尽内存被系统直接杀死（进程级崩溃，HiLog 无记录）。
// 硬上限保护异常增长，避免大谱基础占用高被误判。
const MEMORY_CHECK_EVERY_PAGES: number = 16;

// ─── 颜色（打印固定浅色） ─────────────────────────────────

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
  /** 牒记版式：true=仿古竖排（右起左行、从上到下），缺省=现代横排 */
  classicLayout?: boolean;
  /** 牒记文风：classic=文言（默认），modern=现代白话；与屏幕阅读方式共用 */
  dieJiStyle?: string;
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


// ─── 内容构建 ─────────────────────────────────────────────

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
      // 男性 +3 高于「有父母」+2：夫妻同组时锚点优先落在男方，
      // 避免妻子的父母记录让锚点变成妻子（夫妻顺序颠倒、世代跟着配偶走）
      if (p.gender === '男') {
        score += 3;
      }
      if (score > bestScore) {
        bestScore = score;
        anchor = idxs[i];
      }
    }
    const unit: FamilyUnit = new FamilyUnit();
    // 家庭单元的世代取组内最小有效世代：配偶/错挂关系的世代即使录成后代，
    // 也不会把整条（尤其是第一世始迁祖）抬到后面的世代去，导致正文缺第一世。
    let minGen: number = 0;
    for (let i: number = 0; i < idxs.length; i++) {
      const g: number = people[idxs[i]].generation;
      if (g > 0 && (minGen === 0 || g < minGen)) {
        minGen = g;
      }
    }
    unit.generation = minGen;
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
  /** 同一家庭单元（本人+配偶）共用一个 unitId：用于识别夫妻关系；
   *  分页按“剩余不足 3 行才换页”处理，必要时允许条目跨页续写 */
  unitId: string;
  lines: TextLine[];
}

/** 分页结果：页内容 + 人物所在页码（1 起，含前置页偏移） */
interface PaginateResult {
  pages: PageSpec[];
  uidPage: Map<string, number>;
}

// 牒记正文由 DieJiText 统一生成；PDF 的 UID / 页码互引通过 DieJiRefOptions 打开。
/** 跨卷位置：uid →「第2卷358页」，分卷导出第二遍排版时回填 */
let gCrossRef: Map<string, string> | null = null;

// ─── 条目字号 ─────────────────────────────────────────────
// 牒记排版规范：姓名 小二号（18pt）加粗，正文 四号（14pt），括号引用 五号（10.5pt），
// 除姓名外一律不加粗。与屏幕 DieRecord 的 18/14/10.5 fp 一一对应。
const F_NAME: number = 18;      // 牒记姓名：18pt 加粗
const H_NAME: number = 32;
const F_DETAIL: number = 14;    // 正文：14pt 常规
const H_DETAIL: number = 24.5;
const F_REF: number = 10.5;     // 「（F001）」「（M001·第2页）」：10.5pt 常规
/** 项目符号：正文按语义块分条，首句「讳XX公」不加 */
const BULLET: string = '\u2022';



/** 补齐行：只占高度，不写文本对象（用于对齐两遍排版的行数） */
function padLine(): TextLine {
  return { text: ' ', font: F_DETAIL, lineH: H_DETAIL, color: C_BG, bold: false, indent: 0, center: false };
}

/**
 * 一个人物的牒记条目。
 * 正文统一由 DieJiText 生成（与屏幕 / Markdown 同一套文言句式），
 * 这里按「生卒 / 配偶 / 子嗣 / 学职 / 生平 / 墓葬」分条，非首条加项目符号。
 * refs 非空时在正文中写 UID 与页码互引。
 */
function personEntryLines(ctx: OffscreenCanvasRenderingContext2D, p: Person,
  dieIndex: DieJiIndex, refs: Map<string, number> | null,
  contentW: number = CONTENT_W, dieJiStyle: string = DieJiStyle.CLASSIC): TextLine[] {
  const lines: TextLine[] = [];
  const opts: DieJiRefOptions = new DieJiRefOptions();
  opts.enabled = true;
  opts.refs = refs;
  opts.crossRef = gCrossRef;
  opts.style = dieJiStyle === DieJiStyle.MODERN ? DieJiStyle.MODERN : DieJiStyle.CLASSIC;
  const nameColor: string = p.gender === '女' ? C_FEMALE : C_INK;
  const blocks: DieJiBlock[] = DieJiText.blocks(p, dieIndex, opts);
  for (let bi: number = 0; bi < blocks.length; bi++) {
    const block: DieJiBlock = blocks[bi];
    const prefix: string = block.bullet ? BULLET + DIE_SPACE : '';
    const body: string = prefix + block.text;
    // 项目符号后留一个全角空隙；折行时续行缩进到正文起点，形成悬挂缩进
    const hanging: number = block.bullet
      ? charWidth(ctx, BULLET, F_DETAIL) + charWidth(ctx, DIE_SPACE, F_DETAIL) : 0;
    pushAll(lines, wrapStyledLines(ctx, body, DieJiText.nameRanges(p, body, dieIndex),
      DieJiText.refRanges(body), F_DETAIL, C_INK, F_NAME, nameColor,
      F_REF, C_INK2, 0, contentW, hanging));
  }
  // 人物之间空两行，避免现代横版连续排版时挤在一起
  for (let k: number = 0; k < 2; k++) {
    lines.push({ text: ' ', font: F_DETAIL, lineH: H_DETAIL, color: C_BG, bold: false, indent: 0, center: false });
  }
  return lines;
}

/**
 * 谱内是否缺第一世：最小有效世代大于 1，且谱中没有「第一世同名」的始迁祖。
 * 用于整谱牒记正文补一条始迁祖条目，避免正文直接从第二世开始。
 */
function needsAncestorEntry(people: Person[], units: FamilyUnit[], ancestorName: string): boolean {
  const name: string = ancestorName.trim();
  if (name.length === 0) {
    return false;
  }
  // 已录入且世代不大于 1 的始迁祖：正文会正常出现，不重复补条目
  for (let i: number = 0; i < people.length; i++) {
    if (people[i].name.trim() === name && people[i].generation <= 1) {
      return false;
    }
  }
  let minGen: number = 0;
  for (let i: number = 0; i < units.length; i++) {
    const g: number = units[i].generation;
    if (g > 0 && (minGen === 0 || g < minGen)) {
      minGen = g;
    }
  }
  return minGen > 1;
}

/**
 * 世系条目：世代分隔头 + 逐人条目。
 * 排序以「家庭单元」为单位（见 buildFamilyUnits）：夫妻无论世代是否录得一致都紧挨着输出。
 * 分页时只要当前页剩余不少于 3 行就继续在本页写，写满后按行续到下一页。
 * ancestorName 非空且谱内缺第一世时，正文最前面补「第一世 · 始迁祖」条目。
 */
async function buildGenealogyEntries(ctx: OffscreenCanvasRenderingContext2D, people: Person[],
  kinIndex: KinshipIndex, refs: Map<string, number> | null,
  contentW: number = CONTENT_W, ancestorName: string = '',
  dieIndex?: DieJiIndex, dieJiStyle: string = DieJiStyle.CLASSIC): Promise<EntryBlock[]> {
  const index: DieJiIndex = dieIndex === undefined ? new DieJiIndex(people) : dieIndex;
  const units: FamilyUnit[] = buildFamilyUnits(people);
  const entries: EntryBlock[] = [];
  let written: number = 0;
  // 谱内没有任何第一世人物（始迁祖未录入，或世代录入从二世起）时，
  // 用谱信息里的始迁祖姓名补出第一世条目，避免正文直接从第二世开始。
  if (needsAncestorEntry(people, units, ancestorName)) {
    entries.push({
      uid: '',
      unitId: 'ancestor#1',
      lines: [
        { text: generationLabel(1), font: 15, lineH: 30, color: C_INK, bold: false, indent: 0, center: false },
        { text: ancestorName.trim(), font: F_NAME, lineH: H_NAME, color: C_INK, bold: true, indent: 0, center: false },
        { text: '（' + generationLabel(1) + '）', font: F_DETAIL, lineH: H_DETAIL, color: C_INK, bold: false, indent: 0, center: false },
        { text: '谱载始迁祖' + DIE_SPACE + '本谱世系自此始', font: F_DETAIL, lineH: H_DETAIL, color: C_INK2, bold: false, indent: 10, center: false },
        { text: ' ', font: 8, lineH: 12, color: C_BG, bold: false, indent: 0, center: false }
      ]
    });
  }
  // 每个人物条目前都写「第X世」小标题：同一世代多人时，每人仍有自己的小标题
  for (let i: number = 0; i < units.length; i++) {
    const unit: FamilyUnit = units[i];
    const heading: string = generationLabel(unit.generation);
    const unitId: string = unit.anchorUid + '#' + unit.generation.toString();
    for (let j: number = 0; j < unit.members.length; j++) {
      const p: Person = unit.members[j];
      const lines: TextLine[] = personEntryLines(ctx, p, index, refs, contentW, dieJiStyle);
      lines.unshift({
        text: heading,
        font: 15, lineH: 30, color: C_INK, bold: false, indent: 0, center: false
      });
      entries.push({
        uid: p.uid.trim().toUpperCase(),
        unitId: unitId,
        lines: lines
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


/** 正文每页栏数（三段）与栏间距 */
const COLUMNS: number = 3;
const COLUMN_GAP: number = 14;
/** 现代版横向三段（上中下）的段间距 */
const SEGMENT_GAP: number = 12;

/** 仿古版三段竖排分页：列流连续排版，多人同段，段满才换段 */
async function paginateEntriesVerticalColumns(entries: EntryBlock[], pageOffset: number,
  contentW: number, contentH: number): Promise<PaginateResult> {
  // 仿古版同样是上中下三段横条，但段内文字竖排
  const segmentH: number = (contentH - SEGMENT_GAP * (COLUMNS - 1)) / COLUMNS;
  const flow: VerticalColumnFlow = new VerticalColumnFlow(contentW, segmentH, '世 系', COLUMNS);
  const uidPage: Map<string, number> = new Map<string, number>();
  let processed: number = 0;
  let nextYield: number = 200;
  for (let i: number = 0; i < entries.length; i = i + 1) {
    const e: EntryBlock = entries[i];
    for (let j: number = 0; j < e.lines.length; j = j + 1) {
      const ln: TextLine = e.lines[j];
      if (ln.text.trim().length === 0) {
        // 正文人物间空行在竖排不占列；只有封面 spacer 才占一列
        if (ln.columnGap === true) {
          flow.addGap(ln.font);
        }
        continue;
      }
      flow.addLine(ln);
      // 页码记在人物第一条行所在的那一段（跨段续写时不是末页）
      if (j === 0 && e.uid.length > 0) {
        uidPage.set(e.uid, pageOffset + Math.floor(flow.pages.length / COLUMNS) + 1);
      }
    }
    processed = processed + 1;
    if (processed >= nextYield) {
      nextYield = nextYield + 200;
      await yieldToUi();
    }
  }
  return { pages: flow.finish(), uidPage: uidPage };
}

/**
 * 流式分页：把「世代分隔头 + 条目」按行切到 A4 页内。
 * 一人内容超过一页时按行续到下一页，不再溢出页脚；
 * 只有当当前页剩余不足 3 行时，下一个人（或世代头）才换页，避免页面大片空白。
 */
async function paginateEntries(entries: EntryBlock[], pageOffset: number,
  contentH: number = CONTENT_H): Promise<PaginateResult> {
  const pages: PageSpec[] = [];
  const uidPage: Map<string, number> = new Map<string, number>();
  let cur: TextLine[] = [];
  let used: number = 0;
  // 至少还能放下 3 行正文才在本页起写下一人；否则换页，避免页尾只剩一两行
  const minTail: number = H_DETAIL * 3;
  const flush = (): void => {
    if (cur.length > 0) {
      pages.push({ lines: cur, chapter: '世 系' });
      cur = [];
      used = 0;
    }
  };
  let processed: number = 0;
  let nextYield: number = 200;
  for (let i: number = 0; i < entries.length; i = i + 1) {
    const e: EntryBlock = entries[i];
    if (e.uid.length === 0) {
      // 世代分隔头跟随本节第一个人物：标题 + 至少 3 行正文放不下时一起换页，
      // 避免标题孤零零留在页尾
      const headH: number = e.lines.length > 0 ? e.lines[0].lineH : 0;
      if (cur.length > 0 && contentH - used < minTail + headH) {
        flush();
      }
    } else if (cur.length > 0 && contentH - used < minTail) {
      // 剩余不足 3 行：整条换页再开始写
      flush();
    }
    const startPage: number = pageOffset + pages.length + 1;
    for (let j: number = 0; j < e.lines.length; j = j + 1) {
      const ln: TextLine = e.lines[j];
      // 一人一条允许跨页：本页写满就续到下一页（不再让整条溢出页脚）
      if (cur.length > 0 && used + ln.lineH > contentH) {
        flush();
        // 续页页首不写条目末尾的空白占位行
        if (ln.text.trim().length === 0 && ln.color === C_BG) {
          continue;
        }
      }
      cur.push(ln);
      used = used + ln.lineH;
    }
    if (e.uid.length > 0) {
      // 页码记在人物开始的那一页（跨页续写时不是末页）
      uidPage.set(e.uid, startPage);
    }
    processed = processed + 1;
    // 与条目构建同样分片让出，避免大谱一次分页长时间占住主线程
    if (processed >= nextYield) {
      nextYield = nextYield + 200;
      await yieldToUi();
    }
  }
  flush();
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

// ─── 仿古竖排（右起左行、从上到下） ───────────────────────

/** 竖排字号上限：标题不压过正文，避免单字占满一列 */
const CLASSIC_MAX_FONT: number = 22;
/** 竖排列间距（pt） */
const CLASSIC_COL_GAP: number = 6;

function classicFont(font: number): number {
  return Math.min(font, CLASSIC_MAX_FONT);
}

/** 同一列内相邻字的步长 */
function classicStep(font: number): number {
  return Math.round(classicFont(font) * 1.18 * 10) / 10;
}

/** 一列占用的版心宽度 */
function classicColW(font: number): number {
  return classicStep(font) + CLASSIC_COL_GAP;
}

/** 遍历一行的所有字符（runs 或纯文本），回调每个字符的原始字号 */
function iterLineChars(ln: TextLine, cb: (font: number) => void): void {
  if (ln.runs !== undefined && ln.runs.length > 0) {
    for (let ri: number = 0; ri < ln.runs.length; ri = ri + 1) {
      const run: TextRun = ln.runs[ri];
      const full: string = replaceParens(T(run.text), true);
      let ci: number = 0;
      while (ci < full.length) {
        const cp: number = full.codePointAt(ci) ?? 0;
        cb(run.font);
        ci = ci + (cp > 0xffff ? 2 : 1);
      }
    }
    return;
  }
  const full: string = replaceParens(T(ln.text), true);
  let ci: number = 0;
  while (ci < full.length) {
    const cp: number = full.codePointAt(ci) ?? 0;
    cb(ln.font);
    ci = ci + (cp > 0xffff ? 2 : 1);
  }
}

/**
 * 仿古竖排列流：所有行的字符连续填入当前列，列满换列、段满换段。
 * 分页与绘制共用同一套累加规则，段内列数与绘制完全一致，
 * 不会出现「前一列没满却换列」或「段尾整列空白」。
 */
class VerticalColumnFlow {
  readonly contentW: number;
  readonly segmentH: number;
  readonly chapter: string;
  readonly columnsPerPage: number;
  pages: PageSpec[] = [];
  cur: TextLine[] = [];
  usedW: number = 0;
  colUsed: number = 0;
  colW: number = 0;
  column: number = 0;

  constructor(contentW: number, segmentH: number, chapter: string, columnsPerPage: number) {
    this.contentW = contentW;
    this.segmentH = segmentH;
    this.chapter = chapter;
    this.columnsPerPage = columnsPerPage;
  }

  private curColW(): number {
    return this.colUsed > 0 ? this.colW : 0;
  }

  private flush(): void {
    if (this.cur.length > 0) {
      const spec: PageSpec = { lines: this.cur, chapter: this.chapter, column: this.column };
      if (this.columnsPerPage > 1) {
        spec.columnW = this.contentW;
      }
      this.pages.push(spec);
      this.cur = [];
      this.usedW = 0;
      this.colUsed = 0;
      this.colW = 0;
      this.column = (this.column + 1) % this.columnsPerPage;
    }
  }

  /** 段内换列：当前列宽度计入段宽；段已满则换段 */
  private nextColumn(): void {
    if (this.colUsed > 0) {
      this.usedW += this.colW;
      this.colUsed = 0;
      this.colW = 0;
    }
    if (this.usedW >= this.contentW - 0.01) {
      this.flush();
    }
  }

  /** 占一列空白（封面 spacer） */
  addGap(font: number): void {
    this.nextColumn();
    this.usedW += classicColW(font);
    if (this.usedW >= this.contentW - 0.01) {
      this.flush();
    }
  }

  /** 追加一行：先模拟该行新增的完成列宽度，再实际累加，段边界不落在行中间 */
  addLine(ln: TextLine): void {
    let simUsed: number = this.colUsed;
    let simColW: number = this.colW;
    let extra: number = 0;
    iterLineChars(ln, (font: number): void => {
      const st: number = classicStep(font);
      if (simUsed > 0 && simUsed + st > this.segmentH - 6) {
        extra = extra + simColW;
        simUsed = 0;
        simColW = 0;
      }
      simUsed = simUsed + st;
      const cw: number = classicColW(font);
      if (cw > simColW) {
        simColW = cw;
      }
    });
    if (this.usedW + this.curColW() + extra > this.contentW && this.cur.length > 0) {
      this.flush();
    }
    iterLineChars(ln, (font: number): void => {
      const st: number = classicStep(font);
      if (this.colUsed > 0 && this.colUsed + st > this.segmentH - 6) {
        this.usedW += this.colW;
        this.colUsed = 0;
        this.colW = 0;
      }
      this.colUsed = this.colUsed + st;
      const cw: number = classicColW(font);
      if (cw > this.colW) {
        this.colW = cw;
      }
    });
    this.cur.push(ln);
  }

  finish(): PageSpec[] {
    this.flush();
    return this.pages;
  }
}

/** 仿古竖排分页：列流连续排版，超出版心宽换段 */
function paginateLinesVertical(lines: TextLine[], chapter: string,
  contentW: number, contentH: number): PageSpec[] {
  if (lines.length === 0) {
    return [];
  }
  const flow: VerticalColumnFlow = new VerticalColumnFlow(contentW, contentH, chapter, 1);
  for (let i: number = 0; i < lines.length; i = i + 1) {
    const ln: TextLine = lines[i];
    if (ln.text.trim().length === 0) {
      if (ln.columnGap === true) {
        flow.addGap(ln.font);
      }
      continue;
    }
    flow.addLine(ln);
  }
  return flow.finish();
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

/** 文本宽度（pt）：逐字累加，与 PDF 实际落字宽度严格一致（不再依赖 measureText） */
function measurePt(ctx: OffscreenCanvasRenderingContext2D, text: string, font: number): number {
  let w: number = 0;
  let i: number = 0;
  while (i < text.length) {
    const cp: number = text.codePointAt(i) ?? 0;
    const step: number = cp > 0xffff ? 2 : 1;
    w = w + charWidth(ctx, text.substring(i, i + step), font);
    i = i + step;
  }
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

  /** 谱内始迁祖：优先谱信息里的始迁祖姓名，其次最小世代、谱内无父母者 */
  private static ancestorPerson(people: Person[], byUid: Map<string, Person>): Person | null {
    const bookName: string = GenealogyService.getInstance().getBook().ancestorName.trim();
    const named: Person[] = [];
    let minGen: number = 0;
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      if (bookName.length > 0 && p.name.trim() === bookName) {
        named.push(p);
      }
      if (p.generation > 0 && (minGen === 0 || p.generation < minGen)) {
        minGen = p.generation;
      }
    }
    if (named.length > 0) {
      return PdfExportService.pickFounder(named, byUid);
    }
    if (minGen <= 0) {
      return null;
    }
    const founders: Person[] = [];
    for (let i: number = 0; i < people.length; i = i + 1) {
      if (people[i].generation === minGen) {
        founders.push(people[i]);
      }
    }
    return PdfExportService.pickFounder(founders, byUid);
  }

  /** 同世代多人时：谱内无父母 > 男 > UID，保证选到真正的始祖而非同世旁支 */
  private static pickFounder(list: Person[], byUid: Map<string, Person>): Person | null {
    let best: Person | null = null;
    let bestScore: number = -1;
    for (let i: number = 0; i < list.length; i = i + 1) {
      const p: Person = list[i];
      const f: string = p.fatherId.trim().toUpperCase();
      const m: string = p.motherId.trim().toUpperCase();
      const noParent: boolean = (f.length === 0 || !byUid.has(f)) && (m.length === 0 || !byUid.has(m));
      let score: number = 0;
      if (noParent) {
        score += 2;
      }
      if (p.gender === '男') {
        score += 1;
      }
      if (score > bestScore || (score === bestScore && best !== null && p.uid < best.uid)) {
        bestScore = score;
        best = p;
      }
    }
    return best;
  }

  /** 排行序：长房优先（长子 0、次子 1、其余 2），用于同世代房支定长幼 */
  private static rankOrder(rank: string): number {
    if (rank.indexOf('长') >= 0) {
      return 0;
    }
    if (rank.indexOf('次') >= 0) {
      return 1;
    }
    return 2;
  }

  /**
   * 选长子房组：优先始迁祖的子女所在组，其次世代最早、排行最长。
   * 返回空串表示找不到可并入的房支。
   */
  private static eldestBranchKey(order: string[], groups: Map<string, Person[]>,
    byUid: Map<string, Person>, ancestorUid: string, skipKey: string): string {
    let bestKey: string = '';
    let bestScore: number = -1;
    const au: string = ancestorUid.trim().toUpperCase();
    for (let i: number = 0; i < order.length; i = i + 1) {
      const key: string = order[i];
      if (key === skipKey) {
        continue;
      }
      const list: Person[] | undefined = groups.get(key);
      if (list === undefined || list.length === 0) {
        continue;
      }
      const rootP: Person | undefined = byUid.get(key.trim().toUpperCase());
      const p: Person = rootP !== undefined ? rootP : list[0];
      const isChild: boolean = p.fatherId.trim().toUpperCase() === au || p.motherId.trim().toUpperCase() === au;
      const gen: number = p.generation > 0 ? p.generation : 99;
      const score: number = (isChild ? 1000 : 0) + (100 - Math.min(gen, 99)) * 10 +
        (10 - PdfExportService.rankOrder(p.rank));
      if (score > bestScore) {
        bestScore = score;
        bestKey = key;
      }
    }
    return bestKey;
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
    // 小房不单独成卷：几十个「一房一卷」会让每卷都建文档/保存，导出时间成倍增加，
    // 也更容易在中途触发系统内存回收。这里只让大房独立成卷，小房合并为合卷。
    const minSingle: number = Math.max(200, Math.floor(maxPerVolume / 2));
    // 始迁祖（谱内最早世代）不能沉到最后一卷的「合卷」里：
    // 并到长子房组，并把该组排到最前，第一卷从第一世始迁祖开始，长子一房紧随其后。
    const byUid: Map<string, Person> = new Map<string, Person>();
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      if (index.has(p.uid.trim().toUpperCase())) {
        byUid.set(p.uid.trim().toUpperCase(), p);
      }
    }
    const ancestor: Person | null = PdfExportService.ancestorPerson(people, byUid);
    if (ancestor !== null) {
      const aInfo: BranchInfo | undefined = index.get(ancestor.uid.trim().toUpperCase());
      const ancestorKey: string = aInfo !== undefined ? aInfo.rootUid : '';
      if (ancestorKey.length > 0 && groups.has(ancestorKey)) {
        const ancList: Person[] | undefined = groups.get(ancestorKey);
        // 始迁祖组本身就是大房时不并入别房，只把它所在的卷排到最前
        const smallAncestor: boolean = ancList !== undefined && ancList.length < minSingle;
        let mergedKey: string = '';
        if (smallAncestor) {
          const homeKey: string = PdfExportService.eldestBranchKey(order, groups, byUid,
            ancestor.uid, ancestorKey);
          if (homeKey.length > 0) {
            const homeList: Person[] | undefined = groups.get(homeKey);
            if (homeList !== undefined) {
              groups.delete(ancestorKey);
              const ai2: number = order.indexOf(ancestorKey);
              if (ai2 >= 0) {
                order.splice(ai2, 1);
              }
              // 始迁祖一家放在长子房组最前：分页后第一卷首条即第一世家
              groups.set(homeKey, (ancList as Person[]).concat(homeList));
              mergedKey = homeKey;
            }
          }
        }
        const firstKey: string = mergedKey.length > 0 ? mergedKey : ancestorKey;
        const hi: number = order.indexOf(firstKey);
        if (hi > 0) {
          order.splice(hi, 1);
          order.unshift(firstKey);
        }
      }
    }
    const volumes: PdfVolume[] = [];
    let mergePeople: Person[] = [];
    let mergeNameCount: number = 0;
    for (let g: number = 0; g < order.length; g = g + 1) {
      const key: string = order[g];
      const list: Person[] | undefined = groups.get(key);
      if (list === undefined || list.length === 0) {
        continue;
      }
      const firstInfo: BranchInfo | undefined =
        index.get(key.trim().toUpperCase()) ?? index.get(list[0].uid.trim().toUpperCase());
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
    includeCover: boolean,
    classicLayout: boolean = false,
    dieJiStyle: string = DieJiStyle.CLASSIC
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
    // 牒记正文与分卷页码同源：关系索引一次建好，各卷复用
    const dieIndex: DieJiIndex = new DieJiIndex(people);
    for (let i: number = 0; i < jobs.length; i++) {
      const vol: PdfVolume = jobs[i];
      const coverPages: PageSpec[] = includeCover
        ? paginateLines(ctx, buildCover(book, vol.people.length, vol.title), '封 面', 0, contentH) : [];
      const prefacePages: PageSpec[] = classicLayout
        ? paginateLinesVertical(buildPreface(ctx, book, contentW), '谱 序', contentW, contentH)
        : paginateLines(ctx, buildPreface(ctx, book, contentW), '谱 序', 36, contentH);
      const offset: number = coverPages.length + prefacePages.length;
      const entries: EntryBlock[] =
        await buildGenealogyEntries(ctx, vol.people, kinIndex, null, contentW,
          jobs.length === 1 ? book.ancestorName : '', dieIndex, dieJiStyle);
      const pg: PaginateResult = classicLayout
        ? await paginateEntriesVerticalColumns(entries, offset, contentW, contentH)
        : await paginateEntries(entries, offset, contentH);
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
    // 牒记版式：仿古竖排时按列分页、逐字右起左行；封面仍横排
    const classic: boolean = options.classicLayout === true;
    // 牒记文风：文言 / 现代白话，与屏幕阅读方式保持同一设置
    const dieJiStyle: string = options.dieJiStyle === DieJiStyle.MODERN
      ? DieJiStyle.MODERN : DieJiStyle.CLASSIC;
    const kinPeople: Person[] = (options.kinSource !== undefined && options.kinSource.length > 0)
      ? options.kinSource : people;
    const kinIndex: KinshipIndex = kinshipFor(kinPeople);
    // 牒记正文生成器：与屏幕、Markdown 共用，按全量亲缘解析配偶与子嗣
    const dieIndex: DieJiIndex = new DieJiIndex(kinPeople);
    const coverPages: PageSpec[] = options.includeCover
      ? paginateLines(ctx, buildCover(book, people.length, options.volumeTitle ?? ''), '封 面', 0,
        contentH) : [];
    const prefacePages: PageSpec[] = classic
      ? paginateLinesVertical(buildPreface(ctx, book, contentW), '谱 序', contentW, contentH)
      : paginateLines(ctx, buildPreface(ctx, book, contentW), '谱 序', 36, contentH);
    const offset: number = coverPages.length + prefacePages.length;
    // 整谱单卷导出且谱内缺第一世时，正文补「第一世 · 始迁祖」；
    // 分卷导出每卷有独立卷名，不能把总谱始迁祖写进各房支卷首。
    const ancestorForBody: string = (options.volumeTitle ?? '').length === 0 ? book.ancestorName : '';

    await yieldToUi();
    let entries1: EntryBlock[] = await buildGenealogyEntries(ctx, people, kinIndex, null, contentW,
      ancestorForBody, dieIndex, dieJiStyle);
    const firstPass: PaginateResult = classic
      ? await paginateEntriesVerticalColumns(entries1, offset, contentW, contentH)
      : await paginateEntries(entries1, offset, contentH);
    const uidPageMap: Map<string, number> = firstPass.uidPage;
    // 第二遍排版回填真实页码；分卷时用跨卷位置兜底
    gCrossRef = (options.crossRef !== undefined) ? options.crossRef : null;
    const heights: Map<string, number> = new Map<string, number>();
    for (let i: number = 0; i < entries1.length; i = i + 1) {
      heights.set(entries1[i].uid, entries1[i].lines.length);
    }
    entries1 = [];
    firstPass.pages = [];
    let entries2: EntryBlock[] =
      await buildGenealogyEntries(ctx, people, kinIndex, uidPageMap, contentW, ancestorForBody, dieIndex, dieJiStyle);
    if (!classic) {
      // 横排版靠补空行稳住两遍分页；竖排按字符数分页，补空行反而会多占列
      for (let i: number = 0; i < entries2.length; i = i + 1) {
        const e: EntryBlock = entries2[i];
        const want: number | undefined = heights.get(e.uid);
        if (want !== undefined) {
          while (e.lines.length < want) {
            e.lines.push(padLine());
          }
        }
      }
    }
    let genealogyPages: PageSpec[] = classic
      ? (await paginateEntriesVerticalColumns(entries2, offset, contentW, contentH)).pages
      : (await paginateEntries(entries2, offset, contentH)).pages;
    gCrossRef = null;
    
    const backPages: PageSpec[] = classic
      ? paginateLinesVertical(buildBack(ctx, book, contentW), '家 训', contentW, contentH)
      : paginateLines(ctx, buildBack(ctx, book, contentW), '家 训', 36, contentH);
    const all: PageSpec[] = [];
    pushAllPages(all, coverPages);
    pushAllPages(all, prefacePages);
    pushAllPages(all, genealogyPages);
    pushAllPages(all, backPages);
    entries2 = [];
    genealogyPages = [];
    // 正文按栏存放：column=0 表示新页；封面/谱序/家训一栏一页
    let pageNo: number = 0;
    for (let i: number = 0; i < all.length; i = i + 1) {
      if ((all[i].column ?? 0) === 0) {
        pageNo = pageNo + 1;
      }
      all[i].pageNo = pageNo;
    }
    const total: number = pageNo;
    if (all.length === 0 || total === 0) {
      throw new Error('排版结果为空');
    }

    const d: Date = new Date();
    const stamp: string = d.getFullYear().toString() +
      (d.getMonth() + 1).toString().padStart(2, '0') +
      d.getDate().toString().padStart(2, '0');
    const vol: string = (options.volumeTitle !== undefined && options.volumeTitle.length > 0)
      ? '_' + options.volumeTitle : '';
    const outPath: string = outDir + '/' + book.title + vol + '_' + stamp + '.pdf';

    const rawFont: RawPdfFont | null = PdfFontUtil.rawFont();
    const info: PdfInfo = new PdfInfo(book.title +
      (options.volumeTitle !== undefined && options.volumeTitle.length > 0
        ? ' ' + options.volumeTitle : ''));
    const writer: RawPdfWriter = new RawPdfWriter(outPath,
      PrintPageSpec.mmToPt(printSpec.trimW), PrintPageSpec.mmToPt(printSpec.trimH),
      0, 0, rawFont, info);
    const gutterW: number = PrintPageSpec.mmToPt(printSpec.gutter);
    let renderedPages: number = 0;
    let i: number = 0;
    while (i < all.length) {
      // 同一 pageNo 的多栏必须合并到同一张 PDF 页，否则三栏会被拆成三页
      const currentPageNo: number = all[i].pageNo ?? (i + 1);
      const recto: boolean = (currentPageNo % 2) === 1;
      const isCoverPage: boolean = i < coverPages.length;
      const pageLines: PdfTextLine[] = [];
      let title: string = '';
      let bodyPage: boolean = false;
      while (i < all.length && (all[i].pageNo ?? (i + 1)) === currentPageNo) {
        const spec: PageSpec = all[i];
        if (!isCoverPage && spec.chapter === '世 系') {
          bodyPage = true;
        }
        const lines: PdfTextLine[] = classic
          ? PdfExportService.buildVerticalTextLines(ctx, printSpec, spec, total, recto, isCoverPage)
          : PdfExportService.buildRawTextLines(ctx, printSpec, spec, total, isCoverPage, recto);
        for (let k: number = 0; k < lines.length; k = k + 1) {
          pageLines.push(lines[k]);
        }
        if ((spec.column ?? 0) === 0 && title.length === 0) {
          title = PdfExportService.rawBookmark(spec, i, coverPages.length);
        }
        i = i + 1;
      }
      // 仿古版：正文三段各画一条段底细实线，作为牒记分栏的下边框
      const rules: PdfRule[] = [];
      if (classic && bodyPage) {
        const segH: number = (contentH - SEGMENT_GAP * (COLUMNS - 1)) / COLUMNS;
        const innerY: number = PrintPageSpec.mmToPt(printSpec.innerY());
        const innerX: number = dieInnerX(printSpec, recto);
        for (let c: number = 0; c < COLUMNS; c = c + 1) {
          const bottomTop: number = innerY + c * (segH + SEGMENT_GAP) + segH;
          const rule: PdfRule = new PdfRule();
          rule.x1Pt = innerX;
          rule.y1Pt = PAGE_H - bottomTop;
          rule.x2Pt = innerX + contentW;
          rule.y2Pt = rule.y1Pt;
          rule.widthPt = 0.6;
          rule.color = C_INK;
          rules.push(rule);
        }
      }
      writer.addTextLinePage(pageLines, title,
        PrintPageSpec.mmToPt(printSpec.gutterX(recto)), gutterW, rules);
      renderedPages = renderedPages + 1;
      if (onProgress && (renderedPages % 5 === 0 || i === all.length)) {
        onProgress({ current: renderedPages, total: total,
          message: T('排版第 ') + renderedPages + '/' + total + ' 页' });
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
    printSpec: PrintPageSpec, spec: PageSpec, total: number, isCover: boolean,
    recto: boolean): PdfTextLine[] {
    const out: PdfTextLine[] = [];
    // 版心起点随装订侧变化：装订侧留 gutter + safeInset，双面时奇偶页镜像
    const contentW: number = dieContentW(printSpec);
    const innerX: number = dieInnerX(printSpec, recto);
    const innerY: number = PrintPageSpec.mmToPt(printSpec.innerY());
    const contentH: number = dieContentH(printSpec);
    const pageNo: number = spec.pageNo ?? 1;
    // 现代版是上中下三段横条：每段横向铺满版心，段号决定纵向下移
    const col: number = spec.column ?? 0;
    const segmentH: number = (contentH - SEGMENT_GAP * (COLUMNS - 1)) / COLUMNS;
    const x0: number = innerX;
    const centerX: number = innerX + contentW / 2;
    let y: number = isCover ? 0 : innerY + col * (segmentH + SEGMENT_GAP);
    for (let i: number = 0; i < spec.lines.length; i = i + 1) {
      const ln: TextLine = spec.lines[i];
      if (ln.runs !== undefined && ln.runs.length > 0) {
        // 混排行：姓名 30pt、正文 12.5pt、引用 10.5pt，同一基线按 run 整段排
        let rx: number = x0 + ln.indent;
        const baseY: number = baselineOf(y, ln.font);
        for (let ri: number = 0; ri < ln.runs.length; ri++) {
          const run: TextRun = ln.runs[ri];
          const runText: string = replaceParens(run.text, false);
          if (runText.length === 0) {
            continue;
          }
          // 一个 run 写成一个文本对象：run 内的字距交给 PDF 字体自身的 /W 字宽表，
          // 不再逐字定位。逐字定位一旦宽度估偏，英文/数字就会全部叠在同一点。
          const r: PdfTextLine = new PdfTextLine();
          r.text = runText;
          r.xPt = rx;
          r.yPt = baseY;
          r.sizePt = run.font;
          r.color = run.color;
          r.bold = run.bold;
          out.push(r);
          rx = rx + measurePt(ctx, runText, run.font);
        }
      } else if (ln.text.trim().length > 0) {
        const r: PdfTextLine = new PdfTextLine();
        r.text = replaceParens(ln.text, false);
        r.xPt = ln.center ? centerX - measurePt(ctx, ln.text, ln.font) / 2
          : x0 + ln.indent;
        r.yPt = baselineOf(y, ln.font);
        r.sizePt = ln.font;
        r.color = ln.color;
        r.bold = ln.bold;
        out.push(r);
      }
      y = y + ln.lineH;
    }
    if (!isCover && col === 0) {
      // 页码整页居中，只写在每页第一栏，避免三栏重复
      const footer: string = '第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页';
      const r: PdfTextLine = new PdfTextLine();
      r.text = footer;
      r.xPt = innerX + contentW / 2 - measurePt(ctx, footer, 9.5) / 2;
      r.yPt = PrintPageSpec.mmToPt(printSpec.foot) / 2;
      r.sizePt = 9.5;
      r.color = C_INK2;
      out.push(r);
    }
    return out;
  }

  /** 仿古竖排：逐字定位，列从右往左、字从上往下；封面/谱序/家训/凡例全部竖排 */
  private static buildVerticalTextLines(ctx: OffscreenCanvasRenderingContext2D,
    printSpec: PrintPageSpec, spec: PageSpec, total: number, recto: boolean, isCover: boolean): PdfTextLine[] {
    const out: PdfTextLine[] = [];
    const contentW: number = dieContentW(printSpec);
    const contentH: number = dieContentH(printSpec);
    const innerX: number = dieInnerX(printSpec, recto);
    const innerY: number = PrintPageSpec.mmToPt(printSpec.innerY());
    const pageNo: number = spec.pageNo ?? 1;
    const col: number = spec.column ?? 0;
    // 正文三段（上中下），段内竖排；封面/谱序/家训/凡例整页竖排
    const segmented: boolean = spec.columnW !== undefined && spec.columnW > 0;
    const segmentH: number = segmented
      ? (contentH - SEGMENT_GAP * (COLUMNS - 1)) / COLUMNS : contentH;
    const y0: number = innerY + (segmented ? col * (segmentH + SEGMENT_GAP) : 0);
    // ── 仿古竖排列流：所有行字符连续填列，列满换列，段满换段 ──
    // 拍平字符流（含 columnGap 换列标记），与分页的 VerticalColumnFlow 同源
    const chars: string[] = [];
    const fonts: number[] = [];
    const colors: string[] = [];
    const bolds: boolean[] = [];
    const marks: number[] = []; // 0=字符, 1=换列标记
    for (let i: number = 0; i < spec.lines.length; i = i + 1) {
      const ln: TextLine = spec.lines[i];
      if (ln.text.trim().length === 0) {
        if (ln.columnGap === true) {
          chars.push('');
          fonts.push(ln.font);
          colors.push(ln.color);
          bolds.push(ln.bold);
          marks.push(1);
        }
        continue;
      }
      if (ln.runs !== undefined && ln.runs.length > 0) {
        for (let ri: number = 0; ri < ln.runs.length; ri = ri + 1) {
          const run: TextRun = ln.runs[ri];
          const full: string = replaceParens(T(run.text), true);
          let ci: number = 0;
          while (ci < full.length) {
            const cp: number = full.codePointAt(ci) ?? 0;
            const step: number = cp > 0xffff ? 2 : 1;
            chars.push(full.substring(ci, ci + step));
            fonts.push(run.font);
            colors.push(run.color);
            bolds.push(run.bold);
            marks.push(0);
            ci = ci + step;
          }
        }
      } else {
        const full: string = replaceParens(T(ln.text), true);
        let ci: number = 0;
        while (ci < full.length) {
          const cp: number = full.codePointAt(ci) ?? 0;
          const step: number = cp > 0xffff ? 2 : 1;
          chars.push(full.substring(ci, ci + step));
          fonts.push(ln.font);
          colors.push(ln.color);
          bolds.push(ln.bold);
          marks.push(0);
          ci = ci + step;
        }
      }
    }

    let cursorRight: number = innerX + contentW;
    let ci: number = 0;
    while (ci < chars.length) {
      if (marks[ci] === 1) {
        // spacer 占一列空白
        cursorRight = cursorRight - classicColW(fonts[ci]);
        ci = ci + 1;
        continue;
      }
      const start: number = ci;
      let used: number = 0;
      let maxFont: number = 0;
      while (ci < chars.length && marks[ci] !== 1) {
        const st: number = classicStep(fonts[ci]);
        if (ci > start && used + st > segmentH - 6) {
          break;
        }
        used = used + st;
        const f: number = classicFont(fonts[ci]);
        if (f > maxFont) {
          maxFont = f;
        }
        ci = ci + 1;
      }
      if (ci === start) {
        ci = ci + 1;
        continue;
      }
      const colX: number = cursorRight - maxFont;
      let yy: number = 0;
      for (let k: number = start; k < ci; k = k + 1) {
        const f: number = classicFont(fonts[k]);
        const r: PdfTextLine = new PdfTextLine();
        r.text = chars[k];
        r.xPt = colX;
        r.yPt = baselineOf(y0 + yy, f);
        r.sizePt = f;
        r.color = colors[k];
        r.bold = bolds[k];
        out.push(r);
        yy = yy + classicStep(fonts[k]);
      }
      cursorRight = cursorRight - classicColW(maxFont);
    }
    if (!isCover && col === 0) {
      // 页码横排居中，只写在每页第一段，避免三段重复
      const centerX: number = innerX + contentW / 2;
      const footer: string = '第 ' + pageNo.toString() + ' 页 / 共 ' + total.toString() + ' 页';
      const f: PdfTextLine = new PdfTextLine();
      f.text = footer;
      f.xPt = centerX - measurePt(ctx, footer, 9.5) / 2;
      f.yPt = PrintPageSpec.mmToPt(printSpec.foot) / 2;
      f.sizePt = 9.5;
      f.color = C_INK2;
      out.push(f);
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
    // 分卷导出时用全量人物建索引，本卷只负责排版
    const kinPeople: Person[] = (options.kinSource !== undefined && options.kinSource.length > 0)
      ? options.kinSource : people;
    const kinIndex: KinshipIndex = new KinshipIndex(kinPeople);
    const dieIndex: DieJiIndex = new DieJiIndex(kinPeople);
    const dieJiStyle: string = options.dieJiStyle === DieJiStyle.MODERN
      ? DieJiStyle.MODERN : DieJiStyle.CLASSIC;

    const coverPages: PageSpec[] = options.includeCover
      ? paginateLines(ctx, buildCover(book, people.length, options.volumeTitle ?? ''), '封 面', 0) : [];
    const prefacePages: PageSpec[] = paginateLines(ctx, buildPreface(ctx, book), '谱 序', 36);
    const offset: number = coverPages.length + prefacePages.length;
    // 整谱单卷导出且谱内缺第一世时，正文补「第一世 · 始迁祖」；分卷各房支卷首不写总谱始迁祖
    const ancestorForBody: string = (options.volumeTitle ?? '').length === 0 ? book.ancestorName : '';

    // 第一遍：用等宽页码占位排版，确定「每人落在第几页」
    // 先让进度条跑完一帧，再进入耗时的同步断行与分页
    await yieldToUi();
    let entries1: EntryBlock[] = await buildGenealogyEntries(ctx, people, kinIndex, null, CONTENT_W,
      ancestorForBody, dieIndex, dieJiStyle);
    const firstPass: PaginateResult = await paginateEntries(entries1, offset);
    // 第一遍整页排版仅用于页码映射与行数校验，取出 uidPage 后即可释放，
    // 避免其与第二遍数据同时常驻，降低大数据导出时的内存峰值
    const uidPageMap: Map<string, number> = firstPass.uidPage;
    // 第二遍排版回填真实页码；分卷时用跨卷位置兜底
    gCrossRef = (options.crossRef !== undefined) ? options.crossRef : null;
    // 第二遍：回填真实页码。占位串比真实页码长，折行数可能变少，
    // 用空行补齐到第一遍的行数，保证分页结果与页码互引完全一致
    const heights: Map<string, number> = new Map<string, number>();
    for (let i: number = 0; i < entries1.length; i++) {
      heights.set(entries1[i].uid, entries1[i].lines.length);
    }
    // 第一遍的 entries1 与整页数据到此不再需要，主动置空让 GC 回收（约一整份渲染文本）
    entries1 = [];
    firstPass.pages = [];
    let entries2: EntryBlock[] = await buildGenealogyEntries(ctx, people, kinIndex, uidPageMap, CONTENT_W,
      ancestorForBody, dieIndex, dieJiStyle);
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
      // 大谱基础 PSS 可能已有几百 MB，用「导出增量」比绝对阈值更准确
      const basePssKb: number = currentPssKb();
      for (let i: number = 0; i < total; i++) {
        drawPageToPdf(ctx, doc, all[i], i + 1, total, i < coverPages.length);
        if (onProgress && (i % 5 === 0 || i === total - 1)) {
          onProgress({ current: i + 1, total: total, message: T('排版第 ') + (i + 1) + '/' + total + ' 页' });
        }
        // 内存监控：超过硬上限才中止，避免大谱基础占用高被误判
        if (i > 0 && i % MEMORY_CHECK_EVERY_PAGES === 0) {
          const pssKb: number = currentPssKb();
          const growthKb: number = basePssKb > 0 && pssKb > 0 ? pssKb - basePssKb : -1;
          if (pssKb > PDF_MEMORY_HARD_LIMIT_KB) {
            throw new Error('导出内存占用过高（PSS ' + Math.round(pssKb / 1024) +
              'MB，较导出开始增长 ' + Math.round(growthKb / 1024) +
              'MB，第 ' + i + '/' + total + ' 页）。请减少单卷人数后重试');
          }
        }
        await yieldToUi(); // 每页让出一个时间片，避免主线程被看门狗判定无响应
      }
      // 保存是同步 Native 调用，先让最后一页进度渲染出来
      await yieldToUi();
      saved = doc.saveDocument(outPath);
      let savedSize: number = -1;
      try {
        savedSize = fileIo.statSync(outPath).size;
      } catch (_e) {
        savedSize = -1;
      }
    } finally {
      // 无论正常结束、抛错还是内存中止，都释放 native 文档，避免 native 内存泄漏累积
      doc.releaseDocument();
    }
    if (!saved) {
      throw new Error('PDF 保存失败');
    }

    if (onProgress) {
      onProgress({ current: total + 1, total: total + 1, message: T('完成') });
    }
    return outPath;
  }
}
