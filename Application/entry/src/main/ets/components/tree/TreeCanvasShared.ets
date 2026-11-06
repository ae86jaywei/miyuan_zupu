import { PersonNode } from '../../model/PersonNode';
import { GenealogyService } from '../../service/GenealogyService';
import { LineSeg } from '../../service/TreeLayout';
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
}

/** 组装视口缓存 key：任一参数变化才重新裁剪 */
export function treeViewKey(input: TreeViewportKeyInput): string {
  return input.rootUid + '|' + input.offsetX.toString() + '|' + input.offsetY.toString() + '|' +
    input.viewWidth.toString() + '|' + input.viewHeight.toString() + '|' +
    input.zoom.toString() + '|' + input.layoutVersion.toString() + '|' + input.contentTop.toString() +
    '|' + input.cardWidth.toString() + '|' + input.dense.toString() + '|' + input.showSpouse.toString();
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
