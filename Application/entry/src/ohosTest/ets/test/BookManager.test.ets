import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { Genealogy, createEmptyGenealogy } from 'common_base';
import { DatabaseSchema, TABLE_BOOK } from '../../../main/ets/service/db/DatabaseSchema';
import { BookManager, BookHost } from '../../../main/ets/service/BookManager';
import { openTestStore } from '../testutil/TestEnv';

const BUNDLE: string = 'com.zupu.ae86jay';
const TEST_MODULE: string = 'entry_test';
const TEST_ABILITY: string = 'TestAbility';
const DB_NAME: string = 'ohos_test_book.db';

/** 最小化 BookHost 实现：状态放在内存，DB 用真实测试库 */
class TestBookHost implements BookHost {
  store: relationalStore.RdbStore;
  book: Genealogy = createEmptyGenealogy();
  books: Genealogy[] = [];
  currentId: number = 0;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  storeRef(): relationalStore.RdbStore | null {
    return this.store;
  }

  booksRef(): Genealogy[] {
    return this.books;
  }

  currentBookIdValue(): number {
    return this.currentId;
  }

  currentBookValue(): Genealogy {
    return this.book;
  }

  setCurrentBookId(id: number): void {
    this.currentId = id;
  }

  setCurrentBook(book: Genealogy): void {
    this.book = book;
  }

  syncBookInList(book: Genealogy): void {
    for (let i: number = 0; i < this.books.length; i++) {
      if (this.books[i].key === book.key) {
        this.books[i] = book;
        return;
      }
    }
    this.books.push(book);
  }

  setMetaValue(key: string, value: string): Promise<void> {
    return Promise.resolve();
  }

  reloadData(): Promise<void> {
    return Promise.resolve();
  }

  bumpVersion(): void {
  }

  ensureCurrentBook(): Promise<void> {
    return Promise.resolve();
  }

  applyBookFamilyState(): void {
  }
}

export default function bookManagerTest() {
  describe('BookManager', () => {
    let store: relationalStore.RdbStore | null = null;
    let host: TestBookHost | null = null;
    let manager: BookManager | null = null;
    let createdId: number = 0;

    beforeAll(async () => {
      store = await openTestStore(BUNDLE, TEST_MODULE, TEST_ABILITY, DB_NAME);
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await DatabaseSchema.createTables(s);
      await s.executeSql(`DELETE FROM ${TABLE_BOOK}`);
      host = new TestBookHost(s);
      manager = new BookManager(host);
    });

    afterAll(async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await s.executeSql(`DELETE FROM ${TABLE_BOOK}`);
    });

    it('createGenealogyInsertsBookRow', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const h: TestBookHost = host as TestBookHost;
      const m: BookManager = manager as BookManager;
      await m.createGenealogy('测试谱');
      createdId = h.currentId;
      expect(createdId > 0).assertTrue();

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT title FROM ${TABLE_BOOK} WHERE id = ?`, [createdId]);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getString(rs.getColumnIndex('title'))).assertEqual('测试谱');
      } finally {
        rs.close();
      }
    });

    it('saveBookUpdatesTitle', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const m: BookManager = manager as BookManager;
      const book: Genealogy = createEmptyGenealogy();
      book.key = createdId;
      book.title = '测试谱改名';
      await m.saveBook(book);

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT title FROM ${TABLE_BOOK} WHERE id = ?`, [createdId]);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getString(rs.getColumnIndex('title'))).assertEqual('测试谱改名');
      } finally {
        rs.close();
      }
    });

    it('deleteGenealogyRemovesBookRow', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const m: BookManager = manager as BookManager;
      await m.deleteGenealogy(createdId);

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_BOOK} WHERE id = ?`, [createdId]);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getLong(rs.getColumnIndex('c'))).assertEqual(0);
      } finally {
        rs.close();
      }
    });
  });
}
