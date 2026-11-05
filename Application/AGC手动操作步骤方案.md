# 觅源 · 家族协作功能 —— AGC 手动操作步骤方案

> 配套设计：[家族协作编辑设计方案.md](家族协作编辑设计方案.md)（v1.3）
> 配套代码：`CloudProgram/`（22 个云函数 + 零依赖共享库）、`entry/src/main/ets/`（端侧实现）
> 版本 2.0　更新：2026-10-27（按当前实际工程结构重写）

---

## 0. 这份文档解决什么

代码已经全部写完并编译通过。剩下的是**只能在 AGC 控制台 / DevEco 里手工点**的事：

1. 配云侧工程入口（让 DevEco 认识 `CloudProgram`）；
2. 建「协作存储区」与 13 个对象类型（**字段部署后不可改**）；
3. 配对象类型权限（**这一步漏配 = 数据泄露**）；
4. 部署 23 个云函数、确认云函数能拿到可信调用者身份；
5. 回归验证。

**行文约定**：🔴 红线（做错会泄露/返工）；⚠️ 待验证（官方文档未定论，必须实测）；✅ 验收点。

---

## 1. 当前工程结构（先看清，别改）

```
E:\HarmonyOS\zupu\          ← 用 DevEco 打开「这个目录」会提示"不包含项目"，这是正常的
├── entry\                     ← 端侧工程（build-profile.json5 / hvigorfile.ts / oh-package.json5 都在这里）
│   ├── src\
│   ├── oh_modules\
│   ├── build-profile.json5
│   ├── hvigorfile.ts
│   └── oh-package.json5
├── AppScope\
├── hvigor\hvigor-config.json5
├── build-profile.json5        ← 工程级
├── hvigorfile.ts
├── oh-package.json5           ← 工程级（可在此加 cloudfunctionRoot）
├── CloudProgram\              ← 云侧工程（22 个云函数）
│   ├── cloud-config.json
│   ├── cloudfunctions\
│   └── tools\smoke-test.js
├── zhengshu\                  ← 签名证书（不入库）
└── docs\  *.md
```

🔴 **重要**：当前是「根目录直接放工程文件」的结构（`build-profile.json5` 在根），
**不是** `Application/` 子目录结构。之前的 `Application/` 改造方案已作废，不要照旧文档再拆。

---

## 2. 第 1 步：验证云侧代码完整性（本机可做，不用控制台）

打开 PowerShell：

```powershell
cd E:\HarmonyOS\zupu

# 1) 应有 23 个云函数目录（+ _shared）
(Get-ChildItem CloudProgram\cloudfunctions -Directory |
  Where-Object { $_.Name -ne '_shared' }).Count     # 期望输出 23

# 2) 每个函数都应有三件套：index.js / package.json / function-config.json
Get-ChildItem CloudProgram\cloudfunctions -Directory |
  Where-Object { $_.Name -ne '_shared' } | ForEach-Object {
    foreach ($f in 'index.js','package.json','function-config.json') {
      if (-not (Test-Path (Join-Path $_.FullName $f))) { Write-Host "缺: $($_.Name)/$f" }
    }
  }                                                   # 期望：无输出

# 3) 语法自检
Get-ChildItem CloudProgram\cloudfunctions -Directory |
  Where-Object { $_.Name -ne '_shared' } | ForEach-Object {
    node --check (Join-Path $_.FullName 'index.js')
  }                                                   # 期望：无报错

# 4) 共享库由每个函数的 npm preinstall 自动同步，DevEco 部署无需手动执行脚本
```

✅ 上面三步全绿，说明云侧代码完整。

> DevEco 部署会执行 npm install，并通过每个函数的 `preinstall` 自动重建 `shared/`；
> `smoke-test.js` 也会自动同步，无需再运行任何 PowerShell 脚本。

---

## 3. 第 2 步：配置云侧工程入口（让 DevEco 认识 CloudProgram）

### 3.1 在工程级 `oh-package.json5` 里加一行

文件：`E:\HarmonyOS\zupu\oh-package.json5`

```json5
{
  "modelVersion": "5.0.5",
  "description": "觅源 · 中华宗族谱牒数字化应用",
  "cloudfunctionRoot": "./CloudProgram/cloudfunctions/",
  "dependencies": {},
  "devDependencies": {}
}
```

### 3.2 「找不到项目结构菜单」说明

DevEco Studio **没有** IDEA 那样的「File → Project Structure」可视化面板，工程结构全部由磁盘上的
`build-profile.json5` / `hvigorfile.ts` / `oh-package.json5` 决定。

云函数工程由 **`cloudfunctionRoot`** 字段挂载（DevEco 云开发插件读取），并且：

- 云函数**不会**出现在左侧 Project 树里，而是在**右侧 `CloudDev` 工具窗口**（日志里叫
  `open clouddev tool windows`）；
- 右键 `cloudfunctions` 才会出现 `Deploy` / `Sync` 菜单。

### 3.3 如果 `CloudDev` 面板里没有云函数

按顺序试（每步之后都 `File → Sync` 一次）：

| 顺序 | 操作 |
|---|---|
| ① | 确认已登录华为账号（右下角） |
| ② | 关闭窗口 → 重新打开 `E:\HarmonyOS\zupu` |
| ③ | `File → Invalidate Caches / Restart`，勾选 *Clear file system cache* |
| ④ | 检查 `hvigor\hvigor-config.json5` 是否被改坏（见 §3.4） |
| ⑤ | 仍不行 → 直接走 §7.4「控制台部署」，不依赖 DevEco |

### 3.4 🔴 `hvigor-config.json5` 的正确内容

文件：`E:\HarmonyOS\zupu\hvigor\hvigor-config.json5`

```json5
{
  "modelVersion": "5.0.5",
  "dependencies": {},
  "execution": {},
  "logging": {},
  "debugging": {},
  "nodeOptions": {}
}
```

🔴 **不要**把它写成 `{ "hvigorVersion": "6.26.8", "dependencies": {} }`——
那样 hvigor 会直接报 `The project structure and configuration need to be upgraded before use.`，
表现是「点同步没反应、没有进度条」。

### 3.5 验证编译（不依赖 DevEco GUI）

