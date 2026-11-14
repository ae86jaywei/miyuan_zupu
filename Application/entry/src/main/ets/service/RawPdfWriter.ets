import { fileIo } from '@kit.CoreFileKit';
import { RawPdfFont } from './RawPdfFont';

/**
 * 极简 PDF 写入器（方案 F）。
 *
 * 设计目标：绕开 PDFKit 在 saveDocument 阶段把整卷图片读入 native 内存的问题。
 *  - 每页只放 1 张整页 JPEG，直接以 `/Filter /DCTDecode` 原样嵌入，**不解码 PixelMap**；
 *  - 逐页 append 写文件，写完后当前页字节即可释放；
 *  - 只维护 xref 偏移表（每页 3 个对象），内存与页数基本无关；
 *  - 文字已经画进 300dpi 栅格图，PDF 文字层只保留 ASCII 页码（可选）。
 *
 * 说明：这里只生成 PDF 1.4 的最小结构（Catalog / Pages / Page / Image XObject / Content），
 * 不依赖 PDFKit，也不做字体嵌入；中文文字在栅格图内，打印清晰，但暂不支持文本搜索。
 */
const OBJ_CATALOG: number = 1;
const OBJ_PAGES: number = 2;
const OBJ_FONT: number = 3;
const FIRST_PAGE_OBJ: number = 4;

/** 一页上的一段可搜索文本（F2）：默认不可见，只用于检索/复制，视觉由栅格图承载 */
export class PdfTextRun {
  text: string = '';
  xPt: number = 0;
  yPt: number = 0;
  sizePt: number = 9;
  invisible: boolean = true;
}

export class RawPdfWriter {
  private fd: number = -1;
  private offset: number = 0;
  private offsets: number[] = [];
  private pageIds: number[] = [];
  private nextObj: number = FIRST_PAGE_OBJ;
  private pageW: number = 0;
  private pageH: number = 0;
  private imageW: number = 0;
  private imageH: number = 0;
  /** 文档中用到的字符（Unicode 码点），用于生成 ToUnicode，保证可检索 */
  private usedChars: Set<number> = new Set<number>();
  /** GID → Unicode（F3 嵌入 TTF 时生成 ToUnicode） */
  private usedGids: Map<number, number> = new Map<number, number>();
  /** 嵌入字体；为 null 时退回 STSong-Light（不嵌入） */
  private font: RawPdfFont | null = null;

  constructor(path: string, pageW: number, pageH: number, imageW: number, imageH: number,
    font: RawPdfFont | null = null) {
    this.pageW = pageW;
    this.pageH = pageH;
    this.imageW = imageW;
    this.imageH = imageH;
    this.font = font;
    this.fd = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    this.writeAscii('%PDF-1.4\n');
  }

  /** 写 ASCII 字符串（PDF 语法全部为 ASCII） */
  private writeAscii(s: string): void {
    const bytes: Uint8Array = new Uint8Array(s.length);
    for (let i: number = 0; i < s.length; i = i + 1) {
      bytes[i] = s.charCodeAt(i) & 0x7f;
    }
    fileIo.writeSync(this.fd, bytes.buffer);
    this.offset += bytes.length;
  }

  /** 写 JPEG 原始字节：只复制，不解码 */
  private writeJpegBytes(srcFd: number, size: number): void {
    const chunk: ArrayBuffer = new ArrayBuffer(65536);
    let left: number = size;
    while (left > 0) {
      const n: number = fileIo.readSync(srcFd, chunk);
      if (n <= 0) {
        break;
      }
      const part: Uint8Array = new Uint8Array(n);
      part.set(new Uint8Array(chunk, 0, n));
      fileIo.writeSync(this.fd, part.buffer);
      this.offset += n;
      left -= n;
    }
  }

  private beginObj(id: number): void {
    while (this.offsets.length <= id) {
      this.offsets.push(0);
    }
    this.offsets[id] = this.offset;
    this.writeAscii(id.toString() + ' 0 obj\n');
  }

