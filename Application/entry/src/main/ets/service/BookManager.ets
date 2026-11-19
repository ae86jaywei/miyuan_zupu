import { relationalStore } from '@kit.ArkData';
import { Genealogy, createEmptyGenealogy } from 'common_base';
import { TABLE_BOOK, TABLE_META, TABLE_PERSON, TABLE_SPOUSE } from './db/DatabaseSchema';
import { PersonRowMapper } from './db/PersonRowMapper';

/** 元数据：当前打开的族谱ID（0 表示无族谱） */
const META_CURRENT_BOOK: string = 'current_book_id';
/** 元数据前缀：某部族谱中已被删除、但编号仍需保留不再复用的族人 */
const META_RETIRED_PREFIX: string = 'retired_uids_';

/**
 * 族谱管理宿主接口：由 `GenealogyService` 实现，向管理域暴露必要的状态读写。
 * 这样族谱生命周期逻辑可以下沉，而 book / books / currentBookId 仍由服务统一持有。
 */
export interface BookHost {
  storeRef(): relationalStore.RdbStore | null;
  booksRef(): Genealogy[];
  currentBookIdValue(): number;
  currentBookValue(): Genealogy;
  setCurrentBookId(id: number): void;
  setCurrentBook(book: Genealogy): void;
  syncBookInList(book: Genealogy): void;
  setMetaValue(key: string, value: string): Promise<void>;
  reloadData(): Promise<void>;
  bumpVersion(): void;
  ensureCurrentBook(): Promise<void>;
  applyBookFamilyState(): void;
}

/**
 * 族谱管理域：族谱的保存、新建、切换与删除。
 *
 * 从 `GenealogyService` 拆出；数据库写入与元数据更新在此完成，
 * 状态字段仍由宿主持有，避免多处直接改写。
 */
export class BookManager {
  private host: BookHost;

  constructor(host: BookHost) {
    this.host = host;
  }

  /** 保存族谱元信息（新建或更新），并同步到族谱列表 */
  async saveBook(book: Genealogy): Promise<void> {
    const store: relationalStore.RdbStore | null = this.host.storeRef();
    if (store === null) {
      return;
    }
    book.updatedAt = Date.now();
    if (book.key > 0) {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_BOOK);
      predicates.equalTo('id', book.key);
      await store.update(PersonRowMapper.bookValues(book), predicates);
    } else {
      const rowId: number = await store.insert(TABLE_BOOK, PersonRowMapper.bookValues(book));
      book.key = rowId;
    }
    this.host.setCurrentBook(book);
    // 同步族谱列表中的对应项，供切换入口实时展示
    this.host.syncBookInList(book);
    this.host.bumpVersion();
    // 切换/保存族谱后同步协作态（familyId / 角色 / 同步模式）
    this.host.applyBookFamilyState();
  }

  /** 新建一部空族谱（无族人），创建后自动切换为当前族谱 */
  async createGenealogy(title: string): Promise<Genealogy> {
    const store: relationalStore.RdbStore = this.host.storeRef() as relationalStore.RdbStore;
    const book: Genealogy = createEmptyGenealogy();
    const base: string = title.trim().length > 0 ? title.trim() : '我的族谱';
    // 多族谱下自动去重命名，避免出现多个同名族谱难以区分
    let name: string = base;
    let serial: number = 2;
    while (this.hasBookTitle(name)) {
      name = base + ' ' + serial.toString();
      serial++;
    }
    book.title = name;
    const rowId: number = await store.insert(TABLE_BOOK, PersonRowMapper.bookValues(book));
    book.key = rowId;
    this.host.setCurrentBookId(rowId);
    await this.host.setMetaValue(META_CURRENT_BOOK, rowId.toString());
    await this.host.reloadData();
    return this.host.currentBookValue();
  }

  /** 是否已存在同名族谱 */
  private hasBookTitle(title: string): boolean {
    const books: Genealogy[] = this.host.booksRef();
    for (let i: number = 0; i < books.length; i++) {
      if (books[i].title === title) {
        return true;
      }
    }
    return false;
  }

  /** 切换当前族谱，其他页面会跟随刷新 */
  async switchGenealogy(bookId: number): Promise<void> {
    if (bookId <= 0 || bookId === this.host.currentBookIdValue()) {
      return;
    }
    if (AppStorage.get<boolean>('gpCloudBusy') === true) {
      throw new Error('云发布或同步进行中，请完成后再切换族谱');
    }
    let exists: boolean = false;
    const books: Genealogy[] = this.host.booksRef();
    for (let i: number = 0; i < books.length; i++) {
      if (books[i].key === bookId) {
        exists = true;
        break;
      }
    }
    if (!exists) {
      return;
    }
    AppStorage.setOrCreate<boolean>('gpCloudBusy', true);
    try {
      this.host.setCurrentBookId(bookId);
      await this.host.setMetaValue(META_CURRENT_BOOK, bookId.toString());
      await this.host.reloadData();
    } finally {
      AppStorage.setOrCreate<boolean>('gpCloudBusy', false);
    }
  }

  /**
   * 删除指定族谱（含该族谱的族人、配偶关系与元信息）。
   * 若删除的是当前族谱，自动切换到剩余族谱；全部删除后进入“无族谱”状态。
   */
  async deleteGenealogy(bookId: number = 0): Promise<void> {
    const store: relationalStore.RdbStore | null = this.host.storeRef();
    if (store === null) {
      return;
    }
    const target: number = bookId > 0 ? bookId : this.host.currentBookIdValue();
    if (target <= 0) {
      return;
    }
    await store.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [target]);
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [target]);
    await store.executeSql(`DELETE FROM ${TABLE_BOOK} WHERE id = ?`, [target]);
    await store.executeSql(`DELETE FROM ${TABLE_META} WHERE key = ?`,
      [META_RETIRED_PREFIX + target.toString()]);
    // 重新选定当前族谱：优先保留原来的，不存在则取第一部，全部删除则为 0
    await this.host.ensureCurrentBook();
    await this.host.setMetaValue(META_CURRENT_BOOK, this.host.currentBookIdValue().toString());
    await this.host.reloadData();
  }
}