```powershell
cd E:\HarmonyOS\zupu
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio\sdk'
$env:JAVA_HOME='D:\Program Files\Huawei\DevEco Studio\jbr'
$env:PATH='D:\Program Files\Huawei\DevEco Studio\tools\node;' + $env:PATH
& 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

✅ 输出 `BUILD SUCCESSFUL`，产物在 `entry\build\default\outputs\default\entry-default-signed.hap`。

---

## 4. 第 3 步：在 AGC 创建协作存储区

1. 打开 <https://developer.huawei.com/consumer/cn/service/josp/agc/index.html> → 我的项目 → 选择项目（`project_id = 101653523865445747`）；
2. 左侧 **云开发 → 云数据库**；
3. 点击 **新建存储区**，名称 `miyuanfamily`；
4. 同步模式选 **缓存模式**（端侧优先、可离线读写）。

🔴 **不要删除旧的 `miyuanzupu` Zone**：删除会连带删除全部备份数据且不可恢复。
单应用 Zone 上限为 **4 个**，当前 1 个、本次新增 1 个，**只剩 2 次机会**——所以 §5 的 13 张表必须一次建全。

---

## 5. 第 4 步：创建 13 个对象类型（最容易返工的一步）

### 5.1 🔴 为什么必须一次建到位

AGC 云数据库的对象类型**部署后字段不可改**：不能改字段名、不能改字段类型，只能新增字段。
要改已有字段 → 删除对象类型重新部署 → **该表数据一并删除且不可恢复**。

### 5.2 通用填写规则

| 设置项 | 值 |
|---|---|
| 字段名称 | **与下表完全一致**（大小写敏感） |
| 字段类型 | String / Integer / Long / Double / Boolean / Text |
| 主键 | 每张表只有 1 列勾选「是」 |
| 非空 | 仅主键勾选「是」，其他一律「否」 |
| 默认值 | 见下表 |
| 加密 / 敏感 | 一律「否」（`FamilyPrivate` 的 3 个字段可选开加密） |

### 5.3-A 🔥 最快做法：用导入文件一次性建完（推荐）

仓库里已经生成好导入文件：

```
CloudProgram/clouddb-import-13-objecttypes.json
```

它严格遵循 AGC 下载的官方模板 `ObjectTypeTemplate.json` 结构，包含：

- `objectTypes`：**13 个对象类型、159 个字段**（与 `entry/src/main/ets/model/FamilyModels.ets` 逐字段一致）；
- `permissions`：**13 条权限**，已按 §6 配好（11 表全关 + 2 张公开表只给 Authenticated 的 Read）。

**操作**：云数据库 → 对象类型 → 右上角 **「导入」** → 选择该文件 → 确认。

> 🔴 **关于导入文件里的权限**：官方模板要求 `World/Authenticated/Creator` 都要带 `Read`（不能为空数组），
> 否则控制台会报 **「导入失败：权限与角色不匹配」**。
> 本文件已按模板补齐（三个角色都给了 `Read`），**但这不是我们的最终权限**——
> 导入成功后必须立刻按 **§6.2** 把 11 张私表的这三个角色的权限**手动全部取消**，
> 否则任何人都能直读全库人物数据。
>
> 如果导入时仍然报「权限与角色不匹配」，改用**纯建表**方式：
> 把文件里的 `"permissions"` 整段删掉（只保留 `"objectTypes"`）再导入，然后按 §6 手动配权限。

#### 前置操作：先删除已有的 2 张旧表（本项目已确认旧备份可弃）

库里已有的 `FamilyMember` / `FamilyMedia` 是早期试建的旧结构，与本次定义不一致：

| 表 | 需新增 | 需删除 |
|---|---|---|
| `FamilyMember` | familyId, bookKey, uid, privateRef, graveRef, rev, actor, deletedAt, deletedBy, baseRev | **userId** |
| `FamilyMedia` | familyId, uid, actor | **userId** |

🔴 AGC **不允许删除字段**，且「对象类型创建成功后不支持修改字段类型 / 加密 / 敏感属性」，
所以这 2 张表**必须先删除**，再让导入重建。

**操作步骤（按顺序）：**

1. 对象类型列表 → `FamilyMember` 行 → **删除** → 确认；
2. 同样删除 `FamilyMedia`；
3. 此时列表应为空（共 0 条）；
4. 点右上角 **「导入」** → 选择 `CloudProgram/clouddb-import-13-objecttypes.json` → 确认；
5. 列表应变为 **13 条**。

> ⚠️ **删除对象类型会同时删除它在所有存储区（含旧备份区 `miyuanzupu`）里的数据**。
> 本项目已确认旧云备份不再需要，因此可以安全删除。
> 如果将来又需要旧数据，只能从本机 RDB 或导出的 JSON 文件重新上传。

#### ✅ 导入后核对

| 检查项 | 期望 |
|---|---|
| 对象类型总数 | 13 条 |
| `Family` 字段数 | 14 |
| `FamilyMember` 字段数 | 17（含 familyId / privateRef / graveRef / rev / deletedAt） |
| `FamilyGraveLocation` 字段数 | 19 |
| `FamilyPrivate` 字段数 | 8（privateId / familyId / uid / phone / wechat / residence / actor / updatedAt） |
| 随便点开一张表的权限 | 只有 Administrator 有 Read/Upsert/Delete；其余全空 |
| `FamilyGraveLocation` / `FamilyDirectory` 的 Authenticated | 有 **Read** |

---

### 5.3 13 个对象类型

字段格式：`字段名 : 类型(=主键) 默认值`

#### ① Family
```
familyId           : String  (=主键)
ownerUserId        : String   默认 ""
ownerUnionId       : String   默认 ""
title              : String   默认 ""
bookKey            : Integer  默认 0
rev                : Long     默认 0
aclVersion         : Integer  默认 1
inviteCode         : String   默认 ""
inviteExpireAt     : Long     默认 0
inviteRole         : String   默认 "VIEWER"
directoryEnabled   : Boolean  默认 false
directoryUpdatedAt : Long     默认 0
createdAt          : Long     默认 0
updatedAt          : Long     默认 0
```
索引：`index_inviteCode`

#### ② Membership（权限唯一真相源）
```
membershipId     : String  (=主键)    格式 {familyId}#{userId}
familyId         : String   默认 ""
userId           : String   默认 ""
role             : String   默认 ""   OWNER / EDITOR / VIEWER
status           : String   默认 ""   INVITED / ACTIVE / REVOKED / EXPIRED
branchRootUid    : String   默认 ""   认领分支根人物（空=全谱）
expireAt         : Long     默认 0    0=永久；门槛①默认 now+180天
nickName         : String   默认 ""
source           : String   默认 ""   CREATE / INVITE / ACCESS
joinedAt         : Long     默认 0
revokedAt        : Long     默认 0
updatedAt        : Long     默认 0
```
索引：`index_familyId`、`index_userId`

#### ③ FamilyMember（协作成员记录）
```
memberId     : String  (=主键)    格式 {familyId}#{uid}
familyId     : String   默认 ""
bookKey      : Integer  默认 0
uid          : String   默认 ""
name         : String   默认 ""
generation   : Integer  默认 1
parentId     : String   默认 ""
payload      : Text               只含公开字段，绝不含手机号/微信/现居地/墓地坐标
privateRef   : String   默认 ""
graveRef     : String   默认 ""
rev          : Long     默认 0
actor        : String   默认 ""
deleted      : Boolean  默认 false
deletedAt    : Long     默认 0
deletedBy    : String   默认 ""
baseRev      : Long     默认 0
updatedAt    : Long     默认 0
```
索引：`index_familyId`（familyId + rev）

#### ④ FamilyBook
```
bookId     : String  (=主键)    {familyId}#0
familyId   : String   默认 ""
bookKey    : Integer  默认 0
title      : String   默认 ""
payload    : Text              谱名/堂号/郡望/字派/谱序/家训/凡例
rev        : Long     默认 0
actor      : String   默认 ""
baseRev    : Long     默认 0
deleted    : Boolean  默认 false
updatedAt  : Long     默认 0
```

#### ⑤ ChangeRequest（待审变更）
```
requestId      : String  (=主键)
familyId       : String   默认 ""
bookKey        : Integer  默认 0
submitterId    : String   默认 ""
submitterName  : String   默认 ""
targetUid      : String   默认 ""
op             : String   默认 ""   ADD / UPDATE / DELETE_REQ / APPEND_TEXT
patchJson      : Text             字段级 diff
baseRev        : Long     默认 0
evidence       : Text
status         : String   默认 ""   PENDING / APPROVED / REJECTED / SUPERSEDED
reviewerId     : String   默认 ""
reviewNote     : Text
reviewedAt     : Long     默认 0
resultRev      : Long     默认 0
createdAt      : Long     默认 0
```
索引：`index_familyId_status`

#### ⑥ ChangeLog（审计流水，只追加）
```
logId            : String  (=主键)   {familyId}#{rev}#{seq}
familyId         : String   默认 ""
rev              : Long     默认 0
actor            : String   默认 ""
action           : String   默认 ""
targetMemberId   : String   默认 ""
summary          : String   默认 ""
payload          : Text
createdAt        : Long     默认 0
```
索引：`index_familyId_rev`

#### ⑦ FamilyMedia
```
mediaId     : String  (=主键)
familyId    : String   默认 ""
memberId    : String   默认 ""
uid         : String   默认 ""
type        : String   默认 ""   image / video
cloudPath   : String   默认 ""   {familyId}/{memberIdKey}/{fileName}
fileName    : String   默认 ""
size        : Long     默认 0
uploadedAt  : Long     默认 0
deleted     : Boolean  默认 false
actor       : String   默认 ""
```

#### ⑧ FamilyGraveLocation（🔴 公开可读：墓葬位置）
```
graveId     : String  (=主键)    {familyId}#{uid}
familyId    : String   默认 ""
uid         : String   默认 ""
personName  : String   默认 ""   冗余：公开读者读不到 FamilyMember
generation  : Integer  默认 0    冗余
bookTitle   : String   默认 ""   冗余
graveName   : String   默认 ""
lng         : Double   默认 0
lat         : Double   默认 0
altitude    : Double   默认 0
facing      : String   默认 ""
bearing     : String   默认 ""
routeNote   : String   默认 ""
photoRefs   : Text
visibility  : String   默认 "PUBLIC"    PUBLIC / FAMILY_ONLY
precision   : String   默认 "EXACT"     EXACT / BLURRED
rev         : Long     默认 0
actor       : String   默认 ""
updatedAt   : Long     默认 0
```
索引：`index_familyId`、`index_visibility`

🔴 **本表严禁加入任何活人信息**（手机号、微信、住址、生卒、父链…）。

#### ⑨ AccessRequest
```
requestId        : String  (=主键)
familyId         : String   默认 ""
applicantId      : String   默认 ""   由云函数按可信身份写入
applicantName    : String   默认 ""
kind             : String   默认 ""   VIEW_APPLY / JOIN_CLAIM
relationClaim    : Text
branchClaimUid   : String   默认 ""
evidence         : Text
grantedRole      : String   默认 ""
expireAt         : Long     默认 0
status           : String   默认 ""   PENDING / APPROVED / REJECTED / EXPIRED / CANCELLED
reviewerId       : String   默认 ""
reviewNote       : Text
reviewedAt       : Long     默认 0
createdAt        : Long     默认 0
rev              : Long     默认 0
```
索引：`index_familyId_status`、`index_applicantId`

#### ⑩ FamilyDirectory（🔴 公开可读：族谱黄页索引）
```
dirId            : String  (=主键)    直接等于 familyId（1 谱 1 行）
familyId         : String   默认 ""
surname          : String   默认 ""
region           : String   默认 ""
title            : String   默认 ""
branchSummary    : Text
memberCountBand  : String   默认 ""   只允许：0-50 / 50-100 / 100-500 / 500-1000 / 1000+
coverRef         : String   默认 ""
accessHint       : String   默认 ""
createdAt        : Long     默认 0
updatedAt        : Long     默认 0
rev              : Long     默认 0
actor            : String   默认 ""
```
索引：`index_surname`、`index_region`

🔴 **本表严禁出现任何人物数据**；且**只允许存在已上架的行**（下架 = 删除该行，云函数已实现）。

#### ⑪ FamilyTextSegment（P3 预留）
```
segmentId  : String  (=主键)
familyId   : String   默认 ""
memberId   : String   默认 ""
field      : String   默认 ""   biography / preface / familyRules
segOrder   : Integer  默认 0
text       : Text
actor      : String   默认 ""
rev        : Long     默认 0
createdAt  : Long     默认 0
```

#### ⑫ UserDevice（P3 预留）
```
deviceId  : String  (=主键)
userId    : String   默认 ""
pushToken : String   默认 ""
platform  : String   默认 ""
updatedAt : Long     默认 0
```

#### ⑬ FamilyPrivate（🔴 活人隐私字段，端侧永远不可读）
```
privateId : String  (=主键)    {familyId}#{uid}
familyId  : String   默认 ""
uid       : String   默认 ""
phone     : String   默认 ""
wechat    : String   默认 ""
residence : String   默认 ""
actor     : String   默认 ""
updatedAt : Long     默认 0
```

> 第 13 张表是「payload 脱敏」的物理落点：手机号/微信/现居地不能留在
> `FamilyMember.payload`，所以单独成表、单独配权限。

### 5.4 建表顺序

1. **Family → Membership → FamilyMember → FamilyBook**（P0 最小闭环）
2. **ChangeRequest → ChangeLog → FamilyPrivate**（P1 审核流）
3. **FamilyGraveLocation → AccessRequest → FamilyDirectory**（公开能力）
4. **FamilyMedia → FamilyTextSegment → UserDevice**（P2/P3）

---

## 6. 第 5 步：配置对象类型权限（🔴 最关键）

> ⚠️ **2026-10-27 实测更正**：AGC 控制台的权限项**不叫 Read，而叫 `query`**。
> 面板共 3 项：**`query`（查询） / `Upsert`（增改） / `Delete`（删除）**，
> 分别对应导入 JSON 里的 `Read` / `Upsert` / `Delete`。
> 下文凡出现「Read」的地方，都指的是控制台上的 **`query`**。



### 6.1 为什么不能偷懒

AGC 的 ACL 只有 `World / Authenticated / Creator / Administrator` 四类角色，
**无法表达「本家族成员」**。一旦给某张表开 `Authenticated: Read`，
**任何已登录用户**做一次不带过滤条件的 query 就能拉走**所有家族**的数据。

### 6.2 默认规则（11 张表适用）

| 控制台角色 | 权限（query / Upsert / Delete） |
|---|---|
| **所有人** | 全部不勾 |
| **认证用户** | **全部不勾** |
| **数据创建人** | **全部不勾** |
| **管理员** | **query / Upsert / Delete 全勾** |

适用：`Family`、`Membership`、`FamilyMember`、`FamilyBook`、`ChangeRequest`、`ChangeLog`、
`FamilyMedia`、`AccessRequest`、`FamilyTextSegment`、`UserDevice`、`FamilyPrivate`

### 6.3 🔴 唯一两个例外

| 表 | 所有人 | 认证用户 | 数据创建人 | 管理员 |
|---|---|---|---|---|
| `FamilyGraveLocation` | 不勾 | **只勾 query** | 不勾 | 全勾 |
| `FamilyDirectory` | 不勾 | **只勾 query** | 不勾 | 全勾 |

### 6.4 🔴 绝不要做的事

| 不要 | 后果 |
|---|---|
| 给 `FamilyMember` 的「认证用户」勾 `query` | 全库人物数据被任意登录用户爬走 |
| 给 `Family` 的「认证用户」勾 `query` | 谱主 ID + 加入码一起送人 |
| 给 `FamilyPrivate` 的「认证用户」勾 `query` | 活人隐私全裸 |
| 给 `Membership` 的「认证用户」勾 `query` | 成员名单泄露 |
| 给任何表的「数据创建人」勾 `Upsert` | 端侧可绕过云函数直接写，鉴权全部失效 |

---

## 7. 第 6 步：部署 23 个云函数

### 7.1 部署前

在 DevEco 云开发面板直接部署即可。npm install 会自动执行 `preinstall` 并生成每个函数的 `shared/` 与凭据文件，无需手工同步或打包 zip。

### 7.2 函数清单

| # | 函数 | 作用 | 批次 |
|---|---|---|---|
| 1 | family-create | 创建家族 | P0 |
| 2 | family-bootstrap | 首次全量分页发布 | P0 |
| 3 | family-join | 加入码加入 | P0 |
| 4 | family-acl-list | 成员列表 | P0 |
| 5 | family-acl-set | 角色/期限/轮换加入码 | P0 |
| 6 | family-list-mine | 我参与的家族 | P0 |
| 7 | change-submit | 提交变更审核 | P1 |
| 8 | change-list-pending | 待审列表 | P1 |
| 9 | change-review | 审核合入 | P1 |
| 10 | member-direct-write | 直写（谱主/分支内） | P1 |
| 11 | sync-pull | **唯一读取通道** | P0 |
| 12 | grave-update | 更新墓葬位置 | P1 |
| 13 | grave-list-public | 祖墓聚合（可选） | P1 |
| 14 | access-request | 申请查看/加入 | P1 |
| 15 | access-review | 审批访问申请 | P1 |
| 16 | access-list | 申请列表 | P1 |
| 17 | directory-upsert | 黄页上架/下架 | P1 |
| 18 | directory-search | 黄页搜索（可选） | P1 |
| 19 | family-private-get | 隐私字段（仅 OWNER） | P1 |
| 20 | media-record | 媒体索引 | P2 |
| 21 | media-list | 媒体列表 | P2 |
| 22 | user-device | 推送设备（P3） | P3 |

### 7.3 方式一：DevEco 部署

1. 打开 `CloudProgram/cloudfunctions/<函数名>/index.js`；
2. 右键 → **Deploy Cloud Function**；
3. 首次要求选择应用与运行时：
   - 应用：`com.zupu.ae86jay`
   - 运行时：**Node.js 18.x 或 20.x**
   - 内存 **500 MB**（控制台最低值），超时 **30 秒**

也可以右键 `cloudfunctions` 目录 → Deploy All。

### 7.4 方式二：AGC 控制台部署（DevEco 认不出云工程时用这个）

云开发 → 云函数 → 创建函数：

| 设置 | 值 |
|---|---|
| 函数名称 | 与 §7.2 表格**完全一致** |
| 运行时 | Node.js 18 / 20 |
| 入口 | `index.handler` |
| 内存 / 超时 | **500 MB** / 30 秒 |
| 触发器 | **HTTP 触发器**，认证类型 **云网关认证（cloudgw-client）** |

然后把 `CloudProgram/cloudfunctions/<函数名>/` 打成 zip（**必须包含 `node_modules/_zupu_shared`**）上传。

### 7.5 🔴 `authType` 必须是 `cloudgw-client`

每个函数的 `function-config.json` 已写好：

```json
{
  "name": "family-create",
  "version": "1.0.0",
  "memorySize": 500,
  "timeout": 30,
  "triggers": [
    { "type": "http", "properties": { "authType": "cloudgw-client", "methods": ["POST"] } }
  ]
}
```

部署后若控制台显示 `none` / `iam`，**必须手动改回 `cloudgw-client`**，
否则端侧调用报 `mismatched authType`。

### 7.6 可选环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `ZONE_NAME` | `miyuanfamily` | 协作存储区名 |
| `IDENTITY_FIELD_PATH` | 空 | §8 确认身份字段后填写，如 `headers.x-user-id` |
| `AGC_VERIFY_URL` | 空 | 方案②：AGC 服务端校验令牌接口 |
| `REV_CAS_ENABLED` | 空 | 云侧支持条件写时设为 `1` |

---

---

## 7.7 🔴 已定位并修复的三个线上故障（2026-10-28）

真机联调时连续暴露三个问题，均已修复并重新打包：

| # | 现象 | 根因 | 修复位置 |
|---|---|---|---|
| 1 | 端侧报「云函数 xxx 返回格式异常」 | `cloudFunction.call()` 的 `result.result` **是对象而非字符串**，端侧 `String(obj)` 得到 `"[object Object]"`，`JSON.parse` 必失败 | `AccountService.callFunction`：先判类型，字符串才 parse |
| 2 | 云函数报「云数据库 SDK 形态不符合预期」 | 误以为 SDK 导出 `databaseObject(typeName)`；真实 API 是 `cloud.database({zoneName}).collection(type)` | `_shared/db.js` 全量重写 |
| 3 | 云函数报「请填写谱名」 | 网关式 event 的业务参数在 `event.body`（JSON 串）里，旧代码只认 `event.value/params/data` | `_shared/index.js::extractParams` 改为多来源合并 |

### 真实 SDK 用法（务必记住）

```js
const { cloud } = require('@hw-agconnect/cloud-server');
const db  = cloud.database({ zoneName: 'miyuanfamily' });   // DatabaseConfig
const col = db.collection('Family');                        // CloudDBCollection
const q   = col.query().equalTo('familyId', id).and().greaterThan('rev', 0)
               .orderByAsc('rev').limit(100, 0);
