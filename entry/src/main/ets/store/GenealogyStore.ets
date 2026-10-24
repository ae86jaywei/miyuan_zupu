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
