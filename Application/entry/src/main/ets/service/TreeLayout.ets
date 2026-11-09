import { PersonNode } from '../model/PersonNode';
import { Person, spouseRelationLevel } from '../model/Person';

/** 欧式谱一个节点在画布上的位置 */
export class EuBox {
  node: PersonNode = new PersonNode(new Person());
  x: number = 0;
  y: number = 0;
  w: number = 120;
  h: number = 64;
  centerY: number = 0;
}

/** 连线线段；red 为真表示朱砂红婚约双线，否则为金色世系连线 */
export class LineSeg {
  /** 稳定唯一 id：裁剪后数组下标会变化，不能作为 ForEach key */
  id: number = 0;
  x1: number = 0;
  y1: number = 0;
  x2: number = 0;
  y2: number = 0;
  red: boolean = false;
}

/** 配偶卡片位置（供外部读取配偶布局用） */
export class SpousePos {
  spouse: PersonNode = new PersonNode(new Person());
  index: number = 0;
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

/**
 * 页面/印刷版布局参数。
 *
 * 屏幕版的卡片宽高、行距、母线层距是按手指点击尺寸调的；印到 220×320mm 纸面时
 * 必须换成毫米口径，否则 44/62/74 会被当成毫米，卡片比整页还大。
 * 传 null 表示沿用屏幕版的原有取值，保证连续视图行为不变。
 */
export class LayoutMetrics {
  /** 主卡高度；<=0 时按屏幕版规则推导 */
  cardHeight: number = 0;
  /** 同层兄弟间距；<=0 时按叶子数自适应（屏幕版） */
  siblingGap: number = 0;
  /** 夫妻卡间距 */
  spouseGap: number = 12;
  /** 多妻竖排的卡间距 */
  stackGap: number = 6;
  /** 连线与卡框之间的留白 */
  lineGap: number = 6;
  /** 多房母线层距（苏式） */
  busStep: number = 14;
  /** 多房竖线轨道的横向错开（苏式） */
  railGap: number = 8;
  /** 苏式列间距；<=0 时用 SuLayout.COL_GAP */
  colGap: number = 0;
  /** 苏式世代行距；<0 时用 dense 规则 */
  rowGap: number = -1;
  /** 苏式左起始边距；<0 时用 SuLayout.START_X */
  startX: number = -1;
  /** 间距整体缩放系数（苏式） */
  scale: number = 1;
}

/** 夫妻双线到中轴的距离（两线共 2 倍间距，保证肉眼可见两条） */
const MARRIAGE_LINE_GAP: number = 4;

/** 追加一条普通（金色）世系线段 */
function pushLine(lines: LineSeg[], x1: number, y1: number, x2: number, y2: number): void {
  const s: LineSeg = new LineSeg();
  s.id = lines.length;
  s.x1 = x1;
  s.y1 = y1;
  s.x2 = x2;
  s.y2 = y2;
  s.red = false;
  lines.push(s);
}

/** 以线段法向量向两侧各偏移 gap，生成两条平行的红色婚约线 */
export function pushDoubleLine(lines: LineSeg[], x1: number, y1: number,
  x2: number, y2: number, gap: number): void {
  const dx: number = x2 - x1;
  const dy: number = y2 - y1;
  const len: number = Math.sqrt(dx * dx + dy * dy);
  if (len < 0.001) {
    return;
  }
  const nx: number = -dy / len;
  const ny: number = dx / len;
  const a: LineSeg = new LineSeg();
  a.red = true;
  a.x1 = x1 + nx * gap;
  a.y1 = y1 + ny * gap;
  a.x2 = x2 + nx * gap;
  a.y2 = y2 + ny * gap;
  a.id = lines.length;
  lines.push(a);
  const b: LineSeg = new LineSeg();
  b.red = true;
  b.x1 = x1 - nx * gap;
  b.y1 = y1 - ny * gap;
  b.x2 = x2 - nx * gap;
  b.y2 = y2 - ny * gap;
  b.id = lines.length;
  lines.push(b);
}

/** 全树一次遍历得到的排版统计量 */
class TreeStats {
  /** 叶子节点总数：兄弟间距按人数自适应 */
  leafCount: number = 0;
  /** 每一世（depth 从 0 开始）的最大配偶数 */
  maxSpouseAt: number[] = [];
}

/**
 * 一次 DFS 同时统计叶子数与每一世最大配偶数。
 *
 * [PERF] 原先 countLeaves / collectDepthMaxSpouse 各做一次带 visited Set 的全树遍历，
 * 大谱（数万人）下这两趟完全重复的遍历约占布局耗时的 17%；合并后只走一遍。
 */
function collectTreeStats(roots: PersonNode[], allowed: Set<string> | null = null): TreeStats {
  const stats: TreeStats = new TreeStats();
  const visited: Set<string> = new Set<string>();
  const walk = (node: PersonNode, depth: number): void => {
    if (visited.has(node.uid)) {
      return;
    }
    // 分页布局：只统计本页允许出现的节点，切线之外的旁支不能影响列宽/行高
    if (allowed !== null && !allowed.has(node.uid)) {
      return;
    }
    visited.add(node.uid);
    while (stats.maxSpouseAt.length <= depth) {
      stats.maxSpouseAt.push(0);
    }
    if (node.spouses.length > stats.maxSpouseAt[depth]) {
      stats.maxSpouseAt[depth] = node.spouses.length;
    }
    if (node.children.length === 0) {
      stats.leafCount = stats.leafCount + 1;
      return;
    }
    for (let i: number = 0; i < node.children.length; i = i + 1) {
      walk(node.children[i], depth + 1);
    }
  };
  for (let i: number = 0; i < roots.length; i = i + 1) {
    walk(roots[i], 0);
  }
  return stats;
}

/** 每一世（depth 从 0 开始）的最大配偶数 */
export function collectDepthMaxSpouse(roots: PersonNode[]): number[] {
  return collectTreeStats(roots).maxSpouseAt;
}

/** 全树最大配偶数 */
export function globalMaxSpouse(roots: PersonNode[]): number {
  const visited: Set<string> = new Set<string>();
  let max: number = 0;
  const walk = (node: PersonNode): void => {
    if (visited.has(node.uid)) {
      return;
    }
    visited.add(node.uid);
    if (node.spouses.length > max) {
      max = node.spouses.length;
    }
    node.children.forEach((c: PersonNode): void => {
      walk(c);
    });
  };
  roots.forEach((r: PersonNode): void => {
    walk(r);
  });
  return max;
}

/** 配偶名分等级：正妻 → 平妻 → 贵妾 → 良妾 → 贱妾 → 外室 → 夫 → 未记 */
function spouseRank(relation: string): number {
  const level: string = spouseRelationLevel(relation);
  switch (level) {
    case '正妻': return 0;
    case '平妻': return 1;
    case '贵妾': return 2;
    case '良妾': return 3;
    case '贱妾': return 4;
    case '外室': return 5;
    case '夫': return 6;
    case '未记': return 7;
    default: return 8;
  }
}

/**
 * 配偶卡片排列顺序下标。
 * 正庶先后：原配（正妻）最上 → 继配 → 妾室；同级保持原有先后次序（稳定排序）。
 */
export function spouseOrder(node: PersonNode): number[] {
  // [PERF] 单妻/无妻占绝大多数，避免为每张主卡分配数组并走 sort 闭包
  if (node.spouses.length <= 1) {
    return node.spouses.length === 1 ? [0] : [];
  }
  const idx: number[] = [];
  for (let i: number = 0; i < node.spouses.length; i = i + 1) {
    idx.push(i);
  }
  idx.sort((a: number, b: number): number => {
    const ra: string = a < node.spouseRelations.length ? node.spouseRelations[a] : '';
    const rb: string = b < node.spouseRelations.length ? node.spouseRelations[b] : '';
    const va: number = spouseRank(ra);
    const vb: number = spouseRank(rb);
    if (va !== vb) {
      return va - vb;
    }
    return a - b;
  });
  return idx;
}

/** 按生母分组的子女集合（同父异母的兄弟因此拆开，但仍通过父亲/母亲相连） */
class ChildGroup {
  key: string = '';
  mother: PersonNode | null = null;
  kids: PersonNode[] = [];
}

/** 把某人的子女按生母分组；无生母者归入父亲本组 */
function groupChildren(parent: PersonNode): ChildGroup[] {
  const groups: ChildGroup[] = [];
  parent.children.forEach((child: PersonNode): void => {
    const m: PersonNode | null = child.mother;
    // [PERF] 无生母时组 key 只需在本次调用内唯一，用空串即可，省去给每个子女拼接字符串
    const key: string = (m !== null && m !== undefined) ? m.uid : '';
    let hit: ChildGroup | undefined = undefined;
    for (let i: number = 0; i < groups.length; i = i + 1) {
      if (groups[i].key === key) {
        hit = groups[i];
        break;
      }
    }
    if (hit === undefined) {
      hit = new ChildGroup();
      hit.key = key;
      hit.mother = m;
      groups.push(hit);
    }
    hit.kids.push(child);
  });
  return groups;
}

/** 欧式谱画布 */
export class EuCanvas {
  boxes: EuBox[] = [];
  lines: LineSeg[] = [];
  width: number = 0;
  height: number = 0;
  /** 根节点（始祖）对应的主卡：居中定位直接命中，避免每次遍历全部 boxes */
  rootBox: EuBox | null = null;
}

/**
 * 欧式谱布局（横轴世系图）。
 *
 * 采用自底向上的“叶子计数 + 纵向堆叠”算法：
 *  - 叶子节点按内容高度（主卡 / 配偶堆叠取大者）+ 自适应兄弟间距依次下排；
 *  - 父节点的纵向中心 = 首末子节点中心的中点；
 *  - 同一层的所有节点 x 相同（= 世次列 x），第 N 世永远在第 N 列；
 *  - 配偶按“正庶先后”纵向堆叠在主卡右侧（男左女右；女方持谱即入赘则女左男右），
 *    婚约以朱砂红双线表示；
 *  - 子女按生母分组引出：各组独立母线，组内兄弟相连，不同母的子女经父母相连。
 */
export class EuLayout {
  static compute(roots: PersonNode[], cardWidth: number, rowHeight: number, colGap: number,
    showSpouse: boolean, startY: number, allowed: Set<string> | null = null,
    metrics: LayoutMetrics | null = null): EuCanvas {
    const canvas: EuCanvas = new EuCanvas();
    const placed: Map<string, EuBox> = new Map<string, EuBox>();
    /** 正在递归下钻的节点：父链若成环，下钻会无限递归导致栈溢出 */
    const visiting: Set<string> = new Set<string>();

    // 主卡高度：按卡片实际内容高度取值（渲染时卡片被固定为该高度，连线才能与卡框对齐）
    const cardH: number = (metrics !== null && metrics.cardHeight > 0)
      ? metrics.cardHeight : Math.max(44, rowHeight - 4);
    // 配偶卡与主卡同宽：渲染时按 box.w 绘制，槽位与之保持一致，避免溢出压住相邻列
    const spouseW: number = cardWidth;
    // 配偶卡与主卡等高，堆叠后中心线才能与夫卡中心线一一对齐
    const spouseH: number = cardH;
    // 夫妻卡之间留出间距，保证双线符号看得清
    const spouseGap: number = metrics !== null ? metrics.spouseGap : 12;
    // 婚约双线各自偏离中轴的距离：按卡高比例收口，纸质横版小卡上不能再用大画布的 4mm
    const marriageGap: number = Math.min(MARRIAGE_LINE_GAP, Math.max(0.45, spouseH * 0.08));
    const stackGap: number = metrics !== null ? metrics.stackGap : 6;
    /** 连线与卡框之间的留白，避免线条贴着卡片 */
    const lineGap: number = metrics !== null ? metrics.lineGap : 6;

    // [PERF] 叶子数与每世最大配偶数一次遍历取齐，避免大谱重复全树 DFS
    const stats: TreeStats = collectTreeStats(roots, allowed);
    const leafCount: number = stats.leafCount;
    const siblingGap: number = (metrics !== null && metrics.siblingGap > 0) ? metrics.siblingGap
      : (leafCount <= 6 ? 18 : (leafCount <= 14 ? 11 : 7));

    // 列坐标：在每世卡片右侧为配偶列预留宽度（配偶竖向堆叠，横向只占一列）
    const colX: number[] = [0];
    if (showSpouse) {
      const maxSpouseAt: number[] = stats.maxSpouseAt;
      for (let d: number = 0; d < maxSpouseAt.length; d = d + 1) {
        const n: number = maxSpouseAt[d];
        const extra: number = n > 0 ? (spouseGap + spouseW) : 0;
        colX.push(colX[d] + cardWidth + extra + colGap);
      }
    }

    // 该节点连配偶卡在内的纵向高度
    const stackHeightOf = (node: PersonNode): number => {
      if (!showSpouse || node.spouses.length === 0) {
        return cardH;
      }
      const n: number = node.spouses.length;
      return Math.max(cardH, n * spouseH + (n - 1) * stackGap);
    };

    let cursorY: number = startY;

    // 自底向上：叶子按“内容高度 + 兄弟间距”顺序占位，父节点居中于首末子节点之间
    const place = (node: PersonNode, depth: number): EuBox | null => {
      const existing: EuBox | undefined = placed.get(node.uid);
      if (existing !== undefined) {
        return existing;
      }
      const box: EuBox = new EuBox();
      box.node = node;
      box.w = cardWidth;
      box.h = cardH;
      box.x = depth < colX.length ? colX[depth] : depth * (cardWidth + colGap);
      if (depth === 0 && canvas.rootBox === null) {
        canvas.rootBox = box;
      }
      // 环形关系保护：同一节点在本次下钻中再次出现，说明父链成环，
      // 直接占位返回，避免 place() 无限递归导致 RangeError: Stack overflow
      if (visiting.has(node.uid)) {
        box.y = cursorY;
        box.centerY = box.y + box.h / 2;
        cursorY = box.y + box.h + siblingGap;
        // 环上节点不进入 placed / boxes；返回 null 让父节点计算跳过它（与旧实现一致）
        return null;
      }
      visiting.add(node.uid);
      if (node.children.length === 0) {
        box.y = cursorY;
      } else {
        // [PERF] 递归热路径用 for 循环，避免为每个节点分配 forEach 闭包；
        // 同时直接复用 place 的返回值，省去再按 uid 查一次 placed（大谱约 8 万次字符串哈希）
        const childBoxes: EuBox[] = [];
        for (let i: number = 0; i < node.children.length; i = i + 1) {
          const child: PersonNode = node.children[i];
          // 分页布局：允许集合之外的子女属于下一页，本页停在这里，不画切线
          if (allowed !== null && !allowed.has(child.uid)) {
            continue;
          }
          const cb: EuBox | null = place(child, depth + 1);
          if (cb !== null) {
            childBoxes.push(cb);
          }
        }
        let lo: number = -1;
        let hi: number = -1;
        for (let i: number = 0; i < childBoxes.length; i = i + 1) {
          const c: number = childBoxes[i].y + childBoxes[i].h / 2;
          if (lo < 0 || c < lo) {
            lo = c;
          }
          if (hi < 0 || c > hi) {
            hi = c;
          }
        }
        box.y = lo < 0 ? cursorY : (lo + hi) / 2 - box.h / 2;
      }
      box.centerY = box.y + box.h / 2;
      visiting.delete(node.uid);
      placed.set(node.uid, box);
      canvas.boxes.push(box);
      // 主卡与配偶堆叠中较低者决定该子树占用的纵向底边，后续兄弟据此下移
      const bottom: number = Math.max(box.y + box.h, box.y + stackHeightOf(node));
      if (bottom + siblingGap > cursorY) {
        cursorY = bottom + siblingGap;
      }
      return box;
    };

    roots.forEach((r: PersonNode): void => {
      place(r, 0);
      cursorY = cursorY + 8; // 宗支之间额外留白
    });

    // 先取布局快照，避免边遍历边 push 配偶卡片
    const baseBoxes: EuBox[] = [];
    for (let i: number = 0; i < canvas.boxes.length; i = i + 1) {
      baseBoxes.push(canvas.boxes[i]);
    }

    // 配偶卡：按正庶先后纵向下排；婚约用红色双线，竖向细线把后续配偶串到主卡
    if (showSpouse) {
      for (let bi: number = 0; bi < baseBoxes.length; bi = bi + 1) {
        const pb: EuBox = baseBoxes[bi];
        const order: number[] = spouseOrder(pb.node);
        let slot: number = 0;
        let lastCy: number = pb.centerY;
        for (let oi: number = 0; oi < order.length; oi = oi + 1) {
          const si: number = order[oi];
          const sp: PersonNode = pb.node.spouses[si];
          if (placed.get(sp.uid) !== undefined) {
            continue; // 该配偶已作为树中节点布局，避免重复卡片
          }
          const sb: EuBox = new EuBox();
          sb.node = sp;
          sb.w = spouseW;
          sb.h = spouseH;
          sb.x = pb.x + pb.w + spouseGap;
          sb.y = pb.centerY - spouseH / 2 + slot * (spouseH + stackGap);
          sb.centerY = sb.y + sb.h / 2;
          slot = slot + 1;
          canvas.boxes.push(sb);
          placed.set(sp.uid, sb);
          pushDoubleLine(canvas.lines, pb.x + pb.w, sb.centerY, sb.x, sb.centerY, marriageGap);
          if (sb.centerY > lastCy) {
            lastCy = sb.centerY;
          }
        }
        if (lastCy > pb.centerY + 0.5) {
          const spine: LineSeg = new LineSeg();
          spine.id = canvas.lines.length;
          spine.red = true;
          spine.x1 = pb.x + pb.w;
          // 竖线起点对齐婚约双线中靠下的那一条，而不是卡中心，避免向上错位
          spine.y1 = pb.centerY + marriageGap;
          spine.x2 = pb.x + pb.w;
          // 竖线末端同样对齐最下一位配偶婚约双线中靠下的那一条，避免下端开口
          spine.y2 = lastCy + marriageGap;
          canvas.lines.push(spine);
        }
      }
    }

    // 世系连线：按生母分组，各组独立母线；组内子女相连，不同母子女经父母相连
    for (let pi: number = 0; pi < baseBoxes.length; pi = pi + 1) {
      const parentBox: EuBox = baseBoxes[pi];
      if (parentBox.node.children.length === 0) {
        continue;
      }
      const groups: ChildGroup[] = groupChildren(parentBox.node);
      for (let gi: number = 0; gi < groups.length; gi = gi + 1) {
        const group: ChildGroup = groups[gi];
        // edgeX 为出线起点（卡框边缘，横线从这里出发才能与卡框连成一体）；
        // railX 为母线竖线轨道，与卡框留出间距，避免竖线贴着卡框
        let edgeX: number = parentBox.x + parentBox.w;
        let railX: number = edgeX + lineGap;
        let ay: number = parentBox.centerY;
        if (group.mother !== null && group.mother !== undefined) {
          const mb: EuBox | undefined = placed.get(group.mother.uid);
          if (mb !== undefined) {
            edgeX = mb.x + mb.w;
            railX = edgeX + lineGap;
            ay = mb.centerY;
          }
        } else if (showSpouse && parentBox.node.spouses.length > 0) {
          // 无生母且右侧被配偶列占用：越过配偶列出线，避免连线藏在配偶卡下方
          edgeX = parentBox.x + parentBox.w + spouseGap + spouseW;
          railX = edgeX + lineGap;
        }
        let childX: number = -1;
        let loCy: number = -1;
        let hiCy: number = -1;
        for (let ki: number = 0; ki < group.kids.length; ki = ki + 1) {
          const cb: EuBox | undefined = placed.get(group.kids[ki].uid);
          if (cb === undefined) {
            continue;
          }
          if (childX < 0 || cb.x < childX) {
            childX = cb.x;
          }
          const c: number = cb.centerY;
          if (loCy < 0 || c < loCy) {
            loCy = c;
          }
          if (hiCy < 0 || c > hiCy) {
            hiCy = c;
          }
        }
        if (childX < 0) {
          continue;
        }
        // 母线竖线位于卡框右侧的轨道上；不同生母的母线在轨道上错开，避免连成一条
        const span: number = childX - railX;
        let busX: number = railX + Math.min(Math.max(4, span * (0.5 + gi * 0.15)), Math.max(4, span - 4));
        if (busX > childX - 4) {
          busX = childX - 4;
        }
        if (busX < railX) {
          busX = railX;
        }
        // 横线自卡框边缘引出，与卡框相接后再接到竖线轨道
        if (busX - edgeX > 1) {
          pushLine(canvas.lines, edgeX, ay, busX, ay);
        }
        if (hiCy - loCy > 1) {
          pushLine(canvas.lines, busX, Math.min(ay, loCy), busX, Math.max(ay, hiCy));
        }
        for (let ki: number = 0; ki < group.kids.length; ki = ki + 1) {
          const cb: EuBox | undefined = placed.get(group.kids[ki].uid);
          if (cb === undefined) {
            continue;
          }
          pushLine(canvas.lines, busX, cb.centerY, cb.x, cb.centerY);
        }
      }
    }

    let maxX: number = 0;
    let maxY: number = 0;
    for (let i: number = 0; i < canvas.boxes.length; i = i + 1) {
      const b: EuBox = canvas.boxes[i];
      if (b.x + b.w > maxX) {
        maxX = b.x + b.w;
      }
      if (b.y + b.h > maxY) {
        maxY = b.y + b.h;
      }
    }
    canvas.width = maxX + colGap;
    canvas.height = maxY + startY + 24;
    return canvas;
  }
}

/** 苏式谱一个节点的位置 */
export class SuBox {
  node: PersonNode = new PersonNode(new Person());
  x: number = 0;
  y: number = 0;
  w: number = 120;
  h: number = 64;
}

export class SuCanvas {
  boxes: SuBox[] = [];
  lines: LineSeg[] = [];
  width: number = 0;
  height: number = 0;
  /** 根节点（始祖）对应的主卡：居中定位直接命中，避免每次遍历全部 boxes */
  rootBox: SuBox | null = null;
}

/**
 * 苏式谱布局（竖式吊线图）。
 *
 * “叶子计数 + 横向排布”：每个叶子占一个列宽 slot；
 * 父节点的横向中心 = 首末子节点中心的中点；
 * 同一层的所有节点 y 相同，因此世代分明、不会重叠。
 * 配偶按“正庶先后”竖排在主卡右侧，婚约以朱砂红双线表示；
 * 子女按生母分组下引：各组独立母线，组内兄弟相连，异母兄弟经父母相连。
 */
export class SuLayout {
  /** 苏式布局列间距 */
  static readonly COL_GAP: number = 16;
  /** 苏式布局左起始边距 */
  static readonly START_X: number = 8;

