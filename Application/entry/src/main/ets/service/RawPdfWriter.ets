import { fileIo } from '@kit.CoreFileKit';
import { RawPdfFont } from './RawPdfFont';
import { ScriptService } from './ScriptService';

/**
 * 极简 PDF 写入器（方案 F）。
 *
 * 设计目标：绕开 PDFKit 在 saveDocument 阶段把整卷图片读入 native 内存的问题。
 *  - 每页只放 1 张整页 JPEG，直接以 `/Filter /DCTDecode` 原样嵌入，**不解码 PixelMap**；
 *  - 逐页 append 写文件，写完后当前页字节即可释放；
 *  - 只维护 xref 偏移表（每页 3 个对象），内存与页数基本无关；
 *  - 文字已经画进 300dpi 栅格图，PDF 文字层以不可见文本保留检索能力；
 *  - 可选嵌入子集字体（F3）、写 /Info 元信息与 /Outlines 书签。
 *
 * 说明：这里只生成 PDF 1.4 的最小结构（Catalog / Pages / Page / Image XObject / Content /
 * Font / Outlines / Info），不依赖 PDFKit。
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

/** 牒记式文本页的一行（矢量文字，直接可搜索） */
export class PdfTextLine {
  text: string = '';
  xPt: number = 0;
  yPt: number = 0;
  sizePt: number = 10;
  color: string = '#2B2B2B';
}

/** PDF 文档元信息（/Info），字符串统一按 UTF-16BE 写入 */
export class PdfInfo {
  title: string = '';
  author: string = '';
  subject: string = '';
  creator: string = '觅源族谱';
  producer: string = 'Miyuan RawPdfWriter';

  constructor(title: string) {
    this.title = title;
  }
}

/** 书签项：标题 + 目标页对象 ID */
class PdfBookmark {
  title: string = '';
  pageId: number = 0;

  constructor(title: string, pageId: number) {
    this.title = title;
    this.pageId = pageId;
  }
}

/** 子集字体名前缀（PDF 规范要求子集字体带 6 个大写字母 + 加号） */
const SUBSET_TAG: string = 'ABCDEF+';
const BASE_FONT: string = SUBSET_TAG + 'MiyuanHan';

/** Deflate 固定 Huffman 的长度码基值与额外位数（RFC 1951 3.2.5） */
const LEN_BASE: number[] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
/** Deflate 固定 Huffman 的距离码基值与额外位数 */
const DIST_BASE: number[] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DIST_EXTRA: number[] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

/** 当前时间的 PDF 日期字符串：D:YYYYMMDDHHmmSS+08'00' */
function pdfDate(): string {
  const d: Date = new Date();
  const offMin: number = -d.getTimezoneOffset();
  const sign: string = offMin >= 0 ? '+' : '-';
  const abs: number = Math.abs(offMin);
  return 'D:' + d.getFullYear().toString() + pad2(d.getMonth() + 1) + pad2(d.getDate()) +
    pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds()) +
    sign + pad2(Math.floor(abs / 60)) + "'" + pad2(abs % 60) + "'";
}

export class RawPdfWriter {
  /** 新版本 fileIo.openSync 返回 File 对象（不再返回 fd） */
  private fd: fileIo.File | null = null;
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
  /** 字体未覆盖的字符（码点），导出结束用于告警 */
  private missingChars: Set<number> = new Set<number>();
  /** 嵌入字体；为 null 时退回 STSong-Light（不嵌入） */
  private font: RawPdfFont | null = null;
  /** 文档元信息；为 null 时不写 /Info */
  private info: PdfInfo | null = null;
  /** 页级书签；为空时不写 /Outlines */
  private bookmarks: PdfBookmark[] = [];

  constructor(path: string, pageW: number, pageH: number, imageW: number, imageH: number,
    font: RawPdfFont | null = null, info: PdfInfo | null = null) {
    this.pageW = pageW;
    this.pageH = pageH;
    this.imageW = imageW;
    this.imageH = imageH;
    this.font = font;
    this.info = info;
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
    fileIo.writeSync(this.fdOrThrow().fd, bytes.buffer);
    this.offset += bytes.length;
  }