  /**
   * 追加一页：整页 JPEG + 可选 ASCII 页码。
   * JPEG 文件写完即可删除，PDF 中已经保存了字节副本。
   */
  addJpegPage(jpegPath: string, runs: PdfTextRun[]): void {
    const size: number = fileIo.statSync(jpegPath).size;
    const pageId: number = this.nextObj;
    const imageId: number = this.nextObj + 1;
    const contentId: number = this.nextObj + 2;
    this.nextObj = this.nextObj + 3;

    // Page 对象
    this.beginObj(pageId);
    this.writeAscii('<< /Type /Page /Parent ' + OBJ_PAGES.toString() + ' 0 R /MediaBox [0 0 ' +
      this.pageW.toString() + ' ' + this.pageH.toString() + '] /Resources << /XObject << /Im0 ' +
      imageId.toString() + ' 0 R >> /Font << /F1 ' + OBJ_FONT.toString() + ' 0 R >> >> /Contents ' +
      contentId.toString() + ' 0 R >>\nendobj\n');

    // Image XObject：JPEG 原始字节，DCTDecode 不解码
    this.beginObj(imageId);
    this.writeAscii('<< /Type /XObject /Subtype /Image /Width ' + this.imageW.toString() +
      ' /Height ' + this.imageH.toString() + ' /ColorSpace /DeviceRGB /BitsPerComponent 8' +
      ' /Filter /DCTDecode /Length ' + size.toString() + ' >>\nstream\n');
    const srcFd: number = fileIo.openSync(jpegPath, fileIo.OpenMode.READ_ONLY);
    try {
      this.writeJpegBytes(srcFd, size);
    } finally {
      fileIo.closeSync(srcFd);
    }
    this.writeAscii('\nendstream\nendobj\n');

    // Content：整页铺图 + 不可见的可搜索文本层（UniGB-UCS2-H）
    let content: string = 'q\n' + this.pageW.toString() + ' 0 0 ' + this.pageH.toString() +
      ' 0 0 cm\n/Im0 Do\nQ\n';
    for (let i: number = 0; i < runs.length; i = i + 1) {
      const r: PdfTextRun = runs[i];
      if (r.text.length === 0) {
        continue;
      }
      for (let k: number = 0; k < r.text.length; k = k + 1) {
        this.usedChars.add(r.text.charCodeAt(k));
      }
      content = content + 'BT /F1 ' + r.sizePt.toFixed(2) + ' Tf ' +
        (r.invisible ? '3 Tr' : '0 Tr') + ' ' + r.xPt.toFixed(2) + ' ' + r.yPt.toFixed(2) +
        ' Td <' + this.textHex(r.text) + '> Tj ET\n';
    }
    this.beginObj(contentId);
    this.writeAscii('<< /Length ' + content.length.toString() + ' >>\nstream\n' + content +
      'endstream\nendobj\n');

    this.pageIds.push(pageId);
  }

