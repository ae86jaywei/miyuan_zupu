# 觅源（Miyuan）· 鸿蒙族谱

> 一部可以装在手机、折叠屏、平板与电脑上的“电子族谱”App。
> 支持 **欧式 / 苏式 / 宝塔式 / 牒记式 / 现代创新式** 五种谱式，
> 完整覆盖《关键信息字段_20261023.xlsx》中的 5 大类 22 项字段。

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
- **导入导出**：JSON 全量备份、JSON 脱敏分享版、CSV（与 Excel 字段一一对应）、Markdown 牒记谱文；导入支持 JSON/CSV，ID 冲突可选跳过/覆盖/另生成 ID。
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

## 八、后续可扩展

- 云端备份与家族协作（全员共享一部族谱、线上认领补录）；
- 家谱世系图导出为高清图片 / PDF 成册；
- 族谱事件（婚丧、迁徙、祭祖）时间轴与提醒；
- 农历精确换算（节气、闰月）与生辰提醒。