const rows = await q.get();        // Promise<T[]>，直接是数组
await col.upsert(rows);            // 支持单个或数组
await col.delete(rows);            // 按主键删
```

### 排障开关

任选一个函数加环境变量 **`PROBE_EVENT=1`**，调用后到「监控日志」看：

```
[zupu][family-create] event={"type":"object","keys":["headers","body"],"shape":{...}}
```

只打键名与类型，值全部打码。确认问题后请把该变量删掉。

### 端到端自测（不需要真机）

`CloudProgram/tools/` 之外的本地验证方式：项目根执行

```powershell
node CloudProgram\tools\smoke-test.js   # 自动同步 shared 后执行全部冒烟测试
```

它会用**内存版 CloudDB 假 SDK** 跑通 22 个云函数里的核心链路（建家族 → 加入 → 发布 → 同步 →
提交审核 → 合入 → 审批访问 → 到期失效 → 撤销），当前 **35 项断言全部通过**。

---

## 7.8 部署后的自检清单

| 检查项 | 期望                                                                               |
|---|----------------------------------------------------------------------------------|
| 22 个函数都存在 | AGC 云函数列表 23 条                                                                   |
| 每个函数认证类型 | **API客户端鉴权（Client适用）**                                                           |
| 函数入口 | `index.handler`                                                                  |
| 运行时 | Node.js 18                                                                       |
| 函数体积 | 每包约 1.3 MB（含 `node_modules` 全量依赖，**不要删**）                                        |
| 关键依赖 | zip 内必须含 `node_modules/@hw-agconnect/cloud-server` 与 `node_modules/_zupu_shared` |

---

## 7.9 🔴 云函数访问云数据库所需的「项目凭据」（必做）

云函数里 `@hw-agconnect/cloud-server` 初始化 AGCClient 时，需要一份**项目级 API 客户端凭据**。
AGC 不会自动注入（`AGC_CONFIG` 环境变量为空），因此必须随包携带。

### 7.9.1 凭据从哪来

```
AGC 控制台 → 开发者管理 → 凭证 → 项目级凭证 → 「API 客户端凭证」→ 创建
  凭证名称：zupu-server
  项目：日常应用（projectId 101653523865445747）
  角色：APP管理员 / 管理员
