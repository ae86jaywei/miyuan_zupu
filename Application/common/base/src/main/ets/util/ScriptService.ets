import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = '[Genealogy][Script]';

/**
 * 简繁文字服务。
 *
 * 数据库始终保存原文，本服务只在展示/导出时做转换，避免破坏导入表头匹配、
 * 配偶称谓等既有字符串契约。
 *
 * 词典来自 OpenCC（s2t 42k 条 / t2s 3.5k 条），打包在 rawfile/i18n，
 * 启动时同步读入内存，按最长词优先匹配。
 */
export class ScriptService {
  static readonly HANS: string = 'hans';
  static readonly HANT: string = 'hant';
  static readonly APP_KEY: string = 'gpScript';
  private static PREF_NAME: string = 'zupu_locale';
  private static PREF_FIELD: string = 'script';
  private static instance: ScriptService | null = null;

  private prefs: preferences.Preferences | null = null;
  private script: string = ScriptService.HANS;
  private s2t: Map<string, string> = new Map<string, string>();
  private t2s: Map<string, string> = new Map<string, string>();
  private maxKey: number = 1;
  private loaded: boolean = false;

  static getInstance(): ScriptService {
    if (ScriptService.instance === null) {
      ScriptService.instance = new ScriptService();
    }
    return ScriptService.instance;
  }

  /** 启动时初始化：加载词典、恢复偏好、广播到 AppStorage */
  init(context: common.Context): void {
    if (this.loaded) {
      return;
    }
    this.loadDicts(context);
    try {
      const opt: preferences.Options = { name: ScriptService.PREF_NAME };
      this.prefs = preferences.getPreferencesSync(context, opt);
      const saved: string = this.prefs.getSync(ScriptService.PREF_FIELD, ScriptService.HANS) as string;
      if (ScriptService.isValid(saved)) {
        this.script = saved;
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'prefs init failed: %{public}s', JSON.stringify(err));
    }
    this.loaded = true;
    AppStorage.setOrCreate<string>(ScriptService.APP_KEY, this.script);
    hilog.info(0x0000, TAG, 'script=%{public}s, s2t=%{public}d, t2s=%{public}d',
      this.script, this.s2t.size, this.t2s.size);
  }

  /** 当前文字：hans / hant */
  current(): string {
    return this.script;
  }

  isTraditional(): boolean {
    return this.script === ScriptService.HANT;
  }

  static isValid(v: string): boolean {
    return v === ScriptService.HANS || v === ScriptService.HANT;
  }