  /** 取当前写入句柄；已关闭则报错，避免静默丢字节 */
  private fdOrThrow(): fileIo.File {
    const f: fileIo.File | null = this.fd;
    if (f === null) {
      throw new Error('RawPdfWriter: 文件已关闭');
    }
    return f;
  }

  /** 写 JPEG 原始字节：只复制，不解码 */
  private writeJpegBytes(srcFile: fileIo.File, size: number): void {
    const chunk: ArrayBuffer = new ArrayBuffer(65536);
    let left: number = size;
    while (left > 0) {
      const n: number = fileIo.readSync(srcFile.fd, chunk);
      if (n <= 0) {
        break;
      }
      const part: Uint8Array = new Uint8Array(n);
      part.set(new Uint8Array(chunk, 0, n));
      fileIo.writeSync(this.fdOrThrow().fd, part.buffer);
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
   * bookmarkTitle 非空时，为这一页登记一个书签。
   */
  addJpegPage(jpegPath: string, runs: PdfTextRun[], bookmarkTitle: string = ''): void {
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
    const srcFile: fileIo.File = fileIo.openSync(jpegPath, fileIo.OpenMode.READ_ONLY);
    try {
      this.writeJpegBytes(srcFile, size);
    } finally {
      fileIo.closeSync(srcFile);
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
    if (bookmarkTitle.length > 0) {
      this.bookmarks.push(new PdfBookmark(ScriptService.getInstance().toDisplay(bookmarkTitle), pageId));
    }
  }

  /** 追加一页纯文本（牒记式）：无图片，文字矢量写入，可搜索/复制 */
  addTextLinePage(lines: PdfTextLine[], bookmarkTitle: string = '',
    gutterX: number = -1, gutterW: number = 0): void {
    const pageId: number = this.nextObj;
    const contentId: number = this.nextObj + 1;
    this.nextObj = this.nextObj + 2;

    this.beginObj(pageId);
    this.writeAscii('<< /Type /Page /Parent ' + OBJ_PAGES.toString() + ' 0 R /MediaBox [0 0 ' +
      this.pageW.toString() + ' ' + this.pageH.toString() + '] /Resources << /Font << /F1 ' +
      OBJ_FONT.toString() + ' 0 R >> >> /Contents ' + contentId.toString() + ' 0 R >>\nendobj\n');

    let content: string = 'q\n0.98 0.97 0.94 rg\n0 0 ' + this.pageW.toString() + ' ' +
      this.pageH.toString() + ' re\nf\nQ\n';
    // 装订口：浅米色色带 + 版心侧分隔线，位置由调用方按左右装订/奇偶页算好
    if (gutterW > 0 && gutterX >= 0) {
      content = content + 'q\n0.957 0.937 0.89 rg\n' + gutterX.toFixed(2) + ' 0 ' +
        gutterW.toFixed(2) + ' ' + this.pageH.toString() + ' re\nf\nQ\n';
      const lineX: number = gutterX <= 0.5 ? gutterX + gutterW : gutterX;
      content = content + 'q\n0.85 0.79 0.68 RG\n0.6 w\n' + lineX.toFixed(2) + ' 0 m\n' +
        lineX.toFixed(2) + ' ' + this.pageH.toString() + ' l\nS\nQ\n';
    }
    for (let i: number = 0; i < lines.length; i = i + 1) {
      const ln: PdfTextLine = lines[i];
      if (ln.text.trim().length === 0) {
        continue;
      }
      content = content + 'BT /F1 ' + ln.sizePt.toFixed(2) + ' Tf ' +
        RawPdfWriter.rgbOp(ln.color) + ' ' + ln.xPt.toFixed(2) + ' ' + ln.yPt.toFixed(2) +
        ' Td <' + this.textHex(ln.text) + '> Tj ET\n';
    }
    this.beginObj(contentId);
    this.writeAscii('<< /Length ' + content.length.toString() + ' >>\nstream\n' + content +
      'endstream\nendobj\n');
    this.pageIds.push(pageId);
    if (bookmarkTitle.length > 0) {
      this.bookmarks.push(new PdfBookmark(ScriptService.getInstance().toDisplay(bookmarkTitle), pageId));
    }
  }

  /** 十六进制颜色 → `r g b rg` */
  private static rgbOp(color: string): string {
    if (color.length === 7 && color.charAt(0) === '#') {
      const r: number = parseInt(color.substring(1, 3), 16) / 255;
      const g: number = parseInt(color.substring(3, 5), 16) / 255;
      const b: number = parseInt(color.substring(5, 7), 16) / 255;
      return r.toFixed(3) + ' ' + g.toFixed(3) + ' ' + b.toFixed(3) + ' rg';
    }
    return '0 0 0 rg';
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
      this.writeAscii('<< /Type /Font /Subtype /Type0 /BaseFont /' + BASE_FONT +
        ' /Encoding /Identity-H /DescendantFonts [' + cidFontId.toString() + ' 0 R]' +
        ' /ToUnicode ' + toUnicodeId.toString() + ' 0 R >>\nendobj\n');
      // /W 字宽表：缺了它阅读器统一按 /DW=1000 排版，数字/标点会被当成全角，间距明显过宽
      const gidList: number[] = [];
      this.usedGids.forEach((code: number, gid: number): void => {
        gidList.push(gid);
      });
      gidList.sort((a: number, b: number): number => a - b);
      let widths: string = '[';
      for (let i: number = 0; i < gidList.length; i = i + 1) {
        const gid: number = gidList[i];
        widths = widths + gid.toString() + ' [' + f.advance1000(gid).toString() + '] ';
      }
      widths = widths + ']';

      this.beginObj(cidFontId);
      this.writeAscii('<< /Type /Font /Subtype /CIDFontType2 /BaseFont /' + BASE_FONT +
        ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>' +
        ' /FontDescriptor ' + descId.toString() + ' 0 R /CIDToGIDMap /Identity /DW 1000' +
        ' /W ' + widths + ' >>\nendobj\n');
      this.beginObj(descId);
      this.writeAscii('<< /Type /FontDescriptor /FontName /' + BASE_FONT + ' /Flags 4' +
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
          cmap = cmap + '<' + RawPdfWriter.hex4(gid) + '> <' +
            RawPdfWriter.utf16HexCodePoint(code) + '>\n';
        }
        cmap = cmap + 'endbfchar\n';
      }
      cmap = cmap + 'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n';
      this.beginObj(toUnicodeId);
      this.writeAscii('<< /Length ' + cmap.length.toString() + ' >>\nstream\n' + cmap +
        'endstream\nendobj\n');

      // FontFile2：子集 TTF 字节
      // 子集化：只保留本卷用到的字形（GID 不变），20.6MB 字体通常裁剪到几百 KB；
      // cmap/post/checkSumAdjustment 由 RawPdfFont 按 OpenType 规范一并补齐；
      // 字体流用标准 FlateDecode（zlib）压缩：loca 的重复 4 字节偏移、hmtx 的零槽位、glyf 轮廓都能显著缩小
      const fontBytes: Uint8Array = f.subsetBytes(this.usedGids);
      const packed: Uint8Array = RawPdfWriter.flateEncode(fontBytes);
      this.beginObj(fontFileId);
      if (packed.length < fontBytes.length) {
        this.writeAscii('<< /Length ' + packed.length.toString() + ' /Length1 ' +
          fontBytes.length.toString() + ' /Filter /FlateDecode >>\nstream\n');
        fileIo.writeSync(this.fdOrThrow().fd, packed.buffer);
        this.offset += packed.length;
      } else {
        this.writeAscii('<< /Length ' + fontBytes.length.toString() + ' /Length1 ' +
          fontBytes.length.toString() + ' >>\nstream\n');
        fileIo.writeSync(this.fdOrThrow().fd, fontBytes.buffer);
        this.offset += fontBytes.length;
      }
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
          cmap = cmap + '<' + hex + '> <' + RawPdfWriter.utf16HexCodePoint(codes[k]) + '>\n';
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

    // Outlines（书签）：每页一条，点击跳转到对应页
    let outlineRootId: number = 0;
    if (this.bookmarks.length > 0) {
      const n: number = this.bookmarks.length;
      outlineRootId = this.nextObj;
      const firstItemId: number = outlineRootId + 1;
      const lastItemId: number = firstItemId + n - 1;
      this.nextObj = this.nextObj + 1 + n;

      this.beginObj(outlineRootId);
      this.writeAscii('<< /Type /Outlines /First ' + firstItemId.toString() + ' 0 R /Last ' +
        lastItemId.toString() + ' 0 R /Count ' + n.toString() + ' >>\nendobj\n');
      for (let i: number = 0; i < n; i = i + 1) {
        const bm: PdfBookmark = this.bookmarks[i];
        const id: number = firstItemId + i;
        let s: string = '<< /Title <FEFF' + RawPdfWriter.utf16Hex(bm.title) + '>';
        s = s + ' /Parent ' + outlineRootId.toString() + ' 0 R';
        if (i > 0) {
          s = s + ' /Prev ' + (id - 1).toString() + ' 0 R';
        }
        if (i < n - 1) {
          s = s + ' /Next ' + (id + 1).toString() + ' 0 R';
        }
        s = s + ' /Dest [' + bm.pageId.toString() + ' 0 R /XYZ 0 ' +
          this.pageH.toString() + ' null] >>\nendobj\n';
        this.beginObj(id);
        this.writeAscii(s);
      }
    }

    // Info（文档元数据）
    let infoId: number = 0;
    if (this.info !== null) {
      infoId = this.nextObj;
      this.nextObj = this.nextObj + 1;
      const info: PdfInfo = this.info;
      let s: string = '<<';
      if (info.title.length > 0) {
        s = s + ' /Title <FEFF' + RawPdfWriter.utf16Hex(ScriptService.getInstance().toDisplay(info.title)) + '>';
      }
      if (info.author.length > 0) {
        s = s + ' /Author <FEFF' + RawPdfWriter.utf16Hex(ScriptService.getInstance().toDisplay(info.author)) + '>';
      }
      if (info.subject.length > 0) {
        s = s + ' /Subject <FEFF' + RawPdfWriter.utf16Hex(ScriptService.getInstance().toDisplay(info.subject)) + '>';
      }
      if (info.creator.length > 0) {
        s = s + ' /Creator <FEFF' + RawPdfWriter.utf16Hex(ScriptService.getInstance().toDisplay(info.creator)) + '>';
      }
      if (info.producer.length > 0) {
        s = s + ' /Producer <FEFF' + RawPdfWriter.utf16Hex(ScriptService.getInstance().toDisplay(info.producer)) + '>';
      }
      const when: string = pdfDate();
      s = s + ' /CreationDate (' + when + ') /ModDate (' + when + ') >>\nendobj\n';
      this.beginObj(infoId);
      this.writeAscii(s);
    }

    // Catalog：有书签时挂 Outlines，并默认展开书签面板
    this.beginObj(OBJ_CATALOG);
    let catalog: string = '<< /Type /Catalog /Pages ' + OBJ_PAGES.toString() + ' 0 R';
    if (outlineRootId > 0) {
      catalog = catalog + ' /Outlines ' + outlineRootId.toString() + ' 0 R /PageMode /UseOutlines';
    }
    catalog = catalog + ' >>\nendobj\n';
    this.writeAscii(catalog);

    const xrefStart: number = this.offset;
    const totalObj: number = this.nextObj;
    this.writeAscii('xref\n0 ' + totalObj.toString() + '\n');
    this.writeAscii('0000000000 65535 f \n');
    for (let i: number = 1; i < totalObj; i = i + 1) {
      const off: number = this.offsets.length > i ? this.offsets[i] : 0;
      this.writeAscii(RawPdfWriter.pad10(off) + ' 00000 n \n');
    }
    let trailer: string = 'trailer\n<< /Size ' + totalObj.toString() + ' /Root ' +
      OBJ_CATALOG.toString() + ' 0 R';
    if (infoId > 0) {
      trailer = trailer + ' /Info ' + infoId.toString() + ' 0 R';
    }
    trailer = trailer + ' >>\nstartxref\n' + xrefStart.toString() + '\n%%EOF\n';
    this.writeAscii(trailer);
    if (this.missingChars.size > 0) {
      console.warn('[Pdf] font missing glyphs=' + this.missingChars.size.toString() +
        ', sample=' + this.missingSample());
    }
    if (this.fd !== null) {
      fileIo.closeSync(this.fd);
      this.fd = null;
    }
  }

  /** 文本编码：嵌入字体时用 GID，回退时用 UTF-16BE */
  private textHex(s: string): string {
    // 展示/导出按设置页简繁转换；缺字统计针对转换后的最终字形
    const text: string = ScriptService.getInstance().toDisplay(s);
    if (this.font === null) {
      return RawPdfWriter.utf16Hex(text);
    }
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      // 按 Unicode 码点遍历：CJK Ext-B 等非 BMP 字符是代理对，不能拆成两个码元查表
      const code: number = s.codePointAt(i) ?? 0;
      const gid: number = this.font.gidOf(code);
      if (gid > 0) {
        this.usedGids.set(gid, code);
      } else if (!RawPdfWriter.isBlankCode(code)) {
        this.missingChars.add(code);
      }
      out = out + RawPdfWriter.hex4(gid);
      i = i + (code > 0xffff ? 2 : 1);
    }
    return out;
  }

  /** 字体未覆盖的字符数 */
  missingCount(): number {
    return this.missingChars.size;
  }

  /** 缺字样例，形如 U+20BB7 U+9FEA，便于日志定位 */
  missingSample(limit: number = 12): string {
    const arr: number[] = [];
    this.missingChars.forEach((c: number): void => {
      if (arr.length < limit) {
        arr.push(c);
      }
    });
    let out: string = '';
    for (let i: number = 0; i < arr.length; i = i + 1) {
      out = out + (i > 0 ? ' ' : '') + 'U+' + arr[i].toString(16).toUpperCase();
    }
    return out;
  }

  private static isBlankCode(code: number): boolean {
    return code === 0x20 || code === 0x09 || code === 0x0a || code === 0x0d ||
      code === 0x00a0 || code === 0x3000;
  }

  /** 文本转 UTF-16BE 十六进制（UniGB-UCS2-H 编码，非 BMP 用代理对） */
  private static utf16Hex(s: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      const code: number = s.codePointAt(i) ?? 0;
      out = out + RawPdfWriter.utf16HexCodePoint(code);
      i = i + (code > 0xffff ? 2 : 1);
    }
    return out;
  }

