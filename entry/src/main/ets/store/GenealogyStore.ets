import { GenealogyService } from '../service/GenealogyService';
import { GenealogyScope } from '../model/Scope';

/**
 * 全局数据仓库（AppStorage 驱动）。
 *
 * 注意：统一使用 createIfAbsent + set 的写法。
 * setOrCreate(key, value) 在 key 已存在时等价于 set，若 value 为 undefined 会把
 * 已订阅的 @StorageProp 置空并丢失刷新，故这里显式分离“创建”与“赋值”。
 */
export class GenealogyStore {
  static readonly KEY_VERSION: string = 'gpVersion';
  static readonly KEY_READY: string = 'gpReady';
  static readonly KEY_PEOPLE: string = 'gpPeopleCount';
  static readonly KEY_STYLE: string = 'gpStyle';
  /** 是否已有族谱（删除族谱后为 false） */
  static readonly KEY_HAS_BOOK: string = 'gpHasBook';
  /** 当前族谱ID（0 表示无族谱） */
  static readonly KEY_BOOK_ID: string = 'gpBookId';
  /** 当前族谱名称 */
  static readonly KEY_BOOK_TITLE: string = 'gpBookTitle';
  /** 族谱总数 */
  static readonly KEY_BOOK_COUNT: string = 'gpBookCount';
  /** 待打开的族谱编辑态（新增族谱后置为 true，设置页读取后自动进入编辑） */
  static readonly KEY_EDITING_BOOK: string = 'gpEditingBook';

  private static put<T>(key: string, value: T): void {
    AppStorage.setOrCreate<T>(key, value);
    if (value !== undefined) {
      AppStorage.set<T>(key, value);
    }
  }

  /** 初始化（在 UI 启动时调用一次） */
  static async bootstrap(): Promise<void> {
    const svc: GenealogyService = GenealogyService.getInstance();
    await svc.init(GenealogyScope.context());
    GenealogyStore.put<number>(GenealogyStore.KEY_VERSION, svc.getVersion());
    GenealogyStore.put<number>(GenealogyStore.KEY_PEOPLE, svc.getPeople().length);
    GenealogyStore.put<boolean>(GenealogyStore.KEY_HAS_BOOK, svc.hasBook());
    GenealogyStore.syncBooks(svc);
    GenealogyStore.put<boolean>(GenealogyStore.KEY_READY, true);
    if (AppStorage.get<string>(GenealogyStore.KEY_STYLE) === undefined) {
      GenealogyStore.put<string>(GenealogyStore.KEY_STYLE, 'eu');
    }
  }

  /** 通知界面数据已变化 */
  static notifyChanged(): void {
    const svc: GenealogyService = GenealogyService.getInstance();
    GenealogyStore.put<number>(GenealogyStore.KEY_VERSION, svc.getVersion());
    GenealogyStore.put<number>(GenealogyStore.KEY_PEOPLE, svc.getPeople().length);
    GenealogyStore.put<boolean>(GenealogyStore.KEY_HAS_BOOK, svc.hasBook());
    GenealogyStore.syncBooks(svc);
  }

  /** 同步当前族谱信息（多族谱切换入口使用） */
  private static syncBooks(svc: GenealogyService): void {
    GenealogyStore.put<number>(GenealogyStore.KEY_BOOK_ID, svc.getCurrentBookId());
    GenealogyStore.put<string>(GenealogyStore.KEY_BOOK_TITLE, svc.getBook().title);
    GenealogyStore.put<number>(GenealogyStore.KEY_BOOK_COUNT, svc.getBooks().length);
  }

  static version(): number {
    const v: number | undefined = AppStorage.get<number>(GenealogyStore.KEY_VERSION);
    return v === undefined ? 0 : v;
  }

  static setStyle(style: string): void {
    GenealogyStore.put<string>(GenealogyStore.KEY_STYLE, style);
  }

  static style(): string {
    const s: string | undefined = AppStorage.get<string>(GenealogyStore.KEY_STYLE);
    return s === undefined ? 'eu' : s;
  }
}
