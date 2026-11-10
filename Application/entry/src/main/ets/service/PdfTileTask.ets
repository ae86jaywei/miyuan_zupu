import { renderTileImpl } from './PdfRasterJob';

/**
 * TaskPool 任务入口。
 *
 * 单独放在这个轻量模块里：worker 只需要加载它（以及 PdfRasterJob），
 * 不会把整个 PagedPdfExportService 及其依赖（数据模型、排版等）都拉进每个 worker，
 * 避免重复解析同一个大模块产生大量 "[debugger] Script already been parsed" 警告。
 *
 * @Concurrent 函数只能引用导入的变量，因此具体实现放在 PdfRasterJob.renderTileImpl。
 */
@Concurrent
async function renderTileJob(pageNo: number, r: number, c: number, lineWidthMm: number,
  lineData: number[], boxData: number[], cacheDir: string): Promise<string> {
  return await renderTileImpl(pageNo, r, c, lineWidthMm, lineData, boxData, cacheDir);
}

export { renderTileJob };