→ 创建后点「下载」得到 JSON
```

**正确内容形如：**

```json
{
  "type": "project_client_id",
  "developer_id": "7235262",
  "project_id": "101653523865445747",
  "client_id": "…",
  "client_secret": "…",
  "configuration_version": "3.0",
  "region": "CN"
}
```

### 7.9.2 🔴 三种容易下错的文件

| 下到的文件 | 特征 | 是否可用 |
|---|---|---|
| **服务账号凭证** | 含 `private_key` / `token_uri` / `auth_uri` | ❌ 服务端 SDK 不支持 |
| API Key 凭证 | 只有一串 `DgED…` 密钥 | ❌ 不是凭据文件 |
| **API 客户端凭证** | 含 `"type": "project_client_id"` | ✅ **唯一正确** |
| `AppScope/resources/rawfile/agconnect-services.json` | `client_secret` 是 `[!00…]` 加密串 | ❌ 客户端凭据 |

### 7.9.3 放进工程并分发

```powershell
# 保存为 CloudProgram/agconnect-credential.json
# 之后执行 npm install 或直接在 DevEco 部署；preinstall 会校验 type 并复制到每个函数
```

### 7.9.4 凭据的三种来源（代码已全部支持）

`_shared/db.js` 按以下优先级初始化：

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | 环境变量 `AGC_CONFIG` | 平台注入的凭据**文件路径** |
| 2 | 随包文件 `agconnect-credential.json` | 本项目采用 |
| 3 | 环境变量 `PROJECT_CREDENTIAL` | 凭据 **JSON 内容**，落临时文件后使用 |
| 4 | SDK 默认实例 | 兜底 |

### 7.9.5 🔴 安全要求

`agconnect-credential.json` 含 `client_secret`，等同于服务端主密钥：

- ✅ 已在 `.gitignore` 排除（`CloudProgram/agconnect-credential.json`、`**/agconnect-credential.json`）
- ❌ 不要提交到任何仓库
- ❌ 不要放进客户端（`AppScope/`、`entry/`）
- ⚠️ 若怀疑泄露，在 AGC「API 客户端凭证」里删除重建

---

## 7.10 🔴 写入报 3037003「不含主键字段」的原因与修复

### 现象

```
创建家族失败：3037003：input data does not contain the primary key field
```

### 原因

`@hw-agconnect/cloud-server` 的写入路径（`insert` / `upsert` / `delete`）对参数有强类型要求：

| 操作 | 传字符串类型名 | 传普通对象 |
|---|---|---|
| `query()` | ✅ 可用（SDK 内部转 GenericObject） | — |
| `upsert()` / `delete()` | ❌ | ❌ 抛 3037003 |

写入时 SDK 会用 `convertTClass` 做类型转换，它要么要求记录是**实现了
`getFieldTypeMap/getClassName/getPrimaryKeyList/getIndexList/getEncryptedFieldList`
的类实例**，要么是 **`CloudDBZoneGenericObject`**。普通对象两条都不满足，
于是拿不到主键 → 3037003。

### 修复

`_shared/db.js` 新增 `toGeneric(typeName, row)`，写前把每行包装成通用对象：

```js
const G = require('@hw-agconnect/cloud-server').CloudDBZoneGenericObject;
const go = G.build('Family');
Object.keys(row).forEach(k => go.addFieldValue(k, row[k], k === primaryKey));
await db.collection('Family').upsert([go]);   // 或 delete([go])
```

主键名来自 `_shared/schema-meta.json`（由 `clouddb/objecttype/*.json` 生成，13 个类型）：

| 对象类型 | 主键 |
|---|---|
| Family | familyId |
| Membership | membershipId |
| FamilyMember | memberId |
| FamilyBook | bookId |
| ChangeRequest / AccessRequest | requestId |
| ChangeLog | logId |
| FamilyMedia | mediaId |
| FamilyGraveLocation | graveId |
| FamilyDirectory | dirId |
| FamilyTextSegment | segmentId |
| UserDevice | deviceId |
| FamilyPrivate | privateId |

### 配套脚本变化

`_shared/install-into-function.js` 会复制 `_shared` 下所有文件（含 `schema-meta.json`），
并校验、复制 AGC 项目凭据。

---

## 7.11 🔴 读取结果归一化（「成员权限未生效…状态 undefined」）

### 现象

```
读取失败：成员权限未生效（当前状态：undefined）
```

### 原因

`collection('Membership')` 传**字符串**类型名时，SDK 内部用 `CloudDBZoneGenericObject` 承载记录，
`query().get()` 返回的是**通用对象**而不是普通对象：

```js
row.status        // undefined ❌
row.getObject()   // { status: 'ACTIVE', ... } ✅
```

### 修复

`_shared/db.js` 的 `query()` 统一用 `toPlain()` 归一化：

```js
function toPlain(row) {
  if (typeof row.getObject === 'function') return row.getObject();
  if (typeof row.getFieldMap === 'function') { /* 按字段表还原 */ }
  return row;
}
```

| 方向 | 处理 |
|---|---|
| **写入** upsert / delete | `toGeneric()` 包装成 `CloudDBZoneGenericObject` |
| **读取** query / queryOne / getById / count | `toPlain()` 还原成普通对象 |

### 依赖完整性自检

若某个函数报 **「云数据库 SDK 未安装」**，多半是该函数的
`node_modules/@hw-agconnect/cloud-server` **不完整**（`npm install` 中途失败）。

完整的包应有 **211 个文件**，且必须存在：

```
node_modules/@hw-agconnect/cloud-server/index.js
node_modules/@hw-agconnect/cloud-server/package.json
node_modules/@hw-agconnect/cloud-server/cloud.js
```

自检命令：

```powershell
Get-ChildItem CloudProgram\cloudfunctions -Directory |
  Where-Object { $_.Name -ne '_shared' } | ForEach-Object {
    $p = Join-Path $_.FullName 'node_modules\@hw-agconnect\cloud-server'
    $ok = (Test-Path (Join-Path $p 'index.js')) -and (Test-Path (Join-Path $p 'cloud.js'))
    if (-not $ok) { Write-Host ("BROKEN: " + $_.Name) }
  }
