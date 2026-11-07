# 觅源（Miyuan）Codebase 文档

> 📁 本文档位于 `Application/docs/`，与 DevEco 工程同目录，避免在仓库根目录产生额外文件影响云开发模块识别。
> 📁 本文档为项目总览。目录结构较复杂的模块已拆分为独立子文档，详见各节说明。

## 1. 技术栈

- **语言**：ArkTS（HarmonyOS Stage 模型，TypeScript 超集）
- **SDK 版本**：compatibleSdkVersion `6.1.1(24)`，targetSdkVersion `26.0.0`（来自 `Application/build-profile.json5 > app.products`）
- **构建工具**：hvigor（`Application/hvigor/hvigor-config.json5`，modelVersion `5.0.5`）
- **开发工具**：DevEco Studio 6.1.1+（来源：`Application/README.md > 一、快速开始`）
- **运行时 / 框架**：HarmonyOS ArkUI（Stage 模型，UIAbility）
- **端侧三方依赖**：`@hw-agconnect/auth` `^1.1.0`（来自 `Application/entry/oh-package.json5`）
- **云侧运行时**：Node.js（CloudFunctions，`@types/node` `^18.11.11`、`typescript` `^5.4.2`，来自 `CloudProgram/package.json > devDependencies`）
- **数据存储**：端侧 `@kit.ArkData` 关系型数据库（RDB/SQLite）；云侧 AGC Cloud DB（`CloudProgram/clouddb`）
- **测试**：云函数冒烟测试脚本 `CloudProgram/tools/smoke-test.js`（Node.js 直接执行，无独立测试框架版本记录）

## 2. 项目目录结构

> 💡 已拆分为子文档的模块，在目录树中以 `📄 详见：[路径]` 标注，不在此处展开。

```
miyuan_yunkaifa/
├── Application/                        # HarmonyOS 客户端工程（DevEco Studio 可直接打开的根目录）
│   ├── AppScope/                       # 应用级配置与分层图标等全局资源
│   ├── entry/                          # 唯一 HAP 模块：应用入口与全部端侧业务
│   │   ├── src/main/ets/               # 端侧核心业务源码
│   │   │   ├── common/                 # 布局断点、页边距、栅格与通用常量计算
│   │   │   ├── components/             # 可复用 UI 组件：头像、标签、统计卡、信息行、空态、分区卡片
│   │   │   │   └── tree/               # 五种谱式渲染组件（欧式/苏式/宝塔式/牒记式/现代创新式）
│   │   │   ├── entryability/           # UIAbility 入口：数据库初始化、全局上下文注入
│   │   │   ├── model/                  # 数据模型与枚举：Person、Genealogy、PersonNode、Stats 等
│   │   │   ├── pages/                  # 路由级页面：主界面、人物编辑、导入导出、设置、家族协作、黄页、墓葬地图、变更审核
│   │   │   ├── service/                # 业务服务：族谱 CRUD/树构建/统计/导入导出、云函数调用、同步与 outbox、隐私
│   │   │   ├── store/                  # 全局状态：基于版本号驱动的谱系数据刷新
│   │   │   ├── theme/                  # 宣纸 + 朱砂 + 鎏金主题配色
│   │   │   ├── util/                   # 日期、ID 生成、字符串、设备形态、路由等工具
│   │   │   └── view/                   # 页面级视图：概览、谱系画布、谱式切换、名录、统计、详情、设置内容
│   │   ├── src/main/resources/         # 多语言字符串、颜色、媒体、页面路由 profile 等静态资源
│   │   ├── build-profile.json5         # entry 模块构建目标与 release 混淆配置
│   │   ├── oh-package.json5            # entry 模块包声明与端侧依赖
│   │   └── obfuscation-rules.txt       # release 构建混淆规则
│   ├── docs/                           # 设计、性能、上架、代码规范与方案文档
│   ├── hvigor/                         # hvigor 构建工具配置
│   ├── zhengshu/                       # 签名证书与调试 profile
│   ├── build-profile.json5             # 应用级产品、签名、SDK 版本与模块声明
│   ├── oh-package.json5                # 应用级包声明与云函数根目录配置
│   └── hvigorfile.ts                   # 应用级 hvigor 任务入口
├── CloudProgram/                       # 云侧工程：23 个云函数 + 共享库 + Cloud DB 对象类型
│   # 📄 详见：codebase-docs/cloudprogram-structure.md
└── .bugfix/                            # 缺陷修复流程产物（分析/复现/定位/补丁），按 issue 编号隔离
```

## 3. 开发命令（核心）

> ⚠️ 所有命令均来源于项目文档，每条命令后注明出处。

### 构建命令
```bash
# 工作目录：Application（来源：Application/README.md > 一、快速开始；已实际执行验证 BUILD SUCCESSFUL）
set DEVECO_SDK_HOME=D:\Program Files\Huawei\DevEco Studio\sdk
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

> 构建命令验证说明：README 命令可直接执行，但必须在 `Application` 目录下运行（`build-profile.json5`、`hvigor/`、`hvigorfile.ts` 均位于该目录），并在当前环境设置 `DEVECO_SDK_HOME`。验证方式：在 `Application` 目录执行上述命令，输出 `BUILD SUCCESSFUL`，产物为 `entry/build/default/outputs/default/entry-default-unsigned.hap`。全局 `hvigorw` 由 DevEco Studio 提供（`D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat`），工程内无 wrapper 脚本。

### 测试命令
```bash
# 云函数冒烟测试（来源：Application/README.md > 八、家族协作；自动同步各函数 shared/ 后执行 44 项测试）
node CloudProgram/tools/smoke-test.js
```

### 运行 / 启动命令
```bash
# 图形化运行：DevEco Studio 6.1.1+ 打开 Application 目录 → Sync → 运行 entry 模块（来源：Application/README.md > 一、快速开始）
# 文档中未提供纯命令行启动/安装命令，请参考 Application/entry/build-profile.json5 与 DevEco Studio 运行配置自行确认
```

## 4. 开发环境（简要）

### 前置要求

- DevEco Studio 6.1.1+（HarmonyOS SDK API 12 ~ API 24）
- HarmonyOS SDK，`DEVECO_SDK_HOME` 指向 SDK 安装目录
- Node.js（用于 `CloudProgram/tools/smoke-test.js` 冒烟测试；具体最低版本项目未记录）

### 配置说明（选填）

- `Application/build-profile.json5`：签名证书、产品 SDK 版本、模块声明
- `Application/oh-package.json5`：`cloudfunctionRoot` 指向 `./CloudProgram/cloudfunctions/`
- `CloudProgram/cloud-config.json`：云函数部署配置
- `CloudProgram/cloudfunctions/_shared`：多函数共享库，通过各函数 `preinstall` 自动复制到函数目录

## 5. 子文档索引

> 以下子文档由本次拆分自动生成。

| 文档 | 对应模块/业务域 | 职责摘要 |
|------|----------------|----------|
| [cloudprogram-structure.md](codebase-docs/cloudprogram-structure.md) | `CloudProgram/` | 云函数、共享鉴权/校验库与 Cloud DB 对象类型的完整结构 |