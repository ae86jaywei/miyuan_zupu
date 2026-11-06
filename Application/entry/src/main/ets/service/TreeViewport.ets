/** 内容坐标系中的可视矩形（单位 vp） */
export class ViewRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;

  constructor(x: number = 0, y: number = 0, w: number = 0, h: number = 0) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }

  intersects(x: number, y: number, w: number, h: number): boolean {
    return x < this.x + this.w && x + w > this.x &&
      y < this.y + this.h && y + h > this.y;
  }
}

/**
 * 视口数学。
 *
 * 变换约定（EuTree / SuTree 按此实现）：
 *   屏幕坐标 = 内容坐标 × zoom + offset
 * 因此内容可视矩形 = (-offset / zoom, 视口尺寸 / zoom)。
 */
export class ViewportMath {
  static contentRect(offsetX: number, offsetY: number, viewW: number, viewH: number,
    zoom: number, margin: number): ViewRect {
    const z: number = zoom > 0 ? zoom : 1;
    const w: number = viewW / z + margin * 2;
    const h: number = viewH / z + margin * 2;
    return new ViewRect(-offsetX / z - margin, -offsetY / z - margin, w, h);
  }

  /**
   * 平移边界（内容尺寸版）：
   * - 内容大于视口：offset ∈ [viewW - contentW×zoom - pad, pad]
   * - 内容小于视口：居中
   */
  static clampOffset(value: number, contentSize: number, viewSize: number,
    zoom: number, pad: number): number {
    const z: number = zoom > 0 ? zoom : 1;
    return ViewportMath.clampScreenOffset(value, contentSize * z, viewSize, pad);
  }

  /**
   * 平移边界（屏幕尺寸版）：contentScreenSize 已乘过 zoom。
   * 多宗支堆叠时，每支标题/间隔不随 zoom 缩放，必须用这个版本才能精确到四角。
   */
  static clampScreenOffset(value: number, contentScreenSize: number,
    viewSize: number, pad: number): number {
    // 内容尚未测量时不要居中，否则会把偏移错误地推到 viewSize / 2
    if (contentScreenSize <= 0) {
      return 0;
    }
    if (contentScreenSize <= viewSize) {
      return (viewSize - contentScreenSize) / 2;
    }
    const min: number = viewSize - contentScreenSize - pad;
    const max: number = pad;
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}