```

修复：从完好的函数目录整包复制，或在该目录重新 `npm install`。

---

## 7.12 🔴 谱主被自己「审批」降级为只读（已修复）

### 现象

谱主对自己的族谱提交了「申请查看」，又自己点了通过，结果：

- 界面角色变成「只读成员」；
- 想改回来时，`family-acl-set` 要求 OWNER 身份，而自己已不是 OWNER → **死锁**；
- 但本地缓存的角色仍是 OWNER，于是「能编辑、能上传」，与云端权限不一致。

### 根因

`access-review` 审批通过时，用 `membershipId = {familyId}#{userId}` 写入 Membership。
谱主批准**自己**的申请时，这个 id 正好是他那条 `role=OWNER` 的记录 → **被覆盖成 VIEWER**。

### 三道互锁 + 自愈

| # | 位置 | 规则 |
|---|---|---|
| 1 | `access-request` | 已是 ACTIVE 成员（含谱主）→ 返回 `ALREADY_MEMBER`，不再建申请单 |
| 2 | `access-review` | `applicantId === reviewerId` → 拒绝，错误码 `self_review` |
| 3 | `access-review` | 目标行若已是 OWNER → **永不降级**（`keepOwner`） |
| 4 | `authz.effectiveMembership` | **自愈**：`Family.ownerUserId === userId` 但行角色不是 OWNER 时，自动改回 OWNER + ACTIVE + expireAt=0 并落盘 |

