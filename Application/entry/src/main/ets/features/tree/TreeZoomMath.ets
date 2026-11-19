/** 小地图上的视口矩形（vp） */
export class MiniViewRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

/**
 * 谱系画布的纯几何计算：小地图映射、缩放钳制、捏合锚点。
 * 不持有组件状态，参数全部显式传入，便于单测与复用。
 */
export class TreeZoomMath {
  static clampZoom(v: number, min: number, max: number): number {
    if (v < min) {
      return min;
    }
    if (v > max) {
      return max;
    }
    return v;
  }

  /** 小地图视口宽度 */
  static miniW(canvasW: number, viewW: number, miniW: number): number {
    if (canvasW <= 0) {
      return miniW;
    }
    return Math.max(8, Math.min(miniW, viewW / canvasW * miniW));
  }

  /** 小地图视口高度 */
  static miniH(canvasH: number, viewH: number, miniH: number): number {
    if (canvasH <= 0) {
      return miniH;
    }
    return Math.max(8, Math.min(miniH, viewH / canvasH * miniH));
  }

  /** 小地图视口：由平移、画布尺寸与可视区尺寸换算 */
  static miniRect(offsetX: number, offsetY: number, contentTop: number, canvasW: number,
    canvasH: number, viewW: number, viewH: number, miniW: number, miniH: number): MiniViewRect {
    const rect: MiniViewRect = new MiniViewRect();
    rect.w = TreeZoomMath.miniW(canvasW, viewW, miniW);
    rect.h = TreeZoomMath.miniH(canvasH, viewH, miniH);
    if (canvasW > 0) {
      const vx: number = (-offsetX) / canvasW * miniW;
      rect.x = Math.max(0, Math.min(miniW - rect.w, vx));
    }
    if (canvasH > 0) {
      const vy: number = (-offsetY - contentTop) / canvasH * miniH;
      rect.y = Math.max(0, Math.min(miniH - rect.h, vy));
    }
    return rect;
  }

  /**
   * 捏合点所在的宗支索引。多宗支堆叠时各支屏幕起点不同，锚点必须按所在支换算。
   */
  static anchorIndexAt(tops: number[], heights: number[], centerY: number, offsetY: number,
    zoom: number): number {
    if (tops.length === 0) {
      return 0;
    }
    const y: number = centerY - offsetY;
    let nearestIdx: number = 0;
    let nearestDist: number = Number.MAX_VALUE;
    for (let i: number = 0; i < tops.length; i = i + 1) {
      const top: number = tops[i];
      const bottom: number = top + (i < heights.length ? heights[i] : 0) * zoom;
      if (y >= top && y <= bottom) {
        return i;
      }
      const dist: number = y < top ? top - y : y - bottom;
      if (dist < nearestDist) {
        nearestDist = dist;
        nearestIdx = i;
      }
    }
    return nearestIdx;
  }

  /** 指定宗支在“目标缩放比”下的屏幕起点（不含平移） */
  static branchTopAt(tops: number[], heights: number[], headerBlock: number, gapAfter: number,
    index: number, zoom: number): number {
    if (tops.length === 0) {
      return 0;
    }
    let cursor: number = 0;
    for (let i: number = 0; i < index; i = i + 1) {
      const h: number = i < heights.length ? heights[i] : 0;
      cursor = cursor + headerBlock + h * zoom + gapAfter;
    }
    return cursor + headerBlock;
  }

  /** 双指中心（画布坐标）；无有效双指数据时返回 [-1, -1] */
  static pinchCenter(event: GestureEvent, viewGlobalX: number, viewGlobalY: number): number[] {
    const fingers: FingerInfo[] = event.fingerList;
    if (fingers !== undefined && fingers.length >= 2 &&
      fingers[0].globalX !== undefined && fingers[1].globalX !== undefined) {
      const gx: number = (fingers[0].globalX + fingers[1].globalX) / 2;
      const gy: number = (fingers[0].globalY + fingers[1].globalY) / 2;
      return [gx - viewGlobalX, gy - viewGlobalY];
    }
    if (event.pinchCenterX > 0 || event.pinchCenterY > 0) {
      return [event.pinchCenterX, event.pinchCenterY];
    }
    return [-1, -1];
  }
}