  /** 单个码点 → UTF-16BE 十六进制（ToUnicode 目标值） */
  private static utf16HexCodePoint(code: number): string {
    if (code <= 0xffff) {
      return RawPdfWriter.hex4(code);
    }
    const v: number = code - 0x10000;
    return RawPdfWriter.hex4(0xd800 + (v >> 10)) + RawPdfWriter.hex4(0xdc00 + (v & 0x3ff));
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

  /**
   * Deflate 压缩（RFC 1951 固定 Huffman + LZ77），输出 zlib 包装流（RFC 1950），
   * 供 PDF 的 `/Filter /FlateDecode` 使用。
   *
   * 只做固定 Huffman：码表内置、无需动态码表，足以把子集字体的 loca 重复偏移、
   * hmtx 零槽位与 glyf 轮廓压到原体积的 10%~20%，且实现可完全离线验证。
   */
  private static flateEncode(data: Uint8Array): Uint8Array {
    // 固定 Huffman 码长：0-143→8, 144-255→9, 256-279→7, 280-287→8
    const lens: number[] = [];
    for (let i: number = 0; i < 288; i = i + 1) {
      if (i < 144) {
        lens.push(8);
      } else if (i < 256) {
        lens.push(9);
      } else if (i < 280) {
        lens.push(7);
      } else {
        lens.push(8);
      }
    }
    const blCount: number[] = [];
    for (let i: number = 0; i < 16; i = i + 1) {
      blCount.push(0);
    }
    for (let i: number = 0; i < 288; i = i + 1) {
      blCount[lens[i]] = blCount[lens[i]] + 1;
    }
    const nextCode: number[] = [];
    for (let i: number = 0; i < 16; i = i + 1) {
      nextCode.push(0);
    }
    let code: number = 0;
    for (let bits: number = 1; bits < 16; bits = bits + 1) {
      code = (code + blCount[bits - 1]) << 1;
      nextCode[bits] = code;
    }
    // 写入需要反向位序（Huffman 码 MSB 在前，bit 流 LSB 在前）
    const revCodes: number[] = [];
    for (let i: number = 0; i < 288; i = i + 1) {
      const len: number = lens[i];
      const c: number = nextCode[len];
      nextCode[len] = c + 1;
      revCodes.push(RawPdfWriter.reverseBits(c, len));
    }
    const distRev: number[] = [];
    for (let i: number = 0; i < 32; i = i + 1) {
      distRev.push(RawPdfWriter.reverseBits(i, 5));
    }

    // zlib 头：0x78 0x9C（默认压缩级别）
    const out: number[] = [0x78, 0x9C];
    let cur: number = 0;
    let curBits: number = 0;
    const writeBits = (value: number, count: number): void => {
      for (let i: number = 0; i < count; i = i + 1) {
        cur = cur | (((value >>> i) & 1) << curBits);
        curBits = curBits + 1;
        if (curBits === 8) {
          out.push(cur);
          cur = 0;
          curBits = 0;
        }
      }
    };

    // 单块：BFINAL=1，BTYPE=01（固定 Huffman）
    writeBits(3, 3);

    const n: number = data.length;
    const head: Int32Array = new Int32Array(65536);
    for (let i: number = 0; i < 65536; i = i + 1) {
      head[i] = -1;
    }
    const prev: Int32Array = new Int32Array(n);
    for (let i: number = 0; i < n; i = i + 1) {
      prev[i] = -1;
    }
    const hashAt = (pos: number): number => {
      return ((data[pos] << 10) ^ (data[pos + 1] << 5) ^ data[pos + 2]) & 0xffff;
    };
    const insert = (pos: number): void => {
      if (pos + 2 >= n) {
        return;
      }
      const h: number = hashAt(pos);
      prev[pos] = head[h];
      head[h] = pos;
    };

    let i: number = 0;
    while (i < n) {
      let bestLen: number = 0;
      let bestDist: number = 0;
      if (i + 2 < n) {
        let cand: number = head[hashAt(i)];
        let chain: number = 0;
        const maxLen: number = Math.min(258, n - i);
        while (cand >= 0 && i - cand <= 32768 && chain < 24) {
          let l: number = 0;
          while (l < maxLen && data[cand + l] === data[i + l]) {
            l = l + 1;
          }
          if (l > bestLen) {
            bestLen = l;
            bestDist = i - cand;
            if (l === maxLen) {
              break;
            }
          }
          cand = prev[cand];
          chain = chain + 1;
        }
      }
      if (bestLen >= 3) {
        let k: number = 28;
        while (k > 0 && LEN_BASE[k] > bestLen) {
          k = k - 1;
        }
        writeBits(revCodes[257 + k], lens[257 + k]);
        if (LEN_EXTRA[k] > 0) {
          writeBits(bestLen - LEN_BASE[k], LEN_EXTRA[k]);
        }
        let d: number = 29;
        while (d > 0 && DIST_BASE[d] > bestDist) {
          d = d - 1;
        }
        writeBits(distRev[d], 5);
        if (DIST_EXTRA[d] > 0) {
          writeBits(bestDist - DIST_BASE[d], DIST_EXTRA[d]);
        }
        for (let k2: number = 0; k2 < bestLen; k2 = k2 + 1) {
          insert(i + k2);
        }
        i = i + bestLen;
      } else {
        writeBits(revCodes[data[i]], lens[data[i]]);
        insert(i);
        i = i + 1;
      }
    }
    // 块结束符 EOB
    writeBits(revCodes[256], lens[256]);
    if (curBits > 0) {
      out.push(cur);
    }

    // adler32（大端）
    let a: number = 1;
    let b: number = 0;
    for (let i2: number = 0; i2 < n; i2 = i2 + 1) {
      a = (a + data[i2]) % 65521;
      b = (b + a) % 65521;
    }
    const adler: number = ((b << 16) | a) >>> 0;
    out.push((adler >>> 24) & 0xff);
    out.push((adler >>> 16) & 0xff);
    out.push((adler >>> 8) & 0xff);
    out.push(adler & 0xff);

    const packed: Uint8Array = new Uint8Array(out.length);
    for (let k3: number = 0; k3 < out.length; k3 = k3 + 1) {
      packed[k3] = out[k3];
    }
    return packed;
  }

  private static reverseBits(value: number, count: number): number {
    let out: number = 0;
    for (let i: number = 0; i < count; i = i + 1) {
      out = (out << 1) | ((value >>> i) & 1);
    }
    return out;
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