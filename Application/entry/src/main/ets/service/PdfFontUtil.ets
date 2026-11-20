import { fileIo } from '@kit.CoreFileKit';
import { Font } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { RawPdfFont } from './RawPdfFont';

/**
 * 中文字体定位（F3）。
 *
 * 优先使用打包在 rawfile 里的开源大字库（BabelStone Han，覆盖简繁、CJK Ext-A/D/I
 * 与 Ext-B/C/E/F/G/H 的部分生僻字）；内置字体不可用时再回退系统字体。
 * 系统字体全是 HarmonyOS Sans SC，生僻字覆盖有限，且不同 ROM 路径可能不同。
 *
 * 关键坑：HarmonyOS_Sans.ttf 只有 342KB、不含 CJK 字形，
 * 若按族名命中它，整卷中文都会被映射成 GID 0（.notdef），导出的谱文“只有数字/标点、没有一个汉字”。
 * 因此这里只接受能成功解析且通过常用汉字覆盖校验的字体。
 */
export class PdfFontUtil {
  /** 内置大字库在 rawfile 中的路径 */
  private static readonly BUILTIN: string = 'fonts/BabelStoneHan.ttf';
  /** 系统 CJK 字体兜底路径（只读，应用沙箱可访问） */
  private static FALLBACK: string = '/system/fonts/HarmonyOS_Sans_SC.ttf';
  private static context: common.Context | null = null;
  private static path: string = '';
  private static label: string = '';
  private static builtin: boolean = false;
  private static resolved: boolean = false;
  private static cached: RawPdfFont | null = null;

  /** EntryAbility 启动时注入 context；之后首次导出才会真正读取 52MB 字体 */
  static init(context: common.Context): void {
    PdfFontUtil.context = context;
    // init 前可能已探测失败，重新允许探测
    PdfFontUtil.resolved = false;
  }

  /** 中文字体文件路径/内置标识；为空表示没有可用的 CJK 字体 */
  static fontPath(): string {
    PdfFontUtil.ensureResolved();
    return PdfFontUtil.path;
  }

  /** 字体展示名（日志用） */
  static fontLabel(): string {
    PdfFontUtil.ensureResolved();
    return PdfFontUtil.label;
  }

  /** 是否使用内置字体 */
  static isBuiltin(): boolean {
    PdfFontUtil.ensureResolved();
    return PdfFontUtil.builtin;
  }

  /** 已解析字体，跨卷复用：大字体每卷重读 + 重解析 cmap 会把导出拖慢数倍 */
  static rawFont(): RawPdfFont | null {
    PdfFontUtil.ensureResolved();
    return PdfFontUtil.cached;
  }

  private static ensureResolved(): void {
    if (PdfFontUtil.resolved) {
      return;
    }
    // 1. 内置大字库：简繁 + 生僻字，离线可用
    if (PdfFontUtil.context !== null) {
      try {
        const data: Uint8Array =
          PdfFontUtil.context.resourceManager.getRawFileContentSync(PdfFontUtil.BUILTIN);
        const f: RawPdfFont | null = RawPdfFont.loadBytes(data, 0);
        if (f !== null && f.hasCjkCoverage()) {
          PdfFontUtil.path = PdfFontUtil.BUILTIN;
          PdfFontUtil.label = 'BabelStone Han (builtin)';
          PdfFontUtil.builtin = true;
          PdfFontUtil.cached = f;
          PdfFontUtil.resolved = true;
          return;
        }
      } catch (e) {
      }
    }
    // 2. 系统字体兜底
    const tried: string[] = [];
    if (PdfFontUtil.hasCjk(PdfFontUtil.FALLBACK)) {
      const direct: RawPdfFont | null = RawPdfFont.load(PdfFontUtil.FALLBACK);
      tried.push(PdfFontUtil.FALLBACK);
      if (direct !== null) {
        PdfFontUtil.path = PdfFontUtil.FALLBACK;
        PdfFontUtil.label = 'HarmonyOS Sans SC (system)';
        PdfFontUtil.builtin = false;
        PdfFontUtil.cached = direct;
        PdfFontUtil.resolved = true;
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
        PdfFontUtil.label = 'system ' + p;
        PdfFontUtil.builtin = false;
        PdfFontUtil.cached = f;
        PdfFontUtil.resolved = true;
        return;
      }
    }
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