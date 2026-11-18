import { PersonNode } from 'common_base';
import { GenealogyService } from '../../service/GenealogyService';
import { EuBox, LineSeg, SuBox } from '../../service/TreeLayout';
import { ViewRect, ViewportMath } from '../../service/TreeViewport';

/**
 * 欧式 / 苏式谱画布（EuTree、SuTree）之间完全相同的纯逻辑。
 *
 * 这两个组件此前各自复制了「连线粗细、水平判定、视口 key、根节点查找、
 * 内容可视矩形」等实现；抽取为无副作用的工具函数后，任一调整只需改一处，
 * 组件自身仍保留各自的状态与渲染，行为保持不变。
 */

/** 按缩放比计算连线粗细（缩放越小线越粗，保证屏幕观感一致） */
export function lineThicknessOf(zoom: number): number {
  return 1.5 / (zoom > 0 ? zoom : 1);
}

/** 判断连线是否水平：用于横线/竖线的宽高取值 */
export function isHorizontalSeg(seg: LineSeg): boolean {
  return Math.abs(seg.y2 - seg.y1) <= 0.5;
}

/** 视口缓存 key 的输入参数 */
export interface TreeViewportKeyInput {
  rootUid: string;
  offsetX: number;
  offsetY: number;
  viewWidth: number;
  viewHeight: number;
  zoom: number;
  layoutVersion: number;
  contentTop: number;
  cardWidth: number;
  dense: boolean;
  showSpouse: boolean;
  interacting: boolean;
}

/** 组装视口缓存 key：任一参数变化才重新裁剪 */
export function treeViewKey(input: TreeViewportKeyInput): string {
  return input.rootUid + '|' + input.offsetX.toString() + '|' + input.offsetY.toString() + '|' +
    input.viewWidth.toString() + '|' + input.viewHeight.toString() +
    '|' + input.zoom.toString() + '|' + input.layoutVersion.toString() + '|' + input.contentTop.toString() +
    '|' + input.cardWidth.toString() + '|' + input.dense.toString() + '|' + input.showSpouse.toString() +
    '|' + input.interacting.toString();
}

/** 按 uid 在全部宗支根节点中查找对应节点（找不到返回 null） */
export function findRootNode(uid: string): PersonNode | null {
  const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
  for (let i: number = 0; i < roots.length; i = i + 1) {
    if (roots[i].uid === uid) {
      return roots[i];
    }
  }
  return null;
}

/** 计算需要渲染的内容可视矩形（含半屏缓冲） */
export function contentViewRect(offsetX: number, offsetY: number, contentTop: number,
  viewWidth: number, viewHeight: number, zoom: number): ViewRect {
  return ViewportMath.contentRect(offsetX, offsetY + contentTop,
    viewWidth, viewHeight, zoom, viewWidth * 0.5);
}

// ------------------------------------------------------------------ LOD 多尺度

/** 极低缩放：房支聚簇卡片 */
export const DETAIL_BUBBLE: number = 0;
/** 中等缩放：只画骨架与姓名缩写 */
export const DETAIL_SKELETON: number = 1;
/** 高缩放：完整卡片 */
export const DETAIL_FULL: number = 2;

/** 进入骨架模式的缩放阈值（50% 起显示具体人物） */
const LOD_SKELETON_ZOOM: number = 0.55;
/** 进入房支聚簇模式的缩放阈值（低于约 22% 只显示房支卡片） */
const LOD_BUBBLE_ZOOM: number = 0.22;
/** 可见卡片超过该数量时，即使缩放比不算低也强制降为骨架 */
const DEGRADE_SKELETON_COUNT: number = 250;
/** 可见卡片超过该数量时直接聚合为房支气泡 */
const DEGRADE_BUBBLE_COUNT: number = 1200;
/** 气泡卡片最小/最大屏幕宽度（vp） */
const BUBBLE_MIN_W: number = 64;
const BUBBLE_MAX_W: number = 168;
const BUBBLE_H: number = 34;
/** 防碰撞时的最小屏幕间距（vp） */
const BUBBLE_GAP: number = 6;

/**
 * 按当前缩放、手势状态与可见卡片数量计算细节层次。
 * 手势进行中主动降一级（只改矩阵/骨架），抬手后再恢复完整精度，
 * 避免 PinchGesture 每帧都重建大量卡片。
 */
export function detailLevelOf(zoom: number, interacting: boolean, visibleCount: number = 0): number {
  let level: number = DETAIL_FULL;
  if (zoom < LOD_BUBBLE_ZOOM) {
    level = DETAIL_BUBBLE;
  } else if (zoom < LOD_SKELETON_ZOOM) {
    level = DETAIL_SKELETON;
  }
  if (interacting && level > DETAIL_BUBBLE) {
    level = level - 1;
  }
  if (visibleCount > DEGRADE_BUBBLE_COUNT && level > DETAIL_BUBBLE) {
    level = DETAIL_BUBBLE;
  } else if (visibleCount > DEGRADE_SKELETON_COUNT && level > DETAIL_SKELETON) {
    level = DETAIL_SKELETON;
  }
  return level;
}

