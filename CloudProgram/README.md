# CloudProgram · 觅源家族协作云函数

> 对应 家族协作编辑设计方案.md §六（云函数接口）与 §五（数据模型）。
> 手动操作步骤见仓库根目录《AGC手动操作步骤方案.md》，这里只说明目录与代码约定。

## 目录

```
CloudProgram/
├── cloud-config.json          # 云函数清单（22 个）
├── tools/sync-shared.ps1      # 部署前把 _shared 同步到每个函数的 node_modules/_zupu_shared
├── clouddb/                   # 云数据库工程（DevEco 识别云侧工程的关键）
│   ├── db-config.json         # 存储区配置（cloudDBZoneName = miyuanfamily）
│   ├── clouddb_tables.json    # 表清单
│   ├── objecttype/            # 13 个对象类型定义（*.json）
│   └── dataentry/             # 数据条目（保持空）
└── cloudfunctions/
    ├── _shared/               # 共享库（不是云函数！零第三方依赖）
    │   ├── index.js           # 统一出口：createHandler / extractParams / getFamily
    │   ├── constants.js       # 对象类型名、角色、隐私字段、黄页白名单
    │   ├── core.js            # 返回码、BizError、参数解析、UUID、距离计算
    │   ├── identity.js        # §6.0 可信身份（网关注入 / 令牌校验）
    │   ├── authz.js           # Membership 鉴权 + 惰性到期失效 + 分支子树
    │   ├── rev.js             # 家族 rev 分配（CAS 可选，兜底宽松单调）
    │   ├── db.js              # 云数据库访问（唯一需要按真机 SDK 调整的文件）
    │   ├── validate.js        # 结构校验 + 黄页白名单
    │   ├── patch.js           # 字段级 diff 解析与应用
    │   ├── privacy.js         # payload 脱敏 / 墓葬行组装
    │   ├── members.js         # FamilyMember/FamilyBook 行组装
    │   └── human.js           # 人可读摘要
    └── <22 个云函数>/         # 每个目录：index.js + package.json + function-config.json
```

## 云函数清单（22 个）

| # | 函数 | 说明 | 批次 |
|---|---|---|---|
| 1 | family-create | 创建家族，服务端生成 familyId / 加入码 | P0 |
| 2 | family-bootstrap | 首次把本地全量谱分页发布（≤100 条/次，幂等） | P0 |
| 3 | family-join | 加入码加入（门槛②） | P0 |
| 4 | family-acl-list | 成员列表 + 当前加入码 | P0 |
| 5 | family-acl-set | 改角色/分支/期限/状态，轮换加入码 | P0 |
| 6 | family-list-mine | 我参与的全部家族与角色 | P0 |
| 7 | change-submit | 提交待审变更（分支子树校验 + 频率限制） | P1 |
| 8 | change-list-pending | 待审列表（OWNER 全看，EDITOR 只看本分支） | P1 |
| 9 | change-review | 审核合入（分配 rev + 成员/流水一批写） | P1 |
| 10 | member-direct-write | 直写（分支内、字段级 LWW、墓碑） | P2 |
| 11 | sync-pull | 家族内数据的唯一读取通道 | P0 |
| 12 | grave-update | 墓葬位置（50m 就近优先；FAMILY_ONLY 时真删公开行） | P1 |
| 13 | grave-list-public | 祖墓聚合查询（可选） | P1 |
| 14 | access-request | 申请查看 / 申请成为族人（门槛①③） | P1 |
| 15 | access-review | 审批访问申请（唯一动作 = 写 Membership） | P1 |
| 16 | access-list | 我的申请 / 谱主待审申请 | P1 |
| 17 | directory-upsert | 黄页上架/下架（下架 = 物理删除） | P1 |
| 18 | directory-search | 黄页搜索（只返回索引元数据） | P1 |
| 19 | family-private-get | 活人隐私字段（仅 OWNER） | P1 |
| 20 | media-record | 登记媒体索引（路径必须属于该家族） | P2 |
| 21 | media-list | 列出家族媒体索引 | P2 |
| 22 | user-device | 推送设备登记（P3 预留） | P3 |

## 约定

1. 零第三方依赖的共享库：_shared 只用 Node.js 内置模块；部署前执行 tools/sync-shared.ps1，
   把它复制到每个函数的 node_modules/_zupu_shared，保证每个函数目录自包含。
2. 每个写函数第一行都是 S.requireUserId(event, params)，绝不信任端侧自报 uid（§6.0）。
   例外只有 grave-list-public / directory-search，它们读的是本来就公开的对象类型，只要求已登录。
3. HTTP 触发器认证类型必须是 cloudgw-client（见各函数 function-config.json），
   否则调用报 mismatched authType，且云函数拿不到可信身份。
4. 统一返回结构：{ code, message, reason, data }，由 createHandler 统一包装。
5. 隐私红线：FamilyMember.payload 永远不含 phone/wechat/residence，也不含墓葬坐标
   （迁往 FamilyGraveLocation）。见 _shared/privacy.js。

## 需要按真机结果调整的唯一位置

_shared/db.js 的 ensureCloud()：云数据库在云函数侧的初始化方式以 DevEco 云侧模板为准
（对应方案 §十 P0 验证清单第 2 项）。若 SDK 形态与此不同，只改这一个文件即可。

## clouddb 目录说明

DevEco 的云插件通过 `CloudProgram/clouddb/db-config.json` 判断「这是一个可部署的云侧工程」
（见插件资源 `AGCconfig.properties`：`cloud.project.dir.second.level.name.db=clouddb`）。

- `objecttype/*.json`：13 个对象类型定义，与 `AppScope/resources/rawfile/schema.json` 保持一致；
- `db-config.json`：声明默认存储区 `miyuanfamily`；
- `dataentry/`：保持空（本项目不需要预置数据条目）。

> ⚠️ 若在 DevEco 里对 `clouddb` 点「Deploy」，会用这些定义**覆盖云端对象类型**。
> 云端 13 张表已建好，**不要重复部署 clouddb**；只部署 `cloudfunctions`。
