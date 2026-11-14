import { fileIo } from '@kit.CoreFileKit';

/**
 * 极简 TrueType 解析（F3）。
 *
 * 只做 RawPdfWriter 嵌入中文字体所需的事：
 *  - 读取 TTF 字节（整字体嵌入）；
 *  - 解析 cmap format 4，把 Unicode 映射成 GID；
 *  - 读取 head/hhea 的 em、Ascent/Descent/BBox；
 *  - 读取 hmtx 的 advance（当前只做兜底）。
 *
 * 文本层使用 Identity-H：CID 就是 GID，ToUnicode 再把 GID 映射回 Unicode，
 * 因此 PDF 可搜索/复制，且不依赖阅读器是否安装中文字体。
 */
class CmapSegment {
  start: number = 0;
  end: number = 0;
  delta: number = 0;
  rangeOffset: number = 0;
  /** idRangeOffset 元素在文件中的位置 */
  rangeOffsetPos: number = 0;
}

export class RawPdfFont {
  bytes: Uint8Array;
  /** 已换算到 1000 em 的字体度量 */
  ascent: number = 880;
  descent: number = -120;
  xMin: number = 0;
  yMin: number = -200;
  xMax: number = 1000;
  yMax: number = 880;
  unitsPerEm: number = 1000;

  private dv: DataView;
  private segments: CmapSegment[] = [];
  private numberOfHMetrics: number = 0;
  private hmtxOffset: number = 0;

  private constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.parse();
  }

  static load(path: string): RawPdfFont | null {
    try {
      const size: number = fileIo.statSync(path).size;
      if (size <= 0) {
        return null;
      }
      const bytes: Uint8Array = new Uint8Array(size);
      const fd: number = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const chunk: ArrayBuffer = new ArrayBuffer(65536);
        let pos: number = 0;
        while (pos < size) {
          const n: number = fileIo.readSync(fd, chunk);
          if (n <= 0) {
            break;
          }
          bytes.set(new Uint8Array(chunk, 0, n), pos);
          pos = pos + n;
        }
        if (pos < size) {
          return null;
        }
      } finally {
        fileIo.closeSync(fd);
      }
      return new RawPdfFont(bytes);
    } catch (_e) {
      return null;
    }
  }

  private u16(off: number): number {
    return this.dv.getUint16(off);
  }

  private i16(off: number): number {
    return this.dv.getInt16(off);
  }

  private u32(off: number): number {
    return this.dv.getUint32(off);
  }

  private tag(off: number): string {
    return String.fromCharCode(this.dv.getUint8(off), this.dv.getUint8(off + 1),
      this.dv.getUint8(off + 2), this.dv.getUint8(off + 3));
  }

  private findTable(name: string): number {
    const num: number = this.u16(4);
    for (let i: number = 0; i < num; i = i + 1) {
      const rec: number = 12 + i * 16;
      if (this.tag(rec) === name) {
        return this.u32(rec + 8);
      }
    }
    return 0;
  }

  private parse(): void {
    const cmapOff: number = this.findTable('cmap');
    const headOff: number = this.findTable('head');
    const hheaOff: number = this.findTable('hhea');
    const hmtxOff: number = this.findTable('hmtx');
    if (cmapOff === 0 || headOff === 0 || hheaOff === 0) {
      throw new Error('not a ttf');
    }

    this.unitsPerEm = this.u16(headOff + 18);
    if (this.unitsPerEm <= 0) {
      this.unitsPerEm = 1000;
    }
    const scale: number = 1000 / this.unitsPerEm;
    this.xMin = Math.round(this.i16(headOff + 36) * scale);
    this.yMin = Math.round(this.i16(headOff + 38) * scale);
    this.xMax = Math.round(this.i16(headOff + 40) * scale);
    this.yMax = Math.round(this.i16(headOff + 42) * scale);
    this.ascent = Math.round(this.i16(hheaOff + 4) * scale);
    this.descent = Math.round(this.i16(hheaOff + 6) * scale);
    this.numberOfHMetrics = this.u16(hheaOff + 34);
    this.hmtxOffset = hmtxOff;

    // cmap：优先 Windows Unicode BMP（3,1），其次 Unicode（0,3/0,4）
    const numSub: number = this.u16(cmapOff + 2);
    let subOff: number = 0;
    for (let i: number = 0; i < numSub; i = i + 1) {
      const rec: number = cmapOff + 4 + i * 8;
      const platform: number = this.u16(rec);
      const encoding: number = this.u16(rec + 2);
      const off: number = cmapOff + this.u32(rec + 4);
      if (this.u16(off) !== 4) {
        continue;
      }
      if ((platform === 3 && encoding === 1) || platform === 0) {
        subOff = off;
        if (platform === 3) {
          break;
        }
      }
    }
    if (subOff === 0) {
      throw new Error('no cmap format4');
    }

    const segCount: number = this.u16(subOff + 6) / 2;
    const endBase: number = subOff + 14;
    const startBase: number = endBase + segCount * 2 + 2;
    const deltaBase: number = startBase + segCount * 2;
    const rangeBase: number = deltaBase + segCount * 2;
    for (let i: number = 0; i < segCount; i = i + 1) {
      const seg: CmapSegment = new CmapSegment();
      seg.start = this.u16(startBase + i * 2);
      seg.end = this.u16(endBase + i * 2);
      seg.delta = this.i16(deltaBase + i * 2);
      seg.rangeOffsetPos = rangeBase + i * 2;
      seg.rangeOffset = this.u16(seg.rangeOffsetPos);
      this.segments.push(seg);
    }
  }

  /** Unicode 码点 → GID；缺字返回 0 */
  gidOf(code: number): number {
    for (let i: number = 0; i < this.segments.length; i = i + 1) {
      const seg: CmapSegment = this.segments[i];
      if (code < seg.start) {
        continue;
      }
      if (code > seg.end) {
        continue;
      }
      if (seg.rangeOffset === 0) {
        return (code + seg.delta) & 0xffff;
      }
      const pos: number = seg.rangeOffsetPos + seg.rangeOffset + (code - seg.start) * 2;
      if (pos < 0 || pos + 1 >= this.bytes.length) {
        return 0;
      }
      let gid: number = this.u16(pos);
      if (gid !== 0) {
        gid = (gid + seg.delta) & 0xffff;
      }
      return gid;
    }
    return 0;
  }

  /** GID 的 advance（当前未用于排版，保留给后续字距优化） */
  advance(gid: number): number {
    if (this.hmtxOffset === 0 || this.numberOfHMetrics <= 0) {
      return 1000;
    }
    const idx: number = gid < this.numberOfHMetrics ? gid : this.numberOfHMetrics - 1;
    return this.u16(this.hmtxOffset + idx * 4);
  }
}