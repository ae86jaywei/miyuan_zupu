import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

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

  constructor(path: string, pageW: number, pageH: number, imageW: number, imageH: number) {
    this.pageW = pageW;
    this.pageH = pageH;
    this.imageW = imageW;
    this.imageH = imageH;
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
  addJpegPage(jpegPath: string, footerText: string): void {
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

    // Content：整页铺图 + 可选 ASCII 页码
    let content: string = 'q\n' + this.pageW.toString() + ' 0 0 ' + this.pageH.toString() +
      ' 0 0 cm\n/Im0 Do\nQ\n';
    if (footerText.length > 0) {
      content = content + 'BT /F1 9 Tf 24 18 Td (' + RawPdfWriter.escape(footerText) + ') Tj ET\n';
    }
    this.beginObj(contentId);
    this.writeAscii('<< /Length ' + content.length.toString() + ' >>\nstream\n' + content +
      'endstream\nendobj\n');

    this.pageIds.push(pageId);
  }

  /** 完成文档：写 Pages / Catalog / Font / xref / trailer */
  finish(): void {
    // Font（标准 Helvetica，仅用于 ASCII 页码）
    this.beginObj(OBJ_FONT);
    this.writeAscii('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n');

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