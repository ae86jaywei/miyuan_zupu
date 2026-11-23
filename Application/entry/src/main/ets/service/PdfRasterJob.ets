import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { LengthMetricsUnit } from '@kit.ArkUI';

/**
 * 分页 PDF 栅格层的公共几何与绘制。
 *
 * TaskPool 的并发函数只能引用「导入的变量」，不能直接读取同文件模块级常量，
 * 因此把栅格常量、绘制逻辑和 worker 任务实现独立到本文件：
 *  - 导出服务从本文件取几何常量，保证排版与栅格完全一致；
 *  - worker 通过导入的方式调用 renderTileImpl / paintRasterTile。
 */

/** 成品纸张：横版 320×220mm，与分页画布完全一致 */
export const PAGE_W_MM: number = 320;
export const PAGE_H_MM: number = 220;

/**
 * 栅格层：300dpi（320×220mm → 约 3780×2598px）。
 * 恢复 4625ab1 可导出版本的参数；2×2 分块，单块约 1890×1299px。
 */
export const RENDER_DPI: number = 300;
export const PX_PER_MM: number = RENDER_DPI / 25.4;
export const RENDER_W: number = Math.round(PAGE_W_MM * PX_PER_MM);
export const RENDER_H: number = Math.round(PAGE_H_MM * PX_PER_MM);
/**
 * 方案 F 使用整页单图：300dpi 整页 3780×2598（<4096），1×1 不分块。
 * JPEG 直接嵌入 PDF，不解码，因此不牺牲清晰度。
 */
export const TILE_COLS: number = 1;
export const TILE_ROWS: number = 1;
export const TILE_W: number = Math.ceil(RENDER_W / TILE_COLS);
export const TILE_H: number = Math.ceil(RENDER_H / TILE_ROWS);

/**
 * JPEG 质量恢复 4625ab1 的 95：每页渲染完立即删除临时图，质量可以回到印刷档。
 */
export const JPEG_QUALITY: number = 95;

/** 页眉/版心上下边界（与 PrintLayout 保持一致） */
export const INNER_Y_MM: number = 20;
/** 装订口宽：双面印刷时左右两侧轮流出现，位置由每页几何传入 */
export const GUTTER_MM: number = 20;

export const C_PAPER: string = '#FFFDF6';
export const C_BIND: string = '#F4EFE3';
export const C_INK: string = '#2E2A24';
export const C_INK2: string = '#7A6A57';
export const C_GOLD: string = '#C9A227';
export const C_RED: string = '#B03A2E';
export const C_FEMALE: string = '#A0527A';
export const C_LINE: string = '#D8CBB2';
export const C_FOOT: string = '#8C2F1E';

/**
 * 在一块 PX 单位的离屏画布上画出整页栅格内容（纸面、装订口、页框、连线、卡片框）。
 * 只画与当前分块相交的元素；文字全部留给 PDF 文本对象，不进栅格层。
 *
 * @param innerXMm 本页版心左边界（双面印刷时奇偶页不同）
 * @param gutterXMm 本页装订口左边界
 * @param gutterWMm 装订口宽
 */