第 4 条是**修复存量数据**的关键：谱主无需手工改库，下次任意云函数调用就会自动恢复 OWNER。

### 端侧配套

| 改动 | 说明 |
|---|---|
| `requestAccess` 返回 `SUBMITTED / DUPLICATED / ALREADY_MEMBER` | 不再用「requestId 是否为空」猜状态 |
| `listMine` 回写角色 | 云端角色与本地不一致时同步回 `genealogy.family_role` 与 AppStorage |
| 申请提示语 | 「你已是该谱成员」「已有待审核的申请」分别提示 |

### 验证（本地冒烟测试已覆盖）

```
OK  谱主被降级后 sync-pull 仍可读(自愈)
OK  Membership 已自愈为 OWNER
OK  自愈后仍可执行 OWNER 级操作
OK  谱主申请查看被拒为 ALREADY_MEMBER
OK  谱主本人的申请单无法被自己审批（已阻断）
OK  审批后谱主仍是 OWNER
OK  谱主自审被拒绝
总计 42 项，通过 42，失败 0
```

### 部署后如何恢复自己

1. 重传 22 个云函数 zip（`authz.js` 在共享库里，**所有函数都受影响**）；
2. 装新 HAP；
3. 打开「我的家族」→ 触发一次 `family-list-mine` → 角色自动回到「谱主」。

---

## 7.13 族人唯一 ID 生成规则（端侧，不涉及云侧部署）

### 规则

| 项 | 规则 |
|---|---|
| 前缀 | **男 F / 女 M**，两类**各自独立编号** |
| 生成时机 | **选择性别后**才生成；进入「新增」时留空 |
| 默认位数 | 3 位（F001 / M001） |
| 增位 | 仅当编号本身超过 999 时增位（F1000） |
| 空号复用 | **优先复用最小空号**：删掉 F004 后再新增男丁 → 仍是 F004 |
| 手工填写 | 手工输入 ID 后不再自动改写；清空则恢复自动 |

### 修复前后对比

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 进入新增页 | 立刻显示 F001 | 留空，显示「ID 待生成」 |
| 已有 F001–F003，新增女丁 | M004（男女共用计数器） | **M001**（独立计数） |
| 删掉 F004 后新增男丁 | F005 | **F004**（复用空号） |
| 已有 F1000 | —— | 新增仍是 F001 风格，不出现 F0001 |

### 实现位置

| 文件 | 改动 |
|---|---|
| `util/IdGenerator.ets` | `next()` 按前缀独立统计 + 复用最小空号；`format()` 宽度只看当前编号 |
| `pages/PersonEdit.ets` | 新增 `uidAuto` 状态；`fill()` 不再预生成；性别切换时仅自动模式重算；手工输入即关闭自动；ID 为空时跳过唯一性校验（保存时由 addPerson 生成） |
| `service/GenealogyService.ets` | `addPerson()` 仍保留兜底：uid 为空时按性别生成 |

### 验证