/**
 * 房支聚簇气泡。
 *
 * 与旧版按屏幕网格统计数字不同：这里按 `PersonNode.branchId` 分组，
 * 每个气泡代表一房，显示「三房·韦耀定 25人」，点击锚点即跳转到该房分页。
 * 坐标仍为内容坐标，随 zoom 缩放；bbox 用于同世代防碰撞。
 */
export class Bubble {
  key: string = '';
  /** 气泡中心（内容坐标） */
  x: number = 0;
  y: number = 0;
  r: number = 0;
  /** 可见卡片数 */
  count: number = 0;
  /** 该房总人数（取房根 descendants） */
  total: number = 0;
  femaleRatio: number = 0;
  /** 房支名，如「三房」 */
  branchName: string = '';
  /** 房支始祖 uid：点击跳转目标 */
  anchorUid: string = '';
  anchorName: string = '';
  /** 卡片主标题（房支·代表名） */
  label: string = '';
  /** 卡片副标题（人数） */
  countLabel: string = '';
  /** 房根世代，用于同世代 Y 对齐 */
  generation: number = 0;
  /** 卡片包围盒（内容坐标，左上角 + 宽高） */
  bx: number = 0;
  by: number = 0;
  bw: number = 0;
  bh: number = 0;
}

/** 统一的扁平盒子：EuBox/SuBox 结构一致，先转成无类型歧义的中间结构再聚合 */
class BranchBox {
  node: PersonNode;
  x: number;
  y: number;
  w: number;
  h: number;

  constructor(node: PersonNode, x: number, y: number, w: number, h: number) {
    this.node = node;
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }
}

class BranchAccum {
  branchId: string = '';
  branchName: string = '';
  anchorUid: string = '';
  anchorName: string = '';
  generation: number = 0;
  total: number = 0;
  count: number = 0;
  female: number = 0;
  /** 屏幕坐标锚点（房根中心；房根不在视口内时用组内平均位置） */
  sx: number = 0;
  sy: number = 0;
  sumX: number = 0;
  sumY: number = 0;
  hasAnchor: boolean = false;
}

/**
 * 房支聚合核心。
 *
 * - 只统计 branchLevel ≥ 1 的节点：宗支根单独留在画布外围，不参与房支气泡；
 * - 一房一个气泡，人数取房根 `descendants`（总人数，不是当前视口内可见数）；
 * - 同一世代的气泡 Y 轴对齐，X 轴按包围盒依次推开，保证 5% 全览也互不遮挡。
 */
