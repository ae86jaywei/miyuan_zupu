import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { getNode } from '@ohos/hvigor';
import * as fs from 'fs';
import * as path from 'path';

interface SigningMaterial {
  storeFile: string;
  storePassword: string;
  keyAlias: string;
  keyPassword: string;
  signAlg: string;
  profile: string;
  certpath: string;
}

interface SigningConfig {
  name: string;
  type: string;
  material: SigningMaterial;
}

interface SigningConfigFile {
  /** product 名称到签名配置名称的映射，未配置的 product 不注入签名 */
  productSigning?: Record<string, string>;
  signingConfigs: SigningConfig[];
}

/** 签名材料本地配置文件（不入库，见 .gitignore），构建时注入到 build-profile.json5 */
const SIGNING_CONFIG_FILE = path.join(__dirname, 'signing', 'signing.config.json');

function loadSigningConfigFile(): SigningConfigFile | undefined {
  if (!fs.existsSync(SIGNING_CONFIG_FILE)) {
    console.warn(`[signing] 未找到签名配置文件 ${SIGNING_CONFIG_FILE}，本次将按未签名方式构建。`);
    return undefined;
  }
  try {
    const content = fs.readFileSync(SIGNING_CONFIG_FILE, 'utf-8');
    return JSON.parse(content) as SigningConfigFile;
  } catch (error) {
    console.error(`[signing] 签名配置文件解析失败：${SIGNING_CONFIG_FILE}`, error);
    return undefined;
  }
}

const rootNode = getNode(__filename);
rootNode?.afterNodeEvaluate(node => {
  const signingConfigFile = loadSigningConfigFile();
  if (!signingConfigFile || signingConfigFile.signingConfigs.length === 0) {
    return;
  }

  const signatureNames = signingConfigFile.signingConfigs.map(config => config.name);
  const productSigning = signingConfigFile.productSigning ?? {};
  for (const productName of Object.keys(productSigning)) {
    if (!signatureNames.includes(productSigning[productName])) {
      console.warn(`[signing] product ${productName} 引用的签名配置 ${productSigning[productName]} 不存在，跳过注入。`);
      delete productSigning[productName];
    }
  }

  const appContext = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
  const buildProfileOpt = appContext.getBuildProfileOpt();
  buildProfileOpt.app.signingConfigs = signingConfigFile.signingConfigs;
  buildProfileOpt.app.products?.forEach(product => {
    const signingName = productSigning[product.name];
    if (signingName) {
      product.signingConfig = signingName;
    }
  });
  appContext.setBuildProfileOpt(buildProfileOpt);
  console.info(`[signing] 已注入签名配置：${signatureNames.join(', ')}`);
});

export default {
  system: appTasks,
  plugins: []
}