```
OK 空              男 -> F001
OK 空              女 -> M001
OK F001            男 -> F002
OK F001,F002,F003  女 -> M001     ← 男女独立编号
OK F001,F002,F004  男 -> F003     ← 复用空号
OK F005            男 -> F001     ← 优先复用最小空号
OK [999个]         男 -> F1000    ← 自动增位
OK [1001个]        男 -> F1002
11 / 11 通过
```

---

## 7.14 「同步完成（离线待传 N 条）」是什么意思

### 结论

这不是矛盾，而是**旧文案把两件事拼在了一起**：拉取（pull）成功了，但推送（push）有 N 条没传上去。

修复后文案会明确区分：

| 实际情况 | 提示 |
|---|---|
| 推送 + 拉取都成功 | `同步完成` |
| 拉取成功，但有 N 条上传失败 | `已拉取云端更新，但 N 条本地上传失败：<原因>` |
| 拉取成功，N 条还在排队（未尝试/被跳过） | `已拉取云端更新，N 条本地变更仍待上传` |

### 为什么会残留

`FamilySyncService.flushOutbox()` 逐条推送 outbox：

| 结果 | 处理 | 是否计入「待传」 |
|---|---|---|
| 成功 | `markDone` → state=DONE | 否 |
| 可重试失败（网络/超时/500） | `markFailed(permanent=false)` → **state 仍为 PENDING** | **是** |
| 永久失败（无权/冲突/成环） | `markFailed(permanent=true)` → state=FAILED | 否（但计入 rejectedOutbox） |

旧代码把「可重试失败」吞掉了，只留 `result.message = '同步完成'`，
于是出现「同步完成 + 待传 N 条」这种自相矛盾的展示。

### 现在怎么处理

1. **重试**：可重试失败项仍是 PENDING，**下一次点同步会自动重试**；
2. **永久失败**：会在「待审变更」以外的冲突提示里体现，需要人工修正数据后重试；
3. 提示里的 `<原因>` 来自云函数返回（例如 `500 云数据库访问失败`、`403 当前角色无权`）。

### 常见原因对照

| 提示原因 | 含义 | 处理 |
|---|---|---|
| `403 当前角色（VIEWER）无权执行该操作` | 只读成员改本地数据 | 请谱主提升为编辑者 |
| `500 ...` | 云函数内部错误 | 看 AGC 云函数日志 |
| `409 已被他人修改` | rev 冲突 | 重新同步后再次编辑 |
| 超时/网络 | 断网或弱网 | 联网后再次同步即可 |

---

## 8. 第 7 步：验证云函数能拿到可信身份（P0 唯一单点风险）

### 8.1 为什么重要

官方明确「云函数业务免鉴权，开发云函数无需获取用户凭据」——
`cloudFunction.call` **默认不携带用户身份**。拿不到可信身份，就只能拒绝对所有人服务，
或者相信端侧自报 uid（= 把写权限公开）。

`_shared/identity.js` 已实现三级取法：

| 级别 | 做法 | 触发条件 |
|---|---|---|
| ① | 网关注入（cloudgw-client 校验后把身份放进 event） | 网关确实注入了身份字段 |
| ② | 端侧 `accessToken` → 云函数服务端校验 | 配了 `AGC_VERIFY_URL` |
| ③ | 端侧自报 uid | **不用于鉴权**，只记录日志 |

### 8.2 操作：打印一次 event

1. 编辑 `CloudProgram/cloudfunctions/family-list-mine/index.js`，函数体第一行临时加：

```js
log.info('[zupu][probe] event=' + JSON.stringify(event).substring(0, 2000));
```

2. 重新部署该函数；
3. 真机登录后进入「设置 → 我的家族」（会自动调用）；
4. AGC 控制台 → 云函数 → family-list-mine → 日志，找 `[zupu][probe]`；
5. 观察 event 结构，找网关放进去的身份字段，常见位置：

```
event.headers['x-user-id']
event.headers['x-hw-uid']
event.user.uid
event.auth.uid
```

### 8.3 结果处理

| 情况 | 处理 |
|---|---|
| 找到身份字段 | 给所有函数加环境变量 `IDENTITY_FIELD_PATH=<路径>`，填到 §13 实测记录 |
| 没找到 | 走方案②：配 `AGC_VERIFY_URL` |
| ②也不可用 | 临时 `TOKEN_CLAIM_HEADER=jwt:sub`，**必须真机验一次** |

确认后**删掉临时探针**并重新部署。

### 8.4 ✅ 验收点

- [ ] 真机调 `family-list-mine` 返回 `{ code: 200, data: { families: [...] } }`
- [ ] 未登录调用返回 `{ code: 401 }`
- [ ] 故意把 `params.userId` 改成别人 id，返回结果**不变**

---

## 9. 第 8 步：导出 schema.json 覆盖端侧

### 9.1 🔴 只能导出，禁止手写

`AppScope/resources/rawfile/schema.json` 必须由 DevEco/AGC **导出**得到。
手写（哪怕照抄字段）都会缺元数据，端侧报：

```
1008230002 Schema config error
```

### 9.2 操作

DevEco → 云数据库节点右键 → **Sync Cloud Resources / 同步云端资源**：

1. 选择 Zone：`miyuanfamily`；
2. 全选 13 个对象类型；
3. 目标：`AppScope/resources/rawfile/schema.json`；
4. 导出后核对：`objectTypes` 有 13 项，`FamilyGraveLocation` / `FamilyDirectory` 的
   Authenticated 有 `Read`。

> 若 DevEco 无法同时保留两个 Zone 的 schema，以**新 Zone 为准**；旧备份 Zone 的
> `FamilyMember / FamilyMedia` 在阶段 3 收紧权限时一并下线。

### 9.3 ✅ 验收点

- [ ] `schema.json` 的 `objectTypes` 数量 = 13
- [ ] App 能启动，日志无 `1008230002`
- [ ] `entry/src/main/ets/model/FamilyModels.ets` 每个类字段与 schema 一一对应

---

## 10. 第 9 步：回归验证清单

> 需要**两个华为账号**：A（谱主）、B（另一个账号，最好另一台设备）。

### 验证 1：创建家族 + 发布基线
A 登录 → 设置 → 我的家族 → 「创建云家族」→ 黄页询问选「暂不开放」→「发布当前族谱到云端」。

✅ `Family` 有 1 行、`FamilyMember` 行数 = 本地族人数、`Membership` 有 1 行 `role=OWNER`。

### 验证 2：🔴 未加入账号读不到任何人物数据
B 对 `FamilyMember` 做一次**不带过滤条件**的 query。

✅ 返回空 / 被拒（`2001015 permission denied`）；❌ 返回数据 → 立刻回 §6 检查权限。