function aggregateByBranch(boxes: BranchBox[], zoom: number, offsetX: number, offsetY: number,
  contentTop: number): Bubble[] {
  const z: number = zoom > 0 ? zoom : 1;
  const map: Map<string, BranchAccum> = new Map<string, BranchAccum>();
  let rootFallback: BranchAccum | null = null;

  for (let i: number = 0; i < boxes.length; i = i + 1) {
    const b: BranchBox = boxes[i];
    const node: PersonNode = b.node;
    const sx: number = (b.x + b.w / 2) * z + offsetX;
    const sy: number = (b.y + b.h / 2) * z + offsetY + contentTop;
    if (node.branchId.length === 0 || node.branchLevel <= 0) {
      if (rootFallback === null) {
        rootFallback = new BranchAccum();
        rootFallback.branchId = node.uid;
        rootFallback.branchName = '本支';
        rootFallback.anchorUid = node.uid;
        rootFallback.anchorName = node.person.name.length > 0 ? node.person.name : node.uid;
        rootFallback.generation = node.person.generation;
        rootFallback.total = node.descendants;
      }
      rootFallback.count = rootFallback.count + 1;
      rootFallback.sumX = rootFallback.sumX + sx;
      rootFallback.sumY = rootFallback.sumY + sy;
      if (node.person.gender === '女') {
        rootFallback.female = rootFallback.female + 1;
      }
      continue;
    }
    const key: string = node.branchId;
    let acc: BranchAccum | undefined = map.get(key);
    if (acc === undefined) {
      acc = new BranchAccum();
      acc.branchId = key;
      acc.branchName = node.branchName.length > 0 ? node.branchName : '旁支';
      acc.anchorUid = node.branchRootUid.length > 0 ? node.branchRootUid : node.uid;
      acc.generation = node.person.generation;
      map.set(key, acc);
    }
    acc.count = acc.count + 1;
    acc.sumX = acc.sumX + sx;
    acc.sumY = acc.sumY + sy;
    if (node.person.gender === '女') {
      acc.female = acc.female + 1;
    }
    if (node.uid === acc.anchorUid) {
      acc.hasAnchor = true;
      acc.sx = sx;
      acc.sy = sy;
      acc.anchorName = node.person.name.length > 0 ? node.person.name : node.uid;
      acc.generation = node.person.generation;
      acc.total = node.descendants;
    }
  }

  const out: Bubble[] = [];
  map.forEach((acc: BranchAccum): void => {
    if (acc.anchorName.length === 0) {
      acc.anchorName = acc.branchName;
    }
    const b: Bubble = new Bubble();
    b.key = acc.branchId;
    b.branchName = acc.branchName;
    b.anchorUid = acc.anchorUid;
    b.anchorName = acc.anchorName;
    b.count = acc.count;
    b.total = acc.total > 0 ? acc.total : acc.count;
    b.femaleRatio = acc.count > 0 ? acc.female / acc.count : 0;
    b.generation = acc.generation;
    b.countLabel = b.total.toString() + '人';
    b.label = acc.branchName + '·' + acc.anchorName;
    const sx: number = acc.hasAnchor ? acc.sx : (acc.count > 0 ? acc.sumX / acc.count : 0);
    const sy: number = acc.hasAnchor ? acc.sy : (acc.count > 0 ? acc.sumY / acc.count : 0);
    b.x = (sx - offsetX) / z;
    b.y = (sy - offsetY - contentTop) / z;
    // 屏幕宽度按字数估算后换算回内容坐标；限制上下限，避免长名撑爆版面
    const name: string = b.label.length > 9 ? b.label.substring(0, 8) + '…' : b.label;
    b.label = name;
    const screenW: number = Math.max(BUBBLE_MIN_W, Math.min(BUBBLE_MAX_W, name.length * 11 + 18));
    b.bw = screenW / z;
    b.bh = BUBBLE_H / z;
    b.r = b.bh / 2;
    b.bx = b.x - b.bw / 2;
    b.by = b.y - b.bh / 2;
    out.push(b);
  });

  if (out.length === 0 && rootFallback !== null) {
    const b: Bubble = new Bubble();
    b.key = rootFallback.branchId;
    b.branchName = rootFallback.branchName;
    b.anchorUid = rootFallback.anchorUid;
    b.anchorName = rootFallback.anchorName;
    b.count = rootFallback.count;
    b.total = rootFallback.total > 0 ? rootFallback.total : rootFallback.count;
    b.countLabel = b.total.toString() + '人';
    b.label = b.branchName + '·' + b.anchorName;
    b.x = (rootFallback.sumX / Math.max(1, rootFallback.count) - offsetX) / z;
    b.y = (rootFallback.sumY / Math.max(1, rootFallback.count) - offsetY - contentTop) / z;
    b.bw = BUBBLE_MAX_W / z;
    b.bh = BUBBLE_H / z;
    b.r = b.bh / 2;
    b.bx = b.x - b.bw / 2;
    b.by = b.y - b.bh / 2;
    b.generation = rootFallback.generation;
    out.push(b);
  }

  return avoidOverlap(out, z);
}

/** 同世代 Y 对齐 + X 轴推开，确保低缩放下所有房支卡片均可见 */
function avoidOverlap(list: Bubble[], zoom: number): Bubble[] {
  const z: number = zoom > 0 ? zoom : 1;
  const gap: number = BUBBLE_GAP / z;
  const rows: Map<number, Bubble[]> = new Map<number, Bubble[]>();
  for (let i: number = 0; i < list.length; i = i + 1) {
    const b: Bubble = list[i];
    let arr: Bubble[] | undefined = rows.get(b.generation);
    if (arr === undefined) {
      arr = [];
      rows.set(b.generation, arr);
    }
    arr.push(b);
  }
  rows.forEach((arr: Bubble[]): void => {
    arr.sort((a: Bubble, b: Bubble): number => a.bx - b.bx);
    let sumY: number = 0;
    for (let i: number = 0; i < arr.length; i = i + 1) {
      sumY = sumY + arr[i].y;
    }
    const rowY: number = arr.length > 0 ? sumY / arr.length : 0;
    let right: number = -Number.MAX_VALUE;
    for (let i: number = 0; i < arr.length; i = i + 1) {
      const b: Bubble = arr[i];
      b.y = rowY;
      b.by = rowY - b.bh / 2;
      if (right > -Number.MAX_VALUE && b.bx < right + gap) {
        b.bx = right + gap;
      }
      b.x = b.bx + b.bw / 2;
      right = b.bx + b.bw;
    }
  });
  return list;
}

/** 欧式谱房支聚簇 */
export function aggregateEu(boxes: EuBox[], zoom: number, offsetX: number, offsetY: number,
  contentTop: number): Bubble[] {
  const input: BranchBox[] = [];
  for (let i: number = 0; i < boxes.length; i = i + 1) {
    const b: EuBox = boxes[i];
    input.push(new BranchBox(b.node, b.x, b.y, b.w, b.h));
  }
  return aggregateByBranch(input, zoom, offsetX, offsetY, contentTop);
}

/** 苏式谱房支聚簇 */
export function aggregateSu(boxes: SuBox[], zoom: number, offsetX: number, offsetY: number,
  contentTop: number): Bubble[] {
  const input: BranchBox[] = [];
  for (let i: number = 0; i < boxes.length; i = i + 1) {
    const b: SuBox = boxes[i];
    input.push(new BranchBox(b.node, b.x, b.y, b.w, b.h));
  }
  return aggregateByBranch(input, zoom, offsetX, offsetY, contentTop);
}