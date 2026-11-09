import { PersonNode } from '../../model/PersonNode';
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
    input.viewWidth.toString() + '|' + input.viewHeight.toString() + '|' +
    input.zoom.toString() + '|' + input.layoutVersion.toString() + '|' + input.contentTop.toString() +
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

/** 极低缩放：节点聚合气泡 */
export const DETAIL_BUBBLE: number = 0;
/** 中等缩放：只画骨架与姓名缩写 */
export const DETAIL_SKELETON: number = 1;
/** 高缩放：完整卡片 */
export const DETAIL_FULL: number = 2;

/** 进入骨架模式的缩放阈值 */
const LOD_SKELETON_ZOOM: number = 0.68;
/** 进入聚合模式的缩放阈值 */
const LOD_BUBBLE_ZOOM: number = 0.36;
/** 聚合气泡的屏幕网格边长（vp） */
const BUBBLE_CELL: number = 72;
/** 可见卡片超过该数量时，即使缩放比不算低也强制降为骨架，避免一次性创建成百上千张完整卡片 */
const DEGRADE_SKELETON_COUNT: number = 250;
/** 可见卡片超过该数量时直接聚合为气泡（极端大谱 / 异常视口下的兜底） */
const DEGRADE_BUBBLE_COUNT: number = 1200;

/**
 * 按当前缩放、手势状态与可见卡片数量计算细节层次。
 * 手势进行中主动降一级（只改矩阵/骨架），抬手后再恢复完整精度，
 * 避免 PinchGesture 每帧都重建大量卡片。
 *
 * [PERF] TreePerf.shouldDegrade 之前只用于打日志，没有真正参与渲染：
 * 全览或切支后继承较小缩放时，可见 boxes 可能成百上千，仍按完整卡片逐个创建。
 * 这里让可见数量真正参与 LOD，超阈值时先降骨架、再兜底为聚合气泡。
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

/** 聚合气泡（坐标为内容坐标，r 为内容半径） */
export class Bubble {
  key: string = '';
  x: number = 0;
  y: number = 0;
  r: number = 0;
  count: number = 0;
  femaleRatio: number = 0;
}

class BubbleAccum {
  gx: number = 0;
  gy: number = 0;
  count: number = 0;
  female: number = 0;
}

function addToBubble(map: Map<string, BubbleAccum>, x: number, y: number, isFemale: boolean,
  zoom: number, offsetX: number, offsetY: number, contentTop: number): void {
  const z: number = zoom > 0 ? zoom : 1;
  // 换算到屏幕坐标后按固定屏幕网格聚合，保证任何缩放下气泡大小与密度稳定
  const gx: number = Math.floor((x * z + offsetX) / BUBBLE_CELL);
  const gy: number = Math.floor((y * z + offsetY + contentTop) / BUBBLE_CELL);
  const key: string = gx.toString() + '_' + gy.toString();
  let acc: BubbleAccum | undefined = map.get(key);
  if (acc === undefined) {
    acc = new BubbleAccum();
    acc.gx = gx;
    acc.gy = gy;
    map.set(key, acc);
  }
  acc.count = acc.count + 1;
  if (isFemale) {
    acc.female = acc.female + 1;
  }
}

function toBubbles(map: Map<string, BubbleAccum>, zoom: number, offsetX: number,
  offsetY: number, contentTop: number): Bubble[] {
  const z: number = zoom > 0 ? zoom : 1;
  const out: Bubble[] = [];
  map.forEach((acc: BubbleAccum): void => {
    const b: Bubble = new Bubble();
    b.key = acc.gx.toString() + '_' + acc.gy.toString();
    // 屏幕格心 -> 内容坐标
    b.x = ((acc.gx + 0.5) * BUBBLE_CELL - offsetX) / z;
    b.y = ((acc.gy + 0.5) * BUBBLE_CELL - offsetY - contentTop) / z;
    const grow: number = Math.min(Math.sqrt(acc.count), 5);
    b.r = (12 + grow * 4.5) / z;
    b.count = acc.count;
    b.femaleRatio = acc.count > 0 ? acc.female / acc.count : 0;
    out.push(b);
  });
  return out;
}

/** 欧式谱节点聚合 */
export function aggregateEu(boxes: EuBox[], zoom: number, offsetX: number, offsetY: number,
  contentTop: number): Bubble[] {
  const map: Map<string, BubbleAccum> = new Map<string, BubbleAccum>();
  for (let i: number = 0; i < boxes.length; i = i + 1) {
    const b: EuBox = boxes[i];
    addToBubble(map, b.x + b.w / 2, b.y + b.h / 2, b.node.person.gender === '女',
      zoom, offsetX, offsetY, contentTop);
  }
  return toBubbles(map, zoom, offsetX, offsetY, contentTop);
}

/** 苏式谱节点聚合 */
export function aggregateSu(boxes: SuBox[], zoom: number, offsetX: number, offsetY: number,
  contentTop: number): Bubble[] {
  const map: Map<string, BubbleAccum> = new Map<string, BubbleAccum>();
  for (let i: number = 0; i < boxes.length; i = i + 1) {
    const b: SuBox = boxes[i];
    addToBubble(map, b.x + b.w / 2, b.y + b.h / 2, b.node.person.gender === '女',
      zoom, offsetX, offsetY, contentTop);
  }
  return toBubbles(map, zoom, offsetX, offsetY, contentTop);
}
