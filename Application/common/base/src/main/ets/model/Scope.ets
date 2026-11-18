import { common } from '@kit.AbilityKit';

/**
 * 全局跳转参数与上下文持有。
 */
export class GenealogyScope {
  private static appContext: common.UIAbilityContext | null = null;

  static set(context: common.UIAbilityContext): void {
    GenealogyScope.appContext = context;
  }

  static context(): common.UIAbilityContext {
    return GenealogyScope.appContext as common.UIAbilityContext;
  }

  /** 服务是否已初始化完成（页面可直接调用） */
  static isReady(): boolean {
    return GenealogyScope.appContext !== null;
  }
}

/** 人物编辑页参数 */
export class EditParams {
  /** 编辑模式：create / edit / child */
  mode: string = 'edit';
  /** 人物唯一ID */
  uid: string = '';
  /** 新生子女时预设的父亲或母亲ID */
  presetParent: string = '';
}

/** 渲染视图参数 */
export class ViewOptions {
  style: string = 'eu';
  /** 只看在世 */
  onlyVisible: boolean = true;
  /** 只看某房（根人物ID），空表示全宗 */
  branchUid: string = '';
  /** 高亮人物 */
  highlightUid: string = '';
  /** 是否为公开模式（隐藏隐私字段） */
  publicMode: boolean = false;
  /** 缩放比例 */
  zoom: number = 1;
}

/** 访问申请页参数 */
export class AccessParams {
  /** 目标族谱（空表示从「我的申请」进入） */
  familyId: string = '';
  /** 预填的申请类型：VIEW_APPLY / JOIN_CLAIM */
  kind: string = '';
}
