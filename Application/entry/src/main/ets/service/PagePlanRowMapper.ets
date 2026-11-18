import { relationalStore } from '@kit.ArkData';
import { PageCut, PageJump, PagePlan, PageRootRef } from './PaginationService';

/**
 * page_cache_plan 表行映射。
 *
 * 列名与 JSON 序列化格式只在这里维护：整本缓存读取、增量重排读取、
 * 导出后落库三条路径共用，避免出现“写进去的列和读出来的列不一致”。
 */
export class PagePlanRowMapper {
  /** 数据库行 → PagePlan */
  static parse(rs: relationalStore.ResultSet): PagePlan {
    const p: PagePlan = new PagePlan();
    p.index = rs.getLong(rs.getColumnIndex('page_no'));
    p.branchId = rs.getString(rs.getColumnIndex('branch_id'));
    p.genFrom = rs.getLong(rs.getColumnIndex('gen_from'));
    p.genTo = rs.getLong(rs.getColumnIndex('gen_to'));
    p.rootUids = PagePlanRowMapper.parseStringArray(rs.getString(rs.getColumnIndex('root_uids')));
    p.uids = PagePlanRowMapper.parseUidSet(rs.getString(rs.getColumnIndex('uids')));
    p.roots = JSON.parse(rs.getString(rs.getColumnIndex('roots_json'))) as PageRootRef[];
    p.cuts = JSON.parse(rs.getString(rs.getColumnIndex('cuts_json'))) as PageCut[];
    p.contextAncestors = PagePlanRowMapper.parseStringArray(
      rs.getString(rs.getColumnIndex('context_uids')));
    p.contextAncestorNames = PagePlanRowMapper.parseStringArray(
      rs.getString(rs.getColumnIndex('context_names')));
    p.siblingLinks = JSON.parse(rs.getString(rs.getColumnIndex('sibling_json'))) as PageJump[];
    p.footerText = rs.getString(rs.getColumnIndex('footer_text'));
    p.branchName = rs.getString(rs.getColumnIndex('branch_name'));
    p.recto = rs.getLong(rs.getColumnIndex('recto')) === 1;
    return p;
  }

  /** PagePlan → 数据库行（uids 由调用方按页内顺序展开） */
  static toRow(cacheKey: string, page: PagePlan, globalPage: number,
    volume: number, pageNo: number, uids: string[]): relationalStore.ValuesBucket {
    const row: relationalStore.ValuesBucket = {
      'cache_key': cacheKey,
      'global_page': globalPage,
      'volume': volume,
      'page_no': pageNo,
      'branch_id': page.branchId,
      'page_root_uid': page.rootUids.length > 0 ? page.rootUids[0] : '',
      'gen_from': page.genFrom,
      'gen_to': page.genTo,
      'root_uids': JSON.stringify(page.rootUids),
      'uids': JSON.stringify(uids),
      'roots_json': JSON.stringify(page.roots),
      'cuts_json': JSON.stringify(page.cuts),
      'context_uids': JSON.stringify(page.contextAncestors),
      'context_names': JSON.stringify(page.contextAncestorNames),
      'sibling_json': JSON.stringify(page.siblingLinks),
      'footer_text': page.footerText,
      'branch_name': page.branchName,
      'recto': page.recto ? 1 : 0
    };
    return row;
  }

  private static parseStringArray(text: string): string[] {
    if (text.length === 0) {
      return [];
    }
    return JSON.parse(text) as string[];
  }

  private static parseUidSet(text: string): Set<string> {
    const out: Set<string> = new Set<string>();
    if (text.length === 0) {
      return out;
    }
    const arr: string[] = JSON.parse(text) as string[];
    for (let i: number = 0; i < arr.length; i = i + 1) {
      out.add(arr[i]);
    }
    return out;
  }
}