export function paintRasterTile(g: OffscreenCanvasRenderingContext2D, x0: number, y0: number,
  x1: number, y1: number, lineWidthMm: number, lineData: number[], boxData: number[],
  innerXMm: number, gutterXMm: number, gutterWMm: number): void {
  g.clearRect(0, 0, TILE_W, TILE_H);

  // 底图（纸面 + 装订口 + 页框）：整页坐标绘制，由画布边缘裁切，分块接缝严格对齐
  g.fillStyle = C_PAPER;
  g.fillRect(-x0, -y0, RENDER_W, RENDER_H);
  g.fillStyle = C_BIND;
  g.fillRect(gutterXMm * PX_PER_MM - x0, -y0, gutterWMm * PX_PER_MM, RENDER_H);
  g.strokeStyle = C_LINE;
  g.lineWidth = 1;
  g.strokeRect(0.5 - x0, 0.5 - y0, RENDER_W - 1, RENDER_H - 1);

  const lw: number = Math.max(1, lineWidthMm * PX_PER_MM);
  const pad: number = lw + 2;

  // 连线：红色婚约双线 / 金色世系线
  for (let i: number = 0; i + 4 < lineData.length; i += 5) {
    const ax: number = (innerXMm + lineData[i]) * PX_PER_MM;
    const ay: number = (INNER_Y_MM + lineData[i + 1]) * PX_PER_MM;
    const bx: number = (innerXMm + lineData[i + 2]) * PX_PER_MM;
    const by: number = (INNER_Y_MM + lineData[i + 3]) * PX_PER_MM;
    if (Math.max(ax, bx) + pad < x0 || Math.min(ax, bx) - pad > x1
      || Math.max(ay, by) + pad < y0 || Math.min(ay, by) - pad > y1) {
      continue;
    }
    g.strokeStyle = lineData[i + 4] === 1 ? C_RED : C_GOLD;
    // 2 = 按父亲分组的分隔线：金色但压淡，与真实世系线区分
    g.globalAlpha = lineData[i + 4] === 2 ? 0.45 : 1;
    g.lineWidth = lw;
    g.beginPath();
    g.moveTo(ax - x0, ay - y0);
    g.lineTo(bx - x0, by - y0);
    g.stroke();
  }
  g.globalAlpha = 1;

  // 卡片：底色 + 描边（女卡绛紫描边）
  for (let i: number = 0; i + 4 < boxData.length; i += 5) {
    const cx0: number = (innerXMm + boxData[i]) * PX_PER_MM;
    const cy0: number = (INNER_Y_MM + boxData[i + 1]) * PX_PER_MM;
    const cw: number = boxData[i + 2] * PX_PER_MM;
    const ch: number = boxData[i + 3] * PX_PER_MM;
    if (cx0 + cw < x0 || cx0 > x1 || cy0 + ch < y0 || cy0 > y1) {
      continue;
    }
    g.fillStyle = boxData[i + 4] > 0 ? '#FBF1F5' : '#FFFFFF';
    g.fillRect(cx0 - x0, cy0 - y0, cw, ch);
    g.strokeStyle = boxData[i + 4] > 0 ? C_FEMALE : C_GOLD;
    g.lineWidth = Math.max(1, 0.2 * PX_PER_MM);
    g.strokeRect(cx0 - x0 + 0.5, cy0 - y0 + 0.5, cw - 1, ch - 1);
  }
}

/**
 * 渲染并编码一块栅格，返回落盘文件路径。
 * 画布显式使用 PX 单位，确保 1 单位 = 1 像素（默认 vp 会再乘屏幕密度，
 * 实际渲染分辨率翻数倍，既慢又占内存）。
 */
export async function renderTileImpl(pageNo: number, r: number, c: number, lineWidthMm: number,
  lineData: number[], boxData: number[], cacheDir: string, innerXMm: number, gutterXMm: number,
  gutterWMm: number): Promise<string> {
  const x0: number = Math.round(c * RENDER_W / TILE_COLS);
  const x1: number = Math.round((c + 1) * RENDER_W / TILE_COLS);
  const y0: number = Math.round(r * RENDER_H / TILE_ROWS);
  const y1: number = Math.round((r + 1) * RENDER_H / TILE_ROWS);
  const w: number = x1 - x0;
  const h: number = y1 - y0;

  const off: OffscreenCanvas = new OffscreenCanvas(TILE_W, TILE_H, LengthMetricsUnit.PX);
  const g: OffscreenCanvasRenderingContext2D = off.getContext('2d');
  paintRasterTile(g, x0, y0, x0 + w, y0 + h, lineWidthMm, lineData, boxData,
    innerXMm, gutterXMm, gutterWMm);

  const pm: image.PixelMap = g.getPixelMap(0, 0, w, h);
  const packer: image.ImagePacker = image.createImagePacker();
  let buf: ArrayBuffer;
  try {
    const opt: image.PackingOption = { format: 'image/jpeg', quality: JPEG_QUALITY };
    buf = await packer.packing(pm, opt);
  } finally {
    pm.release();
    packer.release();
  }

  const imgPath: string = cacheDir + '/paged_pdf_' + pageNo.toString() +
    '_' + r.toString() + '_' + c.toString() + '.jpg';
  const fd: fileIo.File = fileIo.openSync(imgPath,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(fd.fd, buf);
  } finally {
    fileIo.closeSync(fd);
  }
  return imgPath;
}
