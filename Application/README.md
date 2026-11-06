# 觅源（Miyuan）· 鸿蒙族谱

> 觅源寻根，一款可以在手机、折叠屏、平板与电脑上创建族谱的鸿蒙版App。
> 支持 **欧式 / 苏式 / 宝塔式 / 牒记式 / 现代创新式** 五种谱式，

---

## 一、快速开始

- 包名（bundleName）：`com.zupu.ae86jay`
- 应用名：**觅源**
- 应用图标：分层图标（`AppScope/resources/base/media` 下的 `layered_image.json`
  = `background` 背景层 + `foreground` 前景层），预览见 [docs/images/app_icon_preview.png](docs/images/app_icon_preview.png)

```bash
# DevEco Studio 6.1.1+（HarmonyOS SDK API 12 ~ API 24）
# 打开本目录 → Sync → 运行 entry 模块

# 命令行编译（可选）
set DEVECO_SDK_HOME=D:\Program Files\Huawei\DevEco Studio\sdk
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

首次启动会自动建库并写入一部演示族谱（李氏宗谱 · 七世 · 19 人），
可在“设置 → 数据管理”中清空或导入自己的谱牒。

---

## 二、适配设备（一多）

| 设备形态 | 典型窗口宽（vp） | 断点 | 布局形态 |
| --- | --- | --- | --- |
| 手机 | 320 ~ 430 | XS | 底部 TabBar + 全屏详情弹层 |
| 双折叠 · 折叠 | 390 | XS | 同上 |
| 双折叠 · 展开 | 700 ~ 840 | SM ~ MD | 左侧图标栏 + 双栏主从 |
| 阔折叠 · 折叠 / 展开 | 500 / 600 | XS / SM | 底部栏 / 侧栏 |
| 阔屏（大直板、平板竖屏） | 600 ~ 840 | SM | 侧栏 + 主内容 |
| 平板横屏 / 三折叠展开 | 840 ~ 1200 | MD / LG | 三栏：导航 · 谱系 · 详情 |
| 电脑（2in1） | 1200+ | XL | 完整侧栏 + 三栏 + 宽间距 |

实现要点：

1. `module.json5` 声明 `deviceTypes: ["phone", "tablet", "2in1"]`，
   折叠屏（双折叠 / 三折叠 / 阔折叠 / 阔屏）在鸿蒙中均以 phone + 窗口宽度呈现，
   统一由断点驱动布局。
2. `pages/Index.ets` 用 `onAreaChange` 实时获取窗口宽度并写入
   `AppStorage['windowWidth']`，配合 `util/DeviceUtil.listenBreakpoints()`
   注册官方 `mediaquery` 监听，折叠 / 展开、电脑拖拽窗口时布局即时切换。
3. `common/Layout.ets` 提供页边距、栅格列数、侧栏折叠、主从分栏等计算；
   `util/DeviceUtil.formOf()` 进一步识别双折叠 / 三折叠 / 阔折叠 / 阔屏 / 平板 / 电脑，
   用于字号、卡片宽度、谱式渲染密度等细节微调。
4. Ability 设置 `minWindowWidth: 320 / minWindowHeight: 480`，保证电脑端窗口自由缩放。

---

## 三、五种谱式

| 谱式 | 实现文件 | 说明 |
| --- | --- | --- |
| 欧式谱 | `components/tree/EuTree.ets` | 横轴世系图：始祖居左，自左向右逐代展开 |
| 苏式谱 | `components/tree/SuTree.ets` | 竖式吊线图：父上子下，以竖线相缀，并显示字派标记 |
| 宝塔式谱 | `components/tree/PagodaTree.ets` | 金字塔：上窄下宽，始祖居塔尖，逐代向两侧铺开 |
| 牒记式谱 | `components/tree/DieRecord.ets` | 文字编年：按世序逐人成条，内容最详备，适合打印成册 |
| 现代创新式 | `components/tree/ModernTree.ets` | 卡片时间轴：头像 + 生卒 + 职位 + 简介，适合手机/平板 |

`view/TreeCanvas.ets` 负责按谱式分发渲染，并提供缩放（50%~150%）、
横向/纵向滚动、世代索引等能力。

---

## 四、字段规范（完全对齐 Excel）

| 分类 | 字段（数据模型 `Person`） |
| --- | --- |
| 身份标识 | 世代 `generation`、唯一ID `uid`、谱名 `name`、曾用名/小名 `alias`、性别 `gender`、辈分/字派 `generationChar`、在世状态 `lifeStatus` |
| 时间信息 | 出生日期 `birthDate` + 历法 `birthCalendar`(公历/农历)、逝世日期 `deathDate` + 历法、出生地 `birthPlace`(省-市-县-乡镇-村)、现居地 `residence` |
| 亲属关系 | 父亲ID `fatherId`、母亲ID `motherId`、**配偶ID `spouseId`（扩展）**、排行 `rank`、过继/出嗣 `adoption` |
| 生平履历 | 学历/学位 `education`、职业/职务 `occupation`、生平简介 `biography`(500字)、墓葬信息 `graveInfo` + GPS（经纬度/海拔） |
| 联系方式 | 手机号 `phone`、微信号 `wechat`（隐私字段，默认打码） |
| 图像信息 | 头像 `avatar`、相片 `photos`、视频资料 `videos` |

- 主键校验：唯一ID 全局不可重复（`IdGenerator.isUnique`），新增时按 `F/M + 序号` 自动生成，
  修改 ID 时会自动同步所有引用它的父亲/母亲/配偶字段。
- 亲属关系以“下拉选择已有族人”方式录入，避免手工输错 ID；
  新增子女时自动继承父母 ID、世代 +1 并套用字派谱。
- 出生地支持“省-市-县-乡镇-村”五级格式提示与自由文本。
- 墓葬支持系统定位拾取经纬度与海拔，或参考高德/百度/花瓣地图读取坐标后手工录入。

---

## 五、功能清单

- **概览**：封面卡片、族众统计（总人数 / 男女 / 在世已故 / 世数）、世代分布条形图、最近更新、家训、谱序。
- **谱系**：五谱式切换、缩放、按族谱树递归渲染、点击人物查看详情。
- **名录**：全文搜索（谱名/曾用名/ID/字派/籍贯/职业）+ 世代、性别、在世状态筛选。
- **统计**：性别构成、在世状况、世代繁衍表、字派分布、平均寿命、资料完整度（出生日期 / 头像 / 墓葬定位覆盖率）。
- **人物详情**：按字段分类完整展示，隐私字段打码；显示父母、配偶、兄弟姊妹、子女，可直接跳转；宽屏为右栏，窄屏为底部弹层。
- **人物编辑**：全部字段表单 + 实时预览（宽屏右栏）；头像/相片选择（PhotoPicker）；校验必填、日期先后、ID 唯一与存在性。
- **导入导出**：JSON 全量备份、JSON 脱敏分享版、CSV（与 Excel 字段一一对应）、Markdown 牒记谱文、整本 PDF；导入支持 JSON/CSV，ID 冲突可选跳过/覆盖/另生成 ID。整谱备份内含「族谱信息」，**删除族谱后可直接导入备份恢复**：按文件里的谱名自动新建族谱，并把堂号/郡望/始迁祖/字派/谱序/家训/凡例一并写回；已有族谱时只合并族人，不覆盖现有设置。
- **设置**：族谱信息（谱名、堂号、郡望、始迁祖、字派谱、谱序、家训、凡例）、默认谱式、隐私开关与公开模式、设备适配信息。
- **隐私**：手机号打码显示、公开模式下隐藏联系方式、导出可选脱敏。

---

## 六、目录结构

```
entry/src/main/ets/
├── entryability/EntryAbility.ets      应用入口：初始化数据库、上下文
├── pages/
│   ├── Index.ets                      主界面（断点驱动的多形态布局）
│   ├── PersonEdit.ets                 人物编辑（全字段）
│   ├── ImportExport.ets               导入导出中心
│   └── Settings.ets                   独立设置页
├── view/
│   ├── HomeView.ets                   概览
│   ├── TreeCanvas.ets                 谱式画布（五种谱式分发）
│   ├── StyleSwitcher.ets              谱式切换器
│   ├── CatalogView.ets                世系名录
│   ├── GenealogyStatsPanel.ets        统计中心
│   ├── PersonDetailPanel.ets          人物详情
│   └── SettingsView.ets               设置内容
├── components/
│   ├── tree/                          五种谱式渲染组件
│   ├── PersonAvatar.ets Tag.ets StatCard.ets InfoRow.ets EmptyHint.ets TS.ets
│   └── SectionCard.ets
├── service/
│   ├── GenealogyService.ets           关系型数据库 + 树构建 + 统计
│   ├── TreeBuilder.ets                世系树构建
│   ├── ExportService.ets              CSV/JSON/Markdown 导出与解析
│   └── SeedData.ets                   演示族谱
├── model/                             Person / Genealogy / PersonNode / Stats / Enums
├── util/                              DateUtil / IdGenerator / StringUtil / DeviceUtil / RouterUtil
├── store/GenealogyStore.ets           全局版本号驱动的刷新
└── theme/Theme.ets                    宣纸 + 朱砂 + 鎏金配色
```

---

## 七、数据存储

使用 `@kit.ArkData` 关系型数据库（RDB，SQLite）：

- `person` 表：32 列，一一对应人物字段；
- `genealogy` 表：族谱元信息（谱名、堂号、字派等）。

删改 ID、删除人物时自动维护父亲/母亲/配偶引用一致性。

---

## 八、家族协作（本次新增）

> 技术设计与事实依据见 [家族协作编辑设计方案.md](家族协作编辑设计方案.md)；
> **需要你在 AGC 控制台手动完成的部分见 [AGC手动操作步骤方案.md](AGC手动操作步骤方案.md)**。

### 8.1 模型（一句话）

**一部谱 = 一个云家族（familyId）**；云侧新建独立存储区 `miyuanfamily` 存放协作数据，
端侧对其中 12 张表**没有任何直接读写权限**，所有数据都经过云函数；
可见性 = 有没有一条 `ACTIVE` 的 `Membership`。

### 8.2 「谁能看」的三条门槛（产品口径三选一，实现上只落一张表）

| 门槛 | 入口 | 审批 | 产出 |
| --- | --- | --- | --- |
| ① 申请认证 | 族谱黄页 →「申请查看」 | 谱主审批 | `Membership(VIEWER, expireAt = now+180天)` |
| ② 分享链接 | 加入码 →「用加入码加入」 | 无需审批 | `Membership(VIEWER/EDITOR)` |
| ③ 成为族人 | 族谱黄页 →「我要加入」并认领支系 | 谱主审批 | `Membership(EDITOR, 永久, branchRootUid)` |

到期失效采用**惰性校验**（云函数鉴权时比较 `expireAt`），不需要定时任务。

### 8.3 隐私

- `payload` 写云前**剔除**手机号 / 微信 / 现居地（进 `FamilyPrivate`，只有谱主经云函数能读）；
- 墓葬坐标**迁出**到公开对象类型 `FamilyGraveLocation`（祭祖寻墓，任意登录用户可查）；
- 族谱黄页 `FamilyDirectory` **默认不可搜**，上架后才可被搜到，下架 = 从表中删除该行。

### 8.4 端侧新增

| 页面 | 作用 |
| --- | --- |
| `pages/FamilyHome.ets` | 我的家族：接入云家族 / 加入码加入 / 发布本谱 / 同步 / 协作入口 |
| `pages/FamilyMembers.ets` | 成员与访问申请审批（三条门槛的唯一审批入口） |
| `pages/FamilyDirectoryView.ets` | 族谱黄页（只含索引元数据）+ 谱主上架管理 |
| `pages/AccessApply.ets` | 申请查看 / 申请成为族人 + 我的申请 |
| `pages/GraveMap.ets` | 祭祖寻墓（公开墓葬表 + 本地缓存，离线可查） |
| `pages/ChangeReview.ets` | 待审变更的字段级 diff 与审核合入 |

| 服务 | 作用 |
| --- | --- |
| `service/FamilyService.ets` | 云函数调用封装 + 家族身份/角色 + 写路径编排 |
| `service/FamilySyncService.ets` | outbox 上传 → sync-pull 增量拉取 → 回放 RDB（唯一读取通道） |
| `service/FamilyBootstrapService.ets` | 首次把本地全量谱分页发布（≤100 条/次，与云端 MAX_BATCH 一致；限速重试，幂等断点续传） |
| `service/OutboxService.ets` | 断网可编辑：本地变更排队，联网后补传 |
| `service/GraveService.ets` | 公开墓葬查询 + 本地 `grave_location` 缓存 |
| `service/DirectoryService.ets` | 黄页搜索与上架 |
| `service/PrivacyService.ets` | 谱主读取隐私字段（其他人拿不到） |

云侧代码在 `CloudProgram/`（**23 个云函数 + 零依赖共享库 `_shared`**）。
DevEco 部署云函数时会执行 `npm install`，每个函数通过 `preinstall` 自动把 `_shared`
和 `agconnect-credential.json` 复制到自己的 `shared/`/凭据文件，**不再需要手动同步或打包 zip**。

需要本地跑冒烟测试时直接执行：

```powershell
node CloudProgram/tools/smoke-test.js   # 会自动同步所有函数的 shared/，再跑 44 项测试
```

**需要在 AGC 控制台手动完成的部分**（建 Zone、建 13 张表、配权限、部署 23 个函数、回归验证），
见 [AGC手动操作步骤方案.md](AGC手动操作步骤方案.md)。

### 8.5 本地数据库变更（自动迁移，无需手动）

`person` 表新增 `rev / base_rev / dirty / deleted_at`；`genealogy` 表新增
`family_id / sync_mode / cloud_rev / family_role`；新增表 `outbox`、`grave_location`。

### 8.6 云函数部署要点（踩过的坑）

1. **共享库用相对路径 `require('./shared')`，不要用 `node_modules/_zupu_shared`。**
   DevEco 构建时会执行 npm 安装，把未写入 `package.json` dependencies 的多余目录清掉，
   部署包里就没有该模块，线上报 `Cannot find module '_zupu_shared'`。
   `shared/` 是函数源码目录内的普通文件夹，打包会原样带上。
2. **每个函数 `package.json` 都有 `preinstall: node ../_shared/install-into-function.js`**；
   修改 `_shared` 后直接在 DevEco 部署即可，安装依赖时会自动重建 `shared/`。
3. **谱元信息直写**（uid 为空串）与**新增族人**（`op=ADD`）都由 `member-direct-write` 处理；
   云端缺记录时 ADD 会建档，只有 `UPDATE` 到不存在的 uid 才报「族人不存在」。
4. **`agconnect-credential.json`（含 `client_secret`）不入库**，`preinstall` 会在文件存在时自动复制到函数目录。
5. **`shared/` 是生成物，也不入库**；每次 `npm install` 或冒烟测试都会自动重建。

---

## 九、后续可扩展

- 家谱世系图导出为高清图片 / PDF 成册；
- 族谱事件（婚丧、迁徙、祭祖）时间轴与提醒；
- 农历精确换算（节气、闰月）与生辰提醒；
- P3：变更推送（Push Kit）、长文分段贡献、谱系版本回滚。