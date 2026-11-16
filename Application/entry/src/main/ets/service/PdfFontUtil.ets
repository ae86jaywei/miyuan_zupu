import { fileIo } from '@kit.CoreFileKit';
import { Font } from '@kit.ArkUI';
import { RawPdfFont } from './RawPdfFont';

/**
 * 中文字体定位（F3）。
 *
 * 关键坑：HarmonyOS_Sans.ttf 只有 342KB、不含 CJK 字形，
 * 若按族名命中它，整卷中文都会被映射成 GID 0（.notdef），导出的谱文“只有数字/标点、没有一个汉字”。
 * 因此这里只接受 >1MB 且能被 RawPdfFont 成功解析（有 cmap format 4/12）的字体，
 * 族名全部失败时直接读系统字体路径兜底。
 */
export class PdfFontUtil {
  /** 系统 CJK 字体兜底路径（只读，应用沙箱可访问） */
  private static FALLBACK: string = '/system/fonts/HarmonyOS_Sans_SC.ttf';
  private static path: string = '';
  private static resolved: boolean = false;
  private static cached: RawPdfFont | null = null;

  /** 中文字体文件路径；为空表示没有可用的 CJK 字体 */
  static fontPath(): string {
    PdfFontUtil.ensureResolved();
    return PdfFontUtil.path;
  }

  /** 已解析字体，跨卷复用：20.6MB 字体每卷重读 + 重解析 cmap 会把导出拖慢数倍 */
  static rawFont(): RawPdfFont | null {
    PdfFontUtil.ensureResolved();
    return PdfFontUtil.cached;
  }

  private static ensureResolved(): void {
    if (PdfFontUtil.resolved) {
      return;
    }
    PdfFontUtil.resolved = true;
    const tried: string[] = [];
    // 优先系统固定路径：命中就不必逐个族名查询，省掉首导几十毫秒的字体配置解析，
    // 也避免 Text 模块打出一批 “Failed to find font name HarmonyOS_Sans_SC/TC” 错误日志。
    if (PdfFontUtil.hasCjk(PdfFontUtil.FALLBACK)) {
      const direct: RawPdfFont | null = RawPdfFont.load(PdfFontUtil.FALLBACK);
      tried.push(PdfFontUtil.FALLBACK);
      if (direct !== null) {
        PdfFontUtil.path = PdfFontUtil.FALLBACK;
        PdfFontUtil.cached = direct;
        console.info('[PdfFont] embed=' + PdfFontUtil.FALLBACK);
        return;
      }
    }
    // 固定路径不存在或不可解析时，再按族名探测（不同机型/系统版本的路径可能不同）
    const candidates: string[] = [];
    const names: string[] = ['HarmonyOS Sans SC', 'HarmonyOS_Sans_SC', 'HarmonyOS Sans TC',
      'HarmonyOS_Sans_TC', 'HarmonyOS Sans'];
    for (let i: number = 0; i < names.length; i = i + 1) {
      try {
        const f: Font = new Font();
        const info = f.getFontByName(names[i]);
        const p: string = info.path ?? '';
        if (p.length > 0 && candidates.indexOf(p) < 0) {
          candidates.push(p);
        }
      } catch (_e) {
        // 换下一个族名
      }
    }
    if (candidates.indexOf(PdfFontUtil.FALLBACK) < 0) {
      candidates.push(PdfFontUtil.FALLBACK);
    }
    for (let i: number = 0; i < candidates.length; i = i + 1) {
      const p: string = candidates[i];
      if (tried.indexOf(p) >= 0 || !PdfFontUtil.hasCjk(p)) {
        continue;
      }
      const f: RawPdfFont | null = RawPdfFont.load(p);
      if (f !== null) {
        PdfFontUtil.path = p;
        PdfFontUtil.cached = f;
        console.info('[PdfFont] embed=' + p);
        return;
      }
    }
    console.info('[PdfFont] no usable CJK font, fallback STSong-Light');
  }

  /** 是否含 CJK 字形（用文件大小判断：拉丁字体只有几百 KB） */
  private static hasCjk(p: string): boolean {
    if (p.length === 0) {
      return false;
    }
    try {
      return fileIo.statSync(p).size > 1024 * 1024;
    } catch (_e) {
      return false;
    }
  }
}