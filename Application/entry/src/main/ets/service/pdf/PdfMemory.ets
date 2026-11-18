import { hidebug } from '@kit.PerformanceAnalysisKit';

/**
 * PDF 导出共用的进程内存监控。
 * 牒记 A4 与卡片分页两套渲染器原先各写一份，逻辑完全一致。
 */

/** 读取当前进程 PSS（KB），失败返回 -1；hidebug.getPss() 返回 bigint */
export function currentPssKb(): number {
  try {
    return Number(hidebug.getPss());
  } catch (_e) {
    return -1;
  }
}

/** 硬上限：仅进程接近系统限制时才中止导出 */
export const PDF_MEMORY_HARD_LIMIT_KB: number = 2600 * 1024;