  static compute(roots: PersonNode[], cardWidth: number, dense: boolean, showSpouse: boolean,
    allowed: Set<string> | null = null, metrics: LayoutMetrics | null = null): SuCanvas {
    const canvas: SuCanvas = new SuCanvas();
    const placed: Map<string, SuBox> = new Map<string, SuBox>();
    /** 正在递归下钻的节点：父链若成环，下钻会无限递归导致栈溢出 */
    const visiting: Set<string> = new Set<string>();
    const colGap: number = (metrics !== null && metrics.colGap > 0) ? metrics.colGap : SuLayout.COL_GAP;
    const startX: number = (metrics !== null && metrics.startX >= 0) ? metrics.startX : SuLayout.START_X;
    const rowGap: number = (metrics !== null && metrics.rowGap >= 0) ? metrics.rowGap : (dense ? 14 : 24);
    // 卡片高度按实际内容高度取值（渲染时卡片固定为该高度，连线才能与卡框对齐）
    const cardH: number = (metrics !== null && metrics.cardHeight > 0)
      ? metrics.cardHeight : (dense ? 62 : 74);

    // 大屏（平板 / 2in1 / PC）卡片更宽，连线间距随卡宽等比放大，避免线在宽卡间显得过细过密
    const scale: number = metrics !== null ? metrics.scale : Math.max(1, cardWidth / 120);
    // 配偶卡与主卡同宽，避免窄卡片内容被压缩 / 裁切
    const spouseW: number = cardWidth;
    const spouseH: number = cardH;
    /** 单妻横排时夫卡与妻卡的横向间隔 */
    const spouseGap: number = metrics !== null ? metrics.spouseGap : 12;
    /** 婚约双线各自偏离中轴的距离：按卡高比例收口，小卡上不再用大画布的 4mm */
    const marriageGap: number = Math.min(MARRIAGE_LINE_GAP, Math.max(0.45, spouseH * 0.08));
    /** 多妻竖排时夫卡与妻妾卡之间的竖向间隔：留出位置画红色双线 */
    const stackGap: number = metrics !== null ? metrics.stackGap : 10;
    /** 连线与卡框之间的留白：竖线离开卡框一段距离，再用短横线引出 */
    const lineGap: number = metrics !== null ? metrics.lineGap : Math.round(6 * scale);
    /** 同一父亲多房竖线的横向错开距离：正妻在内侧、继配/妾室依次向外，几房竖线不重合 */
    const railGap: number = metrics !== null ? metrics.railGap : Math.round(8 * scale);
    /** 同一父亲多房（正妻/继配/妾室）子女母线的层距：每房各得一条横线，需预留相应带宽 */
    const busStep: number = metrics !== null ? metrics.busStep : Math.round(14 * scale);

    // 按“每一世实际最多的配偶数”预留层高，而不是全树按最大配偶数统一拉高
    // [PERF] 与叶子数合并为一次全树遍历
    const stats: TreeStats = collectTreeStats(roots, allowed);
    const depthMax: number[] = showSpouse ? stats.maxSpouseAt : [];
    const stackExtra = (depth: number): number => {
      const n: number = depth < depthMax.length ? depthMax[depth] : 0;
      if (n === 0) {
        return 0;
      }
      // 单妻仍左右并排、不额外占高；多妻（≥2）时妻妾竖排在夫卡下方
      if (n <= 1) {
        return 0;
      }
      return Math.max(0, stackGap + n * (cardH + stackGap) - rowGap + (n - 1) * busStep + 16);
    };
    // 各世的纵坐标
    const rowY: number[] = [0];
    for (let d: number = 0; d < depthMax.length; d = d + 1) {
      rowY.push(rowY[d] + cardH + rowGap + stackExtra(d));
    }

    // 每个节点的横向占位：单妻横排占一列配偶位；多妻竖排在夫下方，只在其右侧留出线轨道
    // 无配偶的子女不再空占一列，子女间距随人数自适应，人多也不至于挤成一条线。
    const ownW = (node: PersonNode): number => {
      const k: number = showSpouse ? node.spouses.length : 0;
      if (k === 0) {
        return cardWidth;
      }
      if (k === 1) {
        return cardWidth + spouseGap + spouseW;
      }
      return cardWidth + lineGap + (k - 1) * railGap + lineGap;
    };

    let cursorX: number = startX;

    const place = (node: PersonNode, depth: number): SuBox | null => {
      const existing: SuBox | undefined = placed.get(node.uid);
      if (existing !== undefined) {
        return existing;
      }
      const box: SuBox = new SuBox();
      box.node = node;
      box.w = cardWidth;
      box.h = cardH;
      box.y = depth < rowY.length ? rowY[depth] : depth * (cardH + rowGap);
      if (depth === 0 && canvas.rootBox === null) {
        canvas.rootBox = box;
      }
      // 环形关系保护：父链成环时不再下钻，占位返回避免无限递归
      if (visiting.has(node.uid)) {
        box.x = cursorX;
        cursorX = cursorX + cardWidth + colGap;
        // 环上节点不进入 placed / boxes；返回 null 让父节点计算跳过它（与旧实现一致）
        return null;
      }
      visiting.add(node.uid);
      if (node.children.length === 0) {
        box.x = cursorX;
      } else {
        // [PERF] 递归热路径用 for 循环，避免为每个节点分配 forEach 闭包；
        // 同时直接复用 place 的返回值，省去再按 uid 查一次 placed
        const childBoxes: SuBox[] = [];
        for (let i: number = 0; i < node.children.length; i = i + 1) {
          const child: PersonNode = node.children[i];
          // 分页布局：允许集合之外的子女属于下一页，本页停在这里，不画切线
          if (allowed !== null && !allowed.has(child.uid)) {
            continue;
          }
          const cb: SuBox | null = place(child, depth + 1);
          if (cb !== null) {
            childBoxes.push(cb);
          }
        }
        let lo: number = -1;
        let hi: number = -1;
        for (let i: number = 0; i < childBoxes.length; i = i + 1) {
          const c: number = childBoxes[i].x + childBoxes[i].w / 2;
          if (lo < 0 || c < lo) {
            lo = c;
          }
          if (hi < 0 || c > hi) {
            hi = c;
          }
        }
        box.x = lo < 0 ? cursorX : (lo + hi) / 2 - cardWidth / 2;
      }
      visiting.delete(node.uid);
      placed.set(node.uid, box);
      canvas.boxes.push(box);
      // 子树右边界取“子孙右缘”与“本卡连配偶右缘”的较大者，后续兄弟据此右移
      const right: number = box.x + ownW(node) + colGap;
      if (right > cursorX) {
        cursorX = right;
      }
      return box;
    };

    roots.forEach((r: PersonNode): void => {
      place(r, 0);
      cursorX = cursorX + 8; // 宗支之间额外留白
    });

    const baseBoxes: SuBox[] = [];
    for (let i: number = 0; i < canvas.boxes.length; i = i + 1) {
      baseBoxes.push(canvas.boxes[i]);
    }

    // 配偶卡：单妻沿用「夫左妻右」横排 + 水平红双线；多妻则夫居中、妻妾竖排在夫下方 + 纵向红双线
    if (showSpouse) {
      for (let bi: number = 0; bi < baseBoxes.length; bi = bi + 1) {
        const pb: SuBox = baseBoxes[bi];
        const order: number[] = spouseOrder(pb.node);
        // 待单独绘制的配偶数（已作为树中节点的跳过）
        let pending: number = 0;
        for (let oi: number = 0; oi < order.length; oi = oi + 1) {
          const sp: PersonNode = pb.node.spouses[order[oi]];
          if (sp !== null && sp !== undefined && placed.get(sp.uid) === undefined) {
            pending = pending + 1;
          }
        }
        if (pending === 0) {
          continue;
        }
        const cx: number = pb.x + pb.w / 2;
        let prevBottom: number = pb.y + pb.h;
        for (let oi: number = 0; oi < order.length; oi = oi + 1) {
          const sp: PersonNode = pb.node.spouses[order[oi]];
          if (placed.get(sp.uid) !== undefined) {
            continue; // 该配偶已作为树中节点布局，避免重复卡片
          }
          const sb: SuBox = new SuBox();
          sb.node = sp;
          sb.w = spouseW;
          sb.h = spouseH;
          if (pending === 1) {
            // 单妻：夫左妻右横排，水平红双线
            sb.x = pb.x + pb.w + spouseGap;
            sb.y = pb.y + pb.h / 2 - spouseH / 2;
          } else {
            // 多妻：妻妾依次竖排在夫卡正下方，纵向红双线
            sb.x = pb.x;
            sb.y = prevBottom + stackGap;
          }
          canvas.boxes.push(sb);
          placed.set(sp.uid, sb);
          if (pending === 1) {
            const scy: number = sb.y + sb.h / 2;
            pushDoubleLine(canvas.lines, pb.x + pb.w, scy, sb.x, scy, marriageGap);
          } else {
            // 夫卡底 → 原配卡顶，之后每位续配 / 妾室与其上一张卡相连
            pushDoubleLine(canvas.lines, cx, prevBottom, cx, sb.y, marriageGap);
            prevBottom = sb.y + sb.h;
          }
        }
      }
    }

    // 世系连线：按生母分组，各组自生母（或父）底部独立下引
    for (let pi: number = 0; pi < baseBoxes.length; pi = pi + 1) {
      const parentBox: SuBox = baseBoxes[pi];
      if (parentBox.node.children.length === 0) {
        continue;
      }
      const groups: ChildGroup[] = groupChildren(parentBox.node);
      // 各生母线锚点的高度：有生母时取生母卡中心，否则取父卡底边，用于决定母线上下次序
      const anchorYOf = (g: ChildGroup): number => {
        if (g.mother !== null && g.mother !== undefined) {
          const mb: SuBox | undefined = placed.get(g.mother.uid);
          if (mb !== undefined) {
            return mb.y + mb.h / 2;
          }
        }
        return parentBox.y + parentBox.h;
      };
      // 每房在配偶竖列中的次序（0 = 最上一位）：同时决定母线高度与竖线轨道的横向错开
      const rankOf = (gi: number): number => {
        const ay: number = anchorYOf(groups[gi]);
        let r: number = 0;
        for (let oi: number = 0; oi < groups.length; oi = oi + 1) {
          if (oi === gi) {
            continue;
          }
          const oy: number = anchorYOf(groups[oi]);
          if (oy < ay || (oy === ay && oi < gi)) {
            r = r + 1;
          }
        }
        return r;
      };
      for (let gi: number = 0; gi < groups.length; gi = gi + 1) {
        const group: ChildGroup = groups[gi];
        let ax: number = parentBox.x + parentBox.w / 2;
        let anchorY: number = parentBox.y + parentBox.h;
        let motherRightX: number = -1;
        let mb: SuBox | undefined = undefined;
        if (group.mother !== null && group.mother !== undefined) {
          mb = placed.get(group.mother.uid);
        }
        if (mb !== undefined) {
          // 生母卡右缘留白后引出：先一条短横线到竖线轨道，再沿轨道下引；
          // 各房轨道按次序横向错开，妻出、妾生的连线便不会叠成一条
          motherRightX = mb.x + mb.w;
          ax = motherRightX + lineGap + rankOf(gi) * railGap;
          anchorY = mb.y + mb.h / 2;
        }
        let loCx: number = -1;
        let hiCx: number = -1;
        let childTop: number = -1;
        for (let ki: number = 0; ki < group.kids.length; ki = ki + 1) {
          const cb: SuBox | undefined = placed.get(group.kids[ki].uid);
          if (cb === undefined) {
            continue;
          }
          const c: number = cb.x + cb.w / 2;
          if (loCx < 0 || c < loCx) {
            loCx = c;
          }
          if (hiCx < 0 || c > hiCx) {
            hiCx = c;
          }
          if (childTop < 0 || cb.y < childTop) {
            childTop = cb.y;
          }
        }
        if (loCx < 0) {
          continue;
        }
        // 自生母卡右缘横向引出到竖线轨道，形成「横—竖—横」的清晰折线
        if (motherRightX > 0 && ax - motherRightX > 1) {
          pushLine(canvas.lines, motherRightX, anchorY, ax, anchorY);
        }
        // 多房母线统一放在最后一位配偶卡下方、子女卡上方：按配偶的上下次序从上到下排列，
        // 正妻所出的横线在上、继配/妾室所出的在下，各房各成一条线、互不重叠也不压卡
        const rank: number = rankOf(gi);
        const busY: number = childTop - 8 - (groups.length - 1 - rank) * busStep;
        pushLine(canvas.lines, ax, anchorY, ax, busY);
        const leftX: number = Math.min(ax, loCx);
        const rightX: number = Math.max(ax, hiCx);
        if (rightX - leftX > 1) {
          pushLine(canvas.lines, leftX, busY, rightX, busY);
        }
        for (let ki: number = 0; ki < group.kids.length; ki = ki + 1) {
          const cb: SuBox | undefined = placed.get(group.kids[ki].uid);
          if (cb === undefined) {
            continue;
          }
          const cx: number = cb.x + cb.w / 2;
          pushLine(canvas.lines, cx, busY, cx, cb.y);
        }
      }
    }

    let maxX2: number = 0;
    let maxY2: number = 0;
    for (let i: number = 0; i < canvas.boxes.length; i = i + 1) {
      const b: SuBox = canvas.boxes[i];
      if (b.x + b.w > maxX2) {
        maxX2 = b.x + b.w;
      }
      if (b.y + b.h > maxY2) {
        maxY2 = b.y + b.h;
      }
    }
    canvas.width = maxX2 + startX + 24;
    canvas.height = maxY2 + 24;
    return canvas;
  }
}

/**
 * 苏式谱首棵树“深度 0 根节点”的中心横坐标。
 * 竖式吊线图里始祖居中于子孙，画布宽度远大于屏幕，切换谱式后据此把始祖居中显示。
 */
export function suRootCenterX(roots: PersonNode[], cardWidth: number, dense: boolean): number {
  if (roots.length === 0) {
    return 0;
  }
  const canvas: SuCanvas = SuLayout.compute([roots[0]], cardWidth, dense, true);
  let cx: number = 0;
  canvas.boxes.forEach((b: SuBox): void => {
    if (b.node.uid === roots[0].uid) {
      cx = b.x + b.w / 2;
    }
  });
  return cx;
}
