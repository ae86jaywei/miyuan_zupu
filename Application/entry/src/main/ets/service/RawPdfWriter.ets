import { fileIo } from '@kit.CoreFileKit';
import { RawPdfFont } from './RawPdfFont';

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
const BASE_FONT: string = SUBSET_TAG + 'HarmonyOS-Sans';

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
      this.bookmarks.push(new PdfBookmark(bookmarkTitle, pageId));
    }
  }

  /** 追加一页纯文本（牒记式）：无图片，文字矢量写入，可搜索/复制 */
  addTextLinePage(lines: PdfTextLine[], bookmarkTitle: string = ''): void {
    const pageId: number = this.nextObj;
    const contentId: number = this.nextObj + 1;
    this.nextObj = this.nextObj + 2;

    this.beginObj(pageId);
    this.writeAscii('<< /Type /Page /Parent ' + OBJ_PAGES.toString() + ' 0 R /MediaBox [0 0 ' +
      this.pageW.toString() + ' ' + this.pageH.toString() + '] /Resources << /Font << /F1 ' +
      OBJ_FONT.toString() + ' 0 R >> >> /Contents ' + contentId.toString() + ' 0 R >>\nendobj\n');

    let content: string = 'q\n0.98 0.97 0.94 rg\n0 0 ' + this.pageW.toString() + ' ' +
      this.pageH.toString() + ' re\nf\nQ\n';
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
      this.bookmarks.push(new PdfBookmark(bookmarkTitle, pageId));
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
          cmap = cmap + '<' + RawPdfWriter.hex4(gid) + '> <' + RawPdfWriter.hex4(code) + '>\n';
        }
        cmap = cmap + 'endbfchar\n';
      }
      cmap = cmap + 'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n';
      this.beginObj(toUnicodeId);
      this.writeAscii('<< /Length ' + cmap.length.toString() + ' >>\nstream\n' + cmap +
        'endstream\nendobj\n');

      // FontFile2：子集 TTF 字节
      // 子集化：只保留本卷用到的字形（GID 不变），20.6MB 字体通常裁剪到几百 KB；
      // cmap/post/checkSumAdjustment 由 RawPdfFont 按 OpenType 规范一并补齐
      const fontBytes: Uint8Array = f.subsetBytes(this.usedGids);
      this.beginObj(fontFileId);
      this.writeAscii('<< /Length ' + fontBytes.length.toString() + ' /Length1 ' +
        fontBytes.length.toString() + ' >>\nstream\n');
      fileIo.writeSync(this.fdOrThrow().fd, fontBytes.buffer);
      this.offset += fontBytes.length;
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
        s = s + ' /Title <FEFF' + RawPdfWriter.utf16Hex(info.title) + '>';
      }
      if (info.author.length > 0) {
        s = s + ' /Author <FEFF' + RawPdfWriter.utf16Hex(info.author) + '>';
      }
      if (info.subject.length > 0) {
        s = s + ' /Subject <FEFF' + RawPdfWriter.utf16Hex(info.subject) + '>';
      }
      if (info.creator.length > 0) {
        s = s + ' /Creator <FEFF' + RawPdfWriter.utf16Hex(info.creator) + '>';
      }
      if (info.producer.length > 0) {
        s = s + ' /Producer <FEFF' + RawPdfWriter.utf16Hex(info.producer) + '>';
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
    if (this.fd !== null) {
      fileIo.closeSync(this.fd);
      this.fd = null;
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