# CloudProgram 目录结构详解

> 所属项目：觅源（Miyuan）
> 文档位置：codebase-docs/cloudprogram-structure.md
> 关联主文档：../codebase-structure.md

## 模块职责

CloudProgram 是觅源 App 的云侧工程，承载家族协作（Family/Zone）所需的 23 个云函数、一份零依赖共享库与 Cloud DB 对象类型定义。端侧对协作数据表没有直接读写权限，所有读写都经由云函数；共享库统一负责登录身份解析、Membership 鉴权、字段校验、rev 版本推进、隐私字段隔离与数据库访问。云函数在部署前通过各函数 `preinstall` 自动把 `_shared` 复制到函数内 `shared/`，因此各函数的业务代码只需 `require('./shared')`。

## 目录结构

```
CloudProgram/
├── clouddb/                          # Cloud DB 对象类型与数据入口定义（协作 Zone 的表结构来源）
│   ├── dataentry/                    # 数据入口配置，声明云侧可读写的对象类型集合
│   └── objecttype/                   # 13 张协作表的对象类型定义：Family、Membership、Person、ChangeRequest、ChangeLog、FamilyPrivate、FamilyGraveLocation、FamilyDirectory 等
├── cloudfunctions/                   # 全部云函数，一目录一函数（含部署配置、依赖锁与凭据）
│   ├── _shared/                      # 零依赖共享库：身份解析、Membership 鉴权、字段校验、rev 推进、隐私隔离、DB 访问、schema 元数据与安装脚本
│   ├── access-list/                  # 访问申请列表：我的申请（mode=mine）与谱主待审收件箱（mode=inbox）
│   ├── access-request/               # 提交访问申请：申请查看（VIEW_APPLY，180 天）与申请成为族人（JOIN_CLAIM），含幂等与频控
│   ├── access-review/                # 谱主审批访问申请：通过后只写一条 Membership（VIEWER/EDITOR）
│   ├── change-list-pending/          # 查询待审变更：OWNER 看全部，EDITOR 只看自己认领支系内的提交
│   ├── change-review/                # 谱主审核合入变更：baseRev 过期则置 SUPERSEDED，通过后字段级合并并推进 rev
│   ├── change-submit/                # 编辑者提交待审变更：只写 ChangeRequest(PENDING)，不直接改家族 rev，带频率限制与支系范围校验
│   ├── directory-search/             # 族谱黄页搜索：仅返回黄页索引字段，不含人物数据，不做 Membership 校验
│   ├── directory-upsert/             # 族谱黄页上架/下架：上架写目录行，下架物理删除目录行，字段白名单校验
│   ├── family-acl-list/              # 谱主查看成员列表与当前加入码
│   ├── family-acl-set/               # 谱主调整成员角色/支系/期限/状态或轮换加入码，ACL 变化推进 aclVersion
│   ├── family-bootstrap/             # 首次把本地全量族谱分页发布到云家族，支持限速、重试与断点续传
│   ├── family-create/                # 创建云家族并初始化谱元信息
│   ├── family-delete/                # 谱主解散云家族：确认谱名后按对象类型逐表清空再删 Family 行
│   ├── family-join/                  # 通过加入码加入云家族，按加入码生成 VIEWER/EDITOR Membership
│   ├── family-list-mine/             # 查看当前用户所属的全部云家族及角色
│   ├── family-private-get/           # 谱主读取家族隐私字段（手机号/微信/现居地），权限收窄到 OWNER
│   ├── grave-list-public/            # 公开墓葬查询：按关键字检索祖先墓葬，返回用于祭祖寻墓的公开数据
│   ├── grave-update/                 # 写入/更新公开墓葬记录，按字段回退规则保留已有值
│   ├── media-list/                   # 查询家族媒体资料清单（头像、相片、视频）元数据
│   ├── media-record/                 # 记录云存储媒体路径与元数据，含路径穿越（CWE-22）防护
│   ├── member-direct-write/          # 谱元信息直写与新增族人（op=ADD），云端缺记录时自动建档
│   ├── sync-pull/                    # 家族内数据唯一读取通道：增量拉取 ChangeLog 或全量分页快照
│   └── user-device/                  # 用户设备注册/注销，维护设备与登录态信息
├── tools/                            # 本地运维脚本：云函数 shared/ 同步与冒烟测试入口
├── cloud-config.json                 # 云函数部署配置（函数清单与运行参数）
├── package.json                      # 云侧工程依赖声明（TypeScript、@types/node）
└── package-lock.json                 # 云侧依赖锁定文件
```