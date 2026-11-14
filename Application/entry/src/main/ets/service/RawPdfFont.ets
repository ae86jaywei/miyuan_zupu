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

/** cmap format 12 的分组：Unicode 区间 → 起始 GID */
class CmapGroup {
  start: number = 0;
  end: number = 0;
  gid: number = 0;
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
  private groups: CmapGroup[] = [];
  private useFormat12: boolean = false;
  /** 子集化需要的表位置与度量 */
  private headOffset: number = 0;
  private maxpOffset: number = 0;
  private hheaOffset: number = 0;
  private locaOffset: number = 0;
  private locaFormat: number = 0;
  private glyfOffset: number = 0;
  private numGlyphs: number = 0;
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
      const fh: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const chunk: ArrayBuffer = new ArrayBuffer(65536);
        let pos: number = 0;
        while (pos < size) {
          const n: number = fileIo.readSync(fh.fd, chunk);
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
        fileIo.closeSync(fh);
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

    // 子集化需要的表（缺失时不启用子集）
    this.headOffset = headOff;
    this.hheaOffset = hheaOff;
    this.maxpOffset = this.findTable('maxp');
    this.locaOffset = this.findTable('loca');
    this.glyfOffset = this.findTable('glyf');
    this.locaFormat = this.i16(headOff + 50);
    this.numGlyphs = this.maxpOffset > 0 ? this.u16(this.maxpOffset + 4) : 0;

    // cmap：优先 Windows Unicode BMP（3,1）format 4；没有时用 format 12（3,10 / 0,4）
    const numSub: number = this.u16(cmapOff + 2);
    let sub4: number = 0;
    let sub12: number = 0;
    for (let i: number = 0; i < numSub; i = i + 1) {
      const rec: number = cmapOff + 4 + i * 8;
      const platform: number = this.u16(rec);
      const encoding: number = this.u16(rec + 2);
      const off: number = cmapOff + this.u32(rec + 4);
      const fmt: number = this.u16(off);
      if (fmt === 4 && sub4 === 0 && ((platform === 3 && encoding === 1) || platform === 0)) {
        sub4 = off;
      } else if (fmt === 12 && sub12 === 0 &&
        ((platform === 3 && encoding === 10) || platform === 0)) {
        sub12 = off;
      }
    }
    if (sub4 !== 0) {
      const segCount: number = this.u16(sub4 + 6) / 2;
      const endBase: number = sub4 + 14;
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
    } else if (sub12 !== 0) {
      const n: number = this.u32(sub12 + 12);
      const base: number = sub12 + 16;
      for (let i: number = 0; i < n; i = i + 1) {
        const g: CmapGroup = new CmapGroup();
        g.start = this.u32(base + i * 12);
        g.end = this.u32(base + i * 12 + 4);
        g.gid = this.u32(base + i * 12 + 8);
        this.groups.push(g);
      }
      this.useFormat12 = true;
    } else {
      throw new Error('no cmap format4/12');
    }
  }