  /** 完成文档：写 Pages / Catalog / Font / xref / trailer */
  finish(): void {
    if (this.font !== null) {
      // F3：嵌入 TTF，Identity-H（CID=GID），ToUnicode 保证可检索
      const f: RawPdfFont = this.font;
      const cidFontId: number = this.nextObj;
      const descId: number = this.nextObj + 1;
      const toUnicodeId: number = this.nextObj + 2;
      const fontFileId: number = this.nextObj + 3;
      this.nextObj = this.nextObj + 4;

      this.beginObj(OBJ_FONT);
      this.writeAscii('<< /Type /Font /Subtype /Type0 /BaseFont /HarmonyOS-Sans' +
        ' /Encoding /Identity-H /DescendantFonts [' + cidFontId.toString() + ' 0 R]' +
        ' /ToUnicode ' + toUnicodeId.toString() + ' 0 R >>\nendobj\n');
      this.beginObj(cidFontId);
      this.writeAscii('<< /Type /Font /Subtype /CIDFontType2 /BaseFont /HarmonyOS-Sans' +
        ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>' +
        ' /FontDescriptor ' + descId.toString() + ' 0 R /CIDToGIDMap /Identity /DW 1000 >>\nendobj\n');
      this.beginObj(descId);
      this.writeAscii('<< /Type /FontDescriptor /FontName /HarmonyOS-Sans /Flags 4' +
        ' /FontBBox [' + f.xMin.toString() + ' ' + f.yMin.toString() + ' ' +
        f.xMax.toString() + ' ' + f.yMax.toString() + '] /ItalicAngle 0' +
        ' /Ascent ' + f.ascent.toString() + ' /Descent ' + f.descent.toString() +
        ' /CapHeight ' + f.ascent.toString() + ' /StemV 80 /FontFile2 ' +
        fontFileId.toString() + ' 0 R >>\nendobj\n');

      // ToUnicode：GID → Unicode
      const gids: number[] = [];
      this.usedGids.forEach((code: number, gid: number): void => {
        gids.push(gid);
      });
      gids.sort((a: number, b: number): number => a - b);
      let cmap: string = '/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n' +
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n' +
        '/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n' +
        '1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n';
      for (let i: number = 0; i < gids.length; i = i + 100) {
        const end: number = Math.min(i + 100, gids.length);
        cmap = cmap + (end - i).toString() + ' beginbfchar\n';
        for (let k: number = i; k < end; k = k + 1) {
          const gid: number = gids[k];
          const code: number = this.usedGids.get(gid) ?? 0;
          cmap = cmap + '<' + RawPdfWriter.hex4(gid) + '> <' + RawPdfWriter.hex4(code) + '>\n';
        }
        cmap = cmap + 'endbfchar\n';
      }
      cmap = cmap + 'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n';
      this.beginObj(toUnicodeId);
      this.writeAscii('<< /Length ' + cmap.length.toString() + ' >>\nstream\n' + cmap +
        'endstream\nendobj\n');

      // FontFile2：整字体 TTF 原始字节
      this.beginObj(fontFileId);
      this.writeAscii('<< /Length ' + f.bytes.length.toString() + ' /Length1 ' +
        f.bytes.length.toString() + ' >>\nstream\n');
      fileIo.writeSync(this.fd, f.bytes.buffer);
      this.offset += f.bytes.length;
      this.writeAscii('\nendstream\nendobj\n');
    } else {
      // 回退：STSong-Light（不嵌入），UniGB-UCS2-H
      const cidFontId: number = this.nextObj;
      const descId: number = this.nextObj + 1;
      const toUnicodeId: number = this.nextObj + 2;
      this.nextObj = this.nextObj + 3;

      this.beginObj(OBJ_FONT);
      this.writeAscii('<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light' +
        ' /Encoding /UniGB-UCS2-H /DescendantFonts [' + cidFontId.toString() + ' 0 R]' +
        ' /ToUnicode ' + toUnicodeId.toString() + ' 0 R >>\nendobj\n');
      this.beginObj(cidFontId);
      this.writeAscii('<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light' +
        ' /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >>' +
        ' /FontDescriptor ' + descId.toString() + ' 0 R /DW 1000 >>\nendobj\n');
      this.beginObj(descId);
      this.writeAscii('<< /Type /FontDescriptor /FontName /STSong-Light /Flags 4' +
        ' /FontBBox [-25 -254 1000 880] /ItalicAngle 0 /Ascent 880 /Descent -120' +
        ' /CapHeight 880 /StemV 80 >>\nendobj\n');

      const codes: number[] = [];
      this.usedChars.forEach((c: number): void => {
        codes.push(c);
      });
      codes.sort((a: number, b: number): number => a - b);
      let cmap: string = '/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n' +
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n' +
        '/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n' +
        '1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n';
      for (let i: number = 0; i < codes.length; i = i + 100) {
        const end: number = Math.min(i + 100, codes.length);
        cmap = cmap + (end - i).toString() + ' beginbfchar\n';
        for (let k: number = i; k < end; k = k + 1) {
          const hex: string = RawPdfWriter.hex4(codes[k]);
          cmap = cmap + '<' + hex + '> <' + hex + '>\n';
        }
        cmap = cmap + 'endbfchar\n';
      }
      cmap = cmap + 'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n';
      this.beginObj(toUnicodeId);
      this.writeAscii('<< /Length ' + cmap.length.toString() + ' >>\nstream\n' + cmap +
        'endstream\nendobj\n');
    }

    // Pages
    this.beginObj(OBJ_PAGES);
    let kids: string = '';
    for (let i: number = 0; i < this.pageIds.length; i = i + 1) {
      kids = kids + this.pageIds[i].toString() + ' 0 R ';
    }
    this.writeAscii('<< /Type /Pages /Kids [' + kids + '] /Count ' +
      this.pageIds.length.toString() + ' >>\nendobj\n');

    // Catalog
    this.beginObj(OBJ_CATALOG);
    this.writeAscii('<< /Type /Catalog /Pages ' + OBJ_PAGES.toString() + ' 0 R >>\nendobj\n');

    const xrefStart: number = this.offset;
    const totalObj: number = this.nextObj;
    this.writeAscii('xref\n0 ' + totalObj.toString() + '\n');
    this.writeAscii('0000000000 65535 f \n');
    for (let i: number = 1; i < totalObj; i = i + 1) {
      const off: number = this.offsets.length > i ? this.offsets[i] : 0;
      this.writeAscii(RawPdfWriter.pad10(off) + ' 00000 n \n');
    }
    this.writeAscii('trailer\n<< /Size ' + totalObj.toString() + ' /Root ' +
      OBJ_CATALOG.toString() + ' 0 R >>\nstartxref\n' + xrefStart.toString() + '\n%%EOF\n');
    if (this.fd >= 0) {
      fileIo.closeSync(this.fd);
      this.fd = -1;
    }
  }

  /** 文本编码：嵌入字体时用 GID，回退时用 UTF-16BE */
  private textHex(s: string): string {
    if (this.font === null) {
      return RawPdfWriter.utf16Hex(s);
    }
    let out: string = '';
    for (let i: number = 0; i < s.length; i = i + 1) {
      const code: number = s.charCodeAt(i);
      const gid: number = this.font.gidOf(code);
      if (gid > 0) {
        this.usedGids.set(gid, code);
      }
      out = out + RawPdfWriter.hex4(gid);
    }
    return out;
  }

  /** 文本转 UTF-16BE 十六进制（UniGB-UCS2-H 编码） */
  private static utf16Hex(s: string): string {
    let out: string = '';
    for (let i: number = 0; i < s.length; i = i + 1) {
      out = out + RawPdfWriter.hex4(s.charCodeAt(i));
    }
    return out;
  }

  private static hex4(code: number): string {
    let s: string = code.toString(16);
    while (s.length < 4) {
      s = '0' + s;
    }
    return s;
  }

  private static pad10(n: number): string {
    let s: string = n.toString();
    while (s.length < 10) {
      s = '0' + s;
    }
    return s;
  }

  private static escape(s: string): string {
    let out: string = '';
    for (let i: number = 0; i < s.length; i = i + 1) {
      const c: string = s.charAt(i);
      if (c === '\\' || c === '(' || c === ')') {
        out = out + '\\' + c;
      } else {
        out = out + c;
      }
    }
    return out;
  }
}