/**
 * PDF 导出共用的单位与基础色。
 * 牒记 A4 与卡片分页两套渲染器原先各自定义，数值完全相同。
 */

/** 1mm = 72/25.4 pt */
export const MM_TO_PT: number = 72 / 25.4;

/** A4 纸张（pt，与 210×297mm 一致） */
export const A4_W_PT: number = 595.28;
export const A4_H_PT: number = 841.89;

/** 打印基础墨色 */
export const PDF_INK: string = '#1a1a1a';
export const PDF_INK_2: string = '#444444';
/** 弱化文字（祖先/注释/三级信息） */
export const PDF_MUTED: string = '#888888';
/** 谱牒金色（始祖/卷名/强调） */
export const PDF_GOLD: string = '#9c7c2e';