  /** Unicode 码点 → GID；缺字返回 0 */
  gidOf(code: number): number {
    if (this.useFormat12) {
      let lo: number = 0;
      let hi: number = this.groups.length - 1;
      while (lo <= hi) {
        const mid: number = (lo + hi) >> 1;
        const g: CmapGroup = this.groups[mid];
        if (code < g.start) {
          hi = mid - 1;
        } else if (code > g.end) {
          lo = mid + 1;
        } else {
          return g.gid + (code - g.start);
        }
      }
      return 0;
    }
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

  /** GID 的 advance 换算到 1000 em（PDF /W 字宽表用） */
  advance1000(gid: number): number {
    if (this.unitsPerEm <= 0) {
      return 1000;
    }
    return Math.round(this.advance(gid) * 1000 / this.unitsPerEm);
  }

  private findTableLen(name: string): number {
    const num: number = this.u16(4);
    for (let i: number = 0; i < num; i = i + 1) {
      const rec: number = 12 + i * 16;
      if (this.tag(rec) === name) {
        return this.u32(rec + 12);
      }
    }
    return 0;
  }

  /** 字形在 glyf 表中的 [start, end) */
  private glyfRange(gid: number): number[] {
    if (this.locaOffset === 0 || this.glyfOffset === 0 || gid < 0 || gid >= this.numGlyphs) {
      return [0, 0];
    }
    if (this.locaFormat === 0) {
      const s: number = this.u16(this.locaOffset + gid * 2) * 2;
      const e: number = this.u16(this.locaOffset + (gid + 1) * 2) * 2;
      return [s, e];
    }
    const s: number = this.u32(this.locaOffset + gid * 4);
    const e: number = this.u32(this.locaOffset + (gid + 1) * 4);
    return [s, e];
  }

  /** 复合字形引用的组件 GID（简单字形返回空） */
  private componentGids(gid: number): number[] {
    const out: number[] = [];
    const r: number[] = this.glyfRange(gid);
    if (r[1] - r[0] < 12) {
      return out;
    }
    let p: number = this.glyfOffset + r[0];
    if (this.i16(p) >= 0) {
      return out;
    }
    p = p + 10; // numberOfContours(2) + bbox(8)
    while (p + 4 <= this.glyfOffset + r[1]) {
      const flags: number = this.u16(p);
      const idx: number = this.u16(p + 2);
      out.push(idx);
      p = p + 4;
      p = p + ((flags & 0x0001) !== 0 ? 4 : 2);
      if ((flags & 0x0008) !== 0) {
        p = p + 2;
      } else if ((flags & 0x0040) !== 0) {
        p = p + 4;
      } else if ((flags & 0x0080) !== 0) {
        p = p + 8;
      }
      if ((flags & 0x0020) === 0) {
        break;
      }
    }
    return out;
  }

  /**
   * 生成子集字体（GID 保持不变，只保留用到 + 复合组件 + 0 号字形）。
   * 20.6MB 的中文字体经此裁剪后通常只剩几百 KB，PDF 每卷各带一份也不至于爆体积。
   * 结构不支持或任何异常时返回原字体（宁可大，不可排版错）。
   */
  subsetBytes(used: Set<number>): Uint8Array {
    if (this.locaOffset === 0 || this.glyfOffset === 0 || this.numGlyphs <= 0 ||
      this.headOffset === 0 || this.maxpOffset === 0 || this.hheaOffset === 0) {
      return this.bytes;
    }
    const keep: Set<number> = new Set<number>();
    keep.add(0);
    used.forEach((g: number): void => {
      if (g >= 0 && g < this.numGlyphs) {
        keep.add(g);
      }
    });
    const stack: number[] = [];
    keep.forEach((g: number): void => {
      stack.push(g);
    });
    while (stack.length > 0) {
      const g: number = stack.pop() as number;
      const comps: number[] = this.componentGids(g);
      for (let i: number = 0; i < comps.length; i = i + 1) {
        const c: number = comps[i];
        if (c < this.numGlyphs && !keep.has(c)) {
          keep.add(c);
          stack.push(c);
        }
      }
    }

    // glyf / loca：统一写 long 格式
    const num: number = this.numGlyphs;
    const locaVals: number[] = [];
    const glyfChunks: Uint8Array[] = [];
    let glyfLen: number = 0;
    for (let g: number = 0; g < num; g = g + 1) {
      locaVals.push(glyfLen);
      if (!keep.has(g)) {
        continue;
      }
      const r: number[] = this.glyfRange(g);
      if (r[1] > r[0]) {
        const chunk: Uint8Array =
          this.bytes.subarray(this.glyfOffset + r[0], this.glyfOffset + r[1]);
        glyfChunks.push(chunk);
        glyfLen = glyfLen + chunk.length;
      }
    }
    locaVals.push(glyfLen);
    const glyf: Uint8Array = new Uint8Array(glyfLen);
    let w: number = 0;
    for (let i: number = 0; i < glyfChunks.length; i = i + 1) {
      glyf.set(glyfChunks[i], w);
      w = w + glyfChunks[i].length;
    }
    const loca: Uint8Array = new Uint8Array((num + 1) * 4);
    const dvLoca: DataView = new DataView(loca.buffer);
    for (let i: number = 0; i <= num; i = i + 1) {
      dvLoca.setUint32(i * 4, locaVals[i]);
    }

    const head: Uint8Array = new Uint8Array(54);
    head.set(this.bytes.subarray(this.headOffset, this.headOffset + 54));
    const dvHead: DataView = new DataView(head.buffer);
    dvHead.setUint32(8, 0);   // checkSumAdjustment 置 0
    dvHead.setInt16(50, 1);   // indexToLocFormat = long

    const hheaLen: number = this.findTableLen('hhea');
    const maxpLen: number = this.findTableLen('maxp');
    const hmtxLen: number = this.findTableLen('hmtx');
    const hhea: Uint8Array = this.bytes.subarray(this.hheaOffset, this.hheaOffset + hheaLen);
    const maxp: Uint8Array = this.bytes.subarray(this.maxpOffset, this.maxpOffset + maxpLen);
    const hmtx: Uint8Array = this.bytes.subarray(this.hmtxOffset, this.hmtxOffset + hmtxLen);

    const tags: string[] = ['glyf', 'head', 'hhea', 'hmtx', 'loca', 'maxp'];
    const datas: Uint8Array[] = [glyf, head, hhea, hmtx, loca, maxp];
    // 可选表：hinting 与字符边距信息，存在就带上
    const optTags: string[] = ['cvt ', 'fpgm', 'prep'];
    for (let i: number = 0; i < optTags.length; i = i + 1) {
      const off: number = this.findTable(optTags[i]);
      const len: number = this.findTableLen(optTags[i]);
      if (off > 0 && len > 0) {
        tags.push(optTags[i]);
        datas.push(this.bytes.subarray(off, off + len));
      }
    }

    const n: number = tags.length;
    let exp: number = 1;
    let expLog: number = 0;
    while (exp * 2 <= n) {
      exp = exp * 2;
      expLog = expLog + 1;
    }
    const dirLen: number = 12 + n * 16;
    const dir: Uint8Array = new Uint8Array(dirLen);
    const dvDir: DataView = new DataView(dir.buffer);
    dvDir.setUint32(0, 0x00010000);
    dvDir.setUint16(4, n);
    dvDir.setUint16(6, exp * 16);
    dvDir.setUint16(8, expLog);
    dvDir.setUint16(10, n * 16 - exp * 16);

    let offset: number = dirLen;
    const padded: Uint8Array[] = [];
    let total: number = dirLen;
    for (let i: number = 0; i < n; i = i + 1) {
      const data: Uint8Array = datas[i];
      const rec: number = 12 + i * 16;
      const tag: string = tags[i];
      dvDir.setUint8(rec, tag.charCodeAt(0));
      dvDir.setUint8(rec + 1, tag.charCodeAt(1));
      dvDir.setUint8(rec + 2, tag.charCodeAt(2));
      dvDir.setUint8(rec + 3, tag.charCodeAt(3));
      dvDir.setUint32(rec + 4, RawPdfFont.checksum(data));
      dvDir.setUint32(rec + 8, offset);
      dvDir.setUint32(rec + 12, data.length);
      const padLen: number = (4 - data.length % 4) % 4;
      const pad: Uint8Array = new Uint8Array(data.length + padLen);
      pad.set(data);
      padded.push(pad);
      offset = offset + pad.length;
      total = total + pad.length;
    }
    const out: Uint8Array = new Uint8Array(total);
    out.set(dir, 0);
    let p: number = dirLen;
    for (let i: number = 0; i < padded.length; i = i + 1) {
      out.set(padded[i], p);
      p = p + padded[i].length;
    }
    return out;
  }

  /** TTF 表 checksum（32 位累加） */
  private static checksum(data: Uint8Array): number {
    let sum: number = 0;
    const n: number = data.length;
    for (let i: number = 0; i < n; i = i + 4) {
      const b0: number = data[i];
      const b1: number = i + 1 < n ? data[i + 1] : 0;
      const b2: number = i + 2 < n ? data[i + 2] : 0;
      const b3: number = i + 3 < n ? data[i + 3] : 0;
      sum = (sum + ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)) >>> 0;
    }
    return sum;
  }
}