  /** 切换文字：立即生效并持久化；数据库不改写 */
  async setScript(mode: string): Promise<void> {
    if (!ScriptService.isValid(mode) || mode === this.script) {
      return;
    }
    this.script = mode;
    AppStorage.setOrCreate<string>(ScriptService.APP_KEY, mode);
    if (this.prefs !== null) {
      try {
        await this.prefs.put(ScriptService.PREF_FIELD, mode);
        await this.prefs.flush();
      } catch (err) {
        hilog.warn(0x0000, TAG, 'persist script failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  /** 展示/导出用转换：繁体输出走 s2t，简体输出走 t2s */
  toDisplay(text: string): string {
    if (text.length === 0) {
      return text;
    }
    return this.script === ScriptService.HANT ? this.convert(text, this.s2t)
      : this.convert(text, this.t2s);
  }

  /** 强制转繁体（导出到繁体文件时用，避免受当前界面状态影响） */
  toTraditional(text: string): string {
    return text.length === 0 ? text : this.convert(text, this.s2t);
  }

  /** 强制转简体 */
  toSimplified(text: string): string {
    return text.length === 0 ? text : this.convert(text, this.t2s);
  }

  private static isCjk(cp: number): boolean {
    // 只对汉字做词典匹配；ASCII/数字/标点在 CSV/JSON 中占比很高，直接复制能省掉大量 Map 查询
    return (cp >= 0x3400 && cp <= 0x4dbf) || (cp >= 0x4e00 && cp <= 0x9fff) ||
      (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0x20000 && cp <= 0x3134f);
  }

  private convert(text: string, dict: Map<string, string>): string {
    if (dict.size === 0) {
      return text;
    }
    let out: string = '';
    let i: number = 0;
    while (i < text.length) {
      const cp: number = text.codePointAt(i) ?? 0;
      if (!ScriptService.isCjk(cp)) {
        out = out + String.fromCodePoint(cp);
        i = i + (cp > 0xffff ? 2 : 1);
        continue;
      }
      let matched: boolean = false;
      const remain: number = text.length - i;
      const maxLen: number = Math.min(this.maxKey, remain);
      for (let len: number = maxLen; len >= 1; len = len - 1) {
        const key: string = text.substring(i, i + len);
        const val: string | undefined = dict.get(key);
        if (val !== undefined) {
          out = out + val;
          i = i + len;
          matched = true;
          break;
        }
      }
      if (!matched) {
        out = out + String.fromCodePoint(cp);
        i = i + (cp > 0xffff ? 2 : 1);
      }
    }
    return out;
  }


  private loadDicts(context: common.Context): void {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const s2tBytes: Uint8Array =
        context.resourceManager.getRawFileContentSync('i18n/s2t.txt');
      const s2tText: string = decoder.decodeToString(s2tBytes);
      const s2t: Map<string, string> = new Map<string, string>();
      let maxKey: number = 1;
      const lines: string[] = s2tText.split('\n');
      for (let i: number = 0; i < lines.length; i = i + 1) {
        // Windows 检出 rawfile 时行尾可能是 CRLF；split('\n') 会留下 '\r'，
        // 进入转换结果后会被字体渲染成方块，必须先剥掉
        const line: string = lines[i].split('\r').join('');
        const tab: number = line.indexOf('\t');
        if (tab <= 0) {
          continue;
        }
        const src: string = line.substring(0, tab);
        const dst: string = line.substring(tab + 1);
        if (src.length > 0 && dst.length > 0) {
          s2t.set(src, dst);
          if (src.length > maxKey) {
            maxKey = src.length;
          }
        }
      }
      this.s2t = s2t;
      this.maxKey = maxKey;

      const t2sBytes: Uint8Array =
        context.resourceManager.getRawFileContentSync('i18n/t2s.txt');
      const t2sText: string = decoder.decodeToString(t2sBytes);
      const t2s: Map<string, string> = new Map<string, string>();
      const t2sLines: string[] = t2sText.split('\n');
      for (let i: number = 0; i < t2sLines.length; i = i + 1) {
        const line: string = t2sLines[i].split('\r').join('');
        const tab: number = line.indexOf('\t');
        if (tab <= 0) {
          continue;
        }
        const src: string = line.substring(0, tab);
        const dst: string = line.substring(tab + 1);
        if (src.length > 0 && dst.length > 0) {
          t2s.set(src, dst);
          if (src.length > this.maxKey) {
            this.maxKey = src.length;
          }
        }
      }
      this.t2s = t2s;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'load dict failed: %{public}s', JSON.stringify(err));
    }
  }
}

/** 界面/导出文本转换快捷函数：跟随设置页当前文字 */
export function T(text: string | number | boolean | undefined | null): string {
  if (text === undefined || text === null) {
    return '';
  }
  // 数字/布尔直接转字符串，避免调用方为 Text(计数)、Text(是否) 单独包一层
  if (typeof text === 'number' || typeof text === 'boolean') {
    return String(text);
  }
  return ScriptService.getInstance().toDisplay(text);
}

/** 繁体界面统一使用内置大字库，避免系统 SC 字体缺字回退造成字体混排与字距空格 */
export const UI_FONT_HANT: string = 'MiyuanHan';
export const UI_FONT_HANS: string = 'HarmonyOS Sans SC';

/** 当前文字对应的界面字体族 */
export function uiFontFamily(): string {
  const s: string | undefined = AppStorage.get<string>(ScriptService.APP_KEY);
  return s === ScriptService.HANT ? UI_FONT_HANT : UI_FONT_HANS;
}