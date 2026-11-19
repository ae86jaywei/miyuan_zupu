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
export const PDF_MUTED: string = '#767676';
/** 谱牒金色（始祖/卷名/强调） */
export const PDF_GOLD: string = '#90722A';

/** 女性姓名 */
export const PDF_FEMALE: string = '#a0527a';
/** 纸白 */
export const PDF_BG: string = '#ffffff';
/** 卡片正文 */
export const PDF_TEXT: string = '#2B2B2B';
/** 卡片次级文字 */
export const PDF_TEXT_2: string = '#7A6A5A';
/** 卷首标题 */
export const PDF_HEADER: string = '#5B4B3B';
/** 卷末页脚 */
export const PDF_FOOTER: string = '#6B5B4B';