### 验证 3：🔴 墓葬坐标确实公开
B（未加入任何家族）直接 query `FamilyGraveLocation`，并在 App 里打开「祭祖寻墓」。

✅ 能查到 A 发布的墓葬坐标。

### 验证 4：🔴 加入码只读到被授权的那一部谱
A 在「成员与访问申请」拿到加入码发给 B；B 在「我的家族 → 用加入码加入」。

✅ B 看到整部谱，角色「只读成员」；`Membership` 有 1 行 `role=VIEWER, status=ACTIVE`。

### 验证 5：编辑者提交 → 谱主审核 → 合入
A 把 B 提升为「编辑者」→ B 改某族人并保存（提示"已提交，等谱主审核后合入"）→
A 打开「待审变更」看到字段级 diff → 通过 → B 点「立即同步」。

✅ B 看到新值；`ChangeLog` 多一行；`Family.rev` +1。

### 验证 6：🔴 墓碑（一人删一人改）
B 离线删除某人 X → A 同时修改 X 并同步 → B 重新联网同步。

✅ 不出现幽灵人物，X 以墓碑标注（`deleted=true, deletedBy=A`），并给出冲突提示。

### 验证 7：🔴 门槛① 申请查看 → 审批 → 到期失效
C（第三个账号）在黄页搜到 A 的谱 → 「申请查看」→ A 审批通过 → C 同步能拉到数据 →
**在控制台把 C 的 `Membership.expireAt` 改成昨天** → C 再同步。

✅ 第 3 步能拉到；第 5 步返回 403「授权已到期」，`status` 自动变 `EXPIRED`（惰性失效生效）。

### 验证 8：🔴 撤销授权立即生效
A 把 B 的状态改为「撤销」→ B 再同步。✅ B 立刻拉不到数据（403）。

### 验证 9：🔴 黄页「下架 = 真删除」
A 在族谱黄页开启并填写 → C 能搜到 → A 关闭 → C 再搜。

✅ 关闭后完全搜不到；控制台 `FamilyDirectory` 该行**已不存在**（不是残留一行 `false`）。

### 验证 10：🔴 黄页与申请里没有人数据
B query `FamilyDirectory` 与 `AccessRequest`。

✅ 黄页只返回 `dirId/familyId/surname/region/title/branchSummary/memberCountBand/coverRef/accessHint`；
✅ `AccessRequest` 查询被拒。

### 验证 11：隐私字段只有谱主可见
A 在「我的家族 → 隐私字段」看到手机号；B 在任何界面都看不到别人的手机号/微信/现居地。

✅ A 能看到；B 看到空值（这是设计）。

### 验证 12（对照）：老 Zone 漏洞仍在
B query **老 Zone（`miyuanzupu`）** 的 `FamilyMember`。

⚠️ **预期仍能读到所有账号的备份人物数据**——方案 §八.2 第 2 步（收紧老 Zone 权限）尚未执行，
必须在协作只读路径（验证 4/7）稳定后再做（阶段 3）。

---

## 11. 第 10 步：阶段推进

| 阶段 | 内容 | 前置 |
|---|---|---|
| 已交付 | 云函数 + 端侧代码 | — |
| 阶段 1 | 执行本文 §2~§10 | — |
| 阶段 2 | 真机灰度：1~2 个真实家族试用 | 验证 1~11 全绿 |
| 阶段 3 | 🔴 收紧老 Zone 权限，旧邀请码统一下线 | 阶段 2 运行 ≥2 周 |
| 阶段 4 | P3：推送、长文分段、版本回滚 | 阶段 3 完成 |

> ⚠️ **对外表述纪律**：阶段 3 完成前，**不能对外宣称「族谱已经私密」**——
> 存量备份数据（老 Zone）仍对任意登录用户可读。

### 11.1 阶段 3 具体操作
1. 确认 `pages/SharedView.ets` 的「只读查看」入口 2 周无调用；
2. 云开发 → `miyuanzupu` Zone → `FamilyMember` → 权限设置 → 取消 `Authenticated` 的 `Read`；
3. `FamilyMedia` 同样操作；
4. 重新导出 `schema.json`；
5. 发补丁版本，更新说明写清「旧只读分享已升级为加入码加入」。

---

## 12. 常见报错对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| DevEco 提示「不包含项目」 | 打开的是含两个工程子目录的根目录 | 正常；或改为在 DevEco 里打开 `CloudProgram` 单独看云侧 |
| 点「同步」没反应、无进度条 | `hvigor-config.json5` 写错（`hvigorVersion` 应为 `modelVersion`） | 见 §3.4 |
| `The project structure and configuration need to be upgraded` | 同上 | 同上 |
| 端侧提示「云函数不存在」 | 函数没部署 / 名字拼错 | 回 §7，核对函数名 |
| 端侧提示「云函数认证类型不正确」 | `authType` 不是 `cloudgw-client` | 回 §7.5 |
| 端侧提示「云函数调用被拒绝：多为签名配置问题」 | AGC 未关联当前调试证书指纹 | AGC 项目设置 → 证书/指纹，加入调试证书 SHA-256 |
| 端侧提示「未登录或登录已失效」 | 云函数拿不到可信身份 | 回 §8 |
| `1008230002 Schema config error` | schema.json 与控制台不一致 | 回 §9 重新导出 |
| `2001015 permission denied` | 云函数写入被拒 | 检查 Administrator 权限三项全勾 |
| 云函数日志 `Cannot find module './shared'` | preinstall 未执行或部署包已过期 | 删除函数 `shared/` 后重新执行 npm install / 部署 |
| 云函数日志 `云数据库 SDK 未安装` | 函数依赖缺 `@hw-agconnect/cloud-server` | 在函数目录 `npm install` 后重新部署 |
| 云函数日志 `云数据库 SDK 形态不符合预期` | SDK 初始化方式与代码假设不同 | **只改 `_shared/db.js` 的 `ensureCloud()`**，改完重新执行 npm install / 部署 |
| 墓葬照片上传失败 `state:65` | 云存储 403 | 签名方式、云存储安全策略设「始终可读写」、AuthProvider 凭据 |
| 报「相差 N 米 > 50m」 | 就近优先规则 | 录入页填「位置变更依据」 |

---

## 13. 实测记录（操作时填写）

| 项目 | 实测结果 | 日期 |
|---|---|---|
| `CloudDev` 面板是否显示 22 个云函数 | | |
| 网关身份字段路径（`IDENTITY_FIELD_PATH`） | | |
| 云函数 SDK 初始化是否与 `_shared/db.js` 一致 | | |
| `rev` 是否支持条件写（`REV_CAS_ENABLED`） | | |
| `FamilyPrivate` 字段加密是否可用 | | |
| 云存储 403 是否已排除 | | |