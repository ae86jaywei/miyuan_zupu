'use strict';

/**
 * 复现：同步与 GenealogyService.init/reload 并发时，ensureSameBook 误判为“切换族谱”。
 *
 * 代码依据（ArkTS 无法在 Windows 直接执行，本脚本按下列源码的状态迁移逐行移植）：
 *  - Application/entry/src/main/ets/service/FamilySyncService.ets
 *      syncCurrent() 中 `const bookKey = book.key;` 后，pullAndReplay 每个阶段调用 ensureSameBook()
 *      ensureSameBook(): getCurrentBookId() !== bookKey || getBook().familyId !== familyId -> throw BOOK_CHANGED
 *  - Application/entry/src/main/ets/service/GenealogyService.ets
 *      doInit() 开始时未把 ready 置 false；reload() 中 current === null 分支会把
 *      currentBookId 置 0 且 book 置空（迁移/重载期间 books 暂不可见时即进入该分支）。
 *
 * 复现时序：init 期间 reload 执行 -> currentBookId/book 短暂归零 -> 同步在 await 后调用
 * ensureSameBook -> 抛出 SYNC_BOOK_CHANGED，与调试日志完全一致。
 */

const TAG = '[Genealogy][FamilySync]';
const BOOK_CHANGED = 'SYNC_BOOK_CHANGED';

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class GenealogyServiceModel {
  constructor() {
    // 单例保留上一次成功初始化的状态（Ability 重建、进程未死亡）
    this.ready = true;
    this.currentBookId = 1;
    this.book = { key: 1, familyId: 'a442c8d9-a995-43e2-9d9d-76b8bc5b1526' };
  }

  getBook() {
    return this.book;
  }

  getCurrentBookId() {
    return this.currentBookId;
  }

  isReady() {
    return this.ready;
  }

  /** 对应 GenealogyService.reload() 的 current === null 分支 */
  async reload() {
    await sleep(20);
    this.currentBookId = 0;
    this.book = { key: 0, familyId: '' };
    await sleep(80);
    this.currentBookId = 1;
    this.book = { key: 1, familyId: 'a442c8d9-a995-43e2-9d9d-76b8bc5b1526' };
  }
}

class FamilySyncServiceModel {
  constructor(svc) {
    this.svc = svc;
  }

  ensureSameBook(bookKey, familyId) {
    if (this.svc.getCurrentBookId() !== bookKey || this.svc.getBook().familyId !== familyId) {
      throw new Error(BOOK_CHANGED);
    }
  }

  async syncCurrent(reason) {
    const book = this.svc.getBook();
    const bookKey = book.key;
    const familyId = book.familyId;
    try {
      await sleep(50); // 模拟 sync-pull / outbox 推送的 await 窗口
      this.ensureSameBook(bookKey, familyId);
      console.log('[REPRO] sync succeeded');
      return { ok: true };
    } catch (err) {
      const msg = err && err.message ? err.message : String(err);
      console.log('[REPRO] ' + TAG + ' sync failed (' + reason + '): ' + msg);
      return { ok: false, message: '同步已中止：同步期间已切换族谱' };
    }
  }
}

async function main() {
  const svc = new GenealogyServiceModel();
  const sync = new FamilySyncServiceModel(svc);

  // 并发触发：init 重跑 -> reload（同步点击发生在 reload 尚未完成时）
  const reloadTask = svc.reload();
  const result = await sync.syncCurrent('settings');
  await reloadTask;

  console.log('[REPRO] sync_message=' + result.message);
  if (result.ok === false && String(result.message).indexOf('切换族谱') >= 0) {
    console.log('[REPRO] DEFECT_REPRODUCED=1');
    process.exitCode = 0;
  } else {
    console.log('[REPRO] DEFECT_REPRODUCED=0');
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error('[REPRO] unexpected_error=' + (err && err.stack ? err.stack : String(err)));
  process.exitCode = 2;
});