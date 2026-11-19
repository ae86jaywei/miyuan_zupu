import { relationalStore } from '@kit.ArkData';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { UIAbility, common, Want } from '@kit.AbilityKit';

/**
 * 打开仪器化测试用数据库。
 *
 * 测试进程不会自动拉起测试 Ability，而 RDB 需要 UIAbilityContext
 * （普通 Context 会报 401 Illegal context），因此先启动 TestAbility 再取上下文。
 */
export async function openTestStore(bundleName: string, moduleName: string,
  abilityName: string, dbName: string): Promise<relationalStore.RdbStore> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const want: Want = {
    bundleName: bundleName,
    moduleName: moduleName,
    abilityName: abilityName
  };
  try {
    await delegator.startAbility(want);
  } catch (e) {
  }
  await new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 1000);
  });
  const ability: UIAbility = await delegator.getCurrentTopAbility() as UIAbility;
  const context: common.UIAbilityContext = ability.context;
  const cfg: relationalStore.StoreConfig = {
    name: dbName,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  return await relationalStore.getRdbStore(context, cfg);
}
