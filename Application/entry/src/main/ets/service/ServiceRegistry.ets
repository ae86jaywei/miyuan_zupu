/**
 * 服务统一入口（Service Locator）。
 *
 * 应用内 17 个单例服务通过各自的 getInstance() 暴露，
 * 本类提供集中入口，调用方可以只 import 本类而不必逐个 import Service。
 *
 * 当前只是静态转发层，不持有状态、不改变实例生命周期。
 * 未来如需支持测试替身 / mock，可在本类内部替换为可注入实现。
 */

import { GenealogyService } from './GenealogyService';
import { AccountService } from './AccountService';
import { CloudFunctionClient } from './CloudFunctionClient';
import { CloudSyncService } from './CloudSyncService';
import { ConsentService } from './ConsentService';
import { DirectoryService } from './DirectoryService';
import { DisplayService } from './DisplayService';
import { FamilyBootstrapService } from './FamilyBootstrapService';
import { FamilyService } from './FamilyService';
import { FamilySyncService } from './FamilySyncService';
import { GraveService } from './GraveService';
import { OutboxService } from './OutboxService';
import { PageCacheService } from './PageCacheService';
import { PaginationService } from './PaginationService';
import { PrivacyService } from './PrivacyService';
import { TreeLayoutCache } from './TreeLayoutCache';

export class SR {
  static genealogy(): GenealogyService { return GenealogyService.getInstance(); }
  static account(): AccountService { return AccountService.getInstance(); }
  static cloud(): CloudFunctionClient { return CloudFunctionClient.getInstance(); }
  static cloudSync(): CloudSyncService { return CloudSyncService.getInstance(); }
  static consent(): ConsentService { return ConsentService.getInstance(); }
  static directory(): DirectoryService { return DirectoryService.getInstance(); }
  static display(): DisplayService { return DisplayService.getInstance(); }
  static familyBootstrap(): FamilyBootstrapService { return FamilyBootstrapService.getInstance(); }
  static family(): FamilyService { return FamilyService.getInstance(); }
  static familySync(): FamilySyncService { return FamilySyncService.getInstance(); }
  static grave(): GraveService { return GraveService.getInstance(); }
  static outbox(): OutboxService { return OutboxService.getInstance(); }
  static pageCache(): PageCacheService { return PageCacheService.getInstance(); }
  static pagination(): PaginationService { return PaginationService.getInstance(); }
  static privacy(): PrivacyService { return PrivacyService.getInstance(); }
  static treeCache(): TreeLayoutCache { return TreeLayoutCache.getInstance(); }
}
