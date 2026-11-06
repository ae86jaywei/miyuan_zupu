# GitCode 推送指南

## 一、当前状态

已完成：
- `.gitignore` 重写（覆盖依赖、构建产物、证书、IDE、截图、云函数产物与凭据）
- 已取消跟踪：`node_modules`（18399 个文件）、`entry/oh_modules`（118 个）、`zhengshu/`（9 个，含签名私钥）、`build/`、`.vscode/`
- 工作区文件全部保留，未被删除

## 二、被忽略的内容

| 类别 | 忽略规则 | 原因 |
|---|---|---|
| 依赖 | `**/node_modules/`、`**/oh_modules/` | 80 MB+，`npm install` / DevEco 可重建 |
| 构建产物 | `**/build/`、`**/.hvigor/`、`/preview` | 每次编译重新生成 |
| **签名与密钥** | `zhengshu/`、`**/*.p12`、`**/*.p7b`、`**/*.csr`、`**/*.jks`、`**/*.keystore`、`**/*.pem`、`**/*.key`、`**/*.cer` | **私钥泄露 = 他人可伪造签名** |
| 云函数产物 | `CloudProgram/dist/` | 临时上传包（28.9 MB），可重打包 |
| **AGC 凭据** | `CloudProgram/agconnect-credential.json`、`**/agconnect-credential.json` | 含 `client_secret` |
| IDE | `/.idea/`、`/.vscode/`、`/.codeartsdoer/` | 个人配置 |
| 本地配置 | `**/local.properties` | 本机 SDK 路径 |
| 临时文件 | `tmp_*`、`*.log`、`**/.DS_Store` | 临时产物 |
| 测试素材 | `远程真机测试截图/` | 6.8 MB 截图 |

## 三、提交并推送

```powershell
cd <项目根目录>

# 1) 提交「取消跟踪 + 忽略规则」这次变更
git add -A
git commit -m "chore: 忽略依赖/构建产物/签名证书/AGC凭据，减少仓库体积"

# 2) 添加 GitCode 远端（首次）
git remote add gitcode https://gitcode.com/<你的用户名>/<仓库名>.git
# 若已有远端：
# git remote -v

# 3) 推送
git push gitcode 1.01:main
```

> 分支当前是 `1.01`；上面命令把它推到 GitCode 的 `main`。若想同名推送：
> `git push gitcode 1.01`

## 四、🔴 必须注意：历史提交里仍有证书

第 3 节只清理了**当前索引**，但提交 `005c3a1` 里**已经包含了 `zhengshu/`（含 `miyuan.p12` 私钥）**。
一旦推送到 GitCode，这份历史就会公开。

二选一：

### 方案 A（推荐，最省事）：换签名证书
1. DevEco → File → Project Structure → Signing Configs → 取消自动签名，重新生成新证书；
2. 重新配置 `build-profile.json5` 的 `storeFile` / `keyAlias` / 密码；
3. 旧证书即使泄露也无法给你的新包签名。

### 方案 B：重写历史（仓库还没推过时可用）
```powershell
pip install git-filter-repo
git filter-repo --path zhengshu --invert-paths
git remote add gitcode https://gitcode.com/<用户名>/<仓库名>.git
git push gitcode 1.01:main
```

⚠️ `filter-repo` 会重写所有提交哈希，若已有其他人协作请先通知。

### 若只想把仓库设为**私有**
GitCode 支持私有仓库。私有仓库下证书泄露风险可控，但**仍建议按方案 A 换证书**。

## 五、`build-profile.json5` 里的口令

```json5
"storeFile": "./zhengshu/miyuan.p12",
"storePassword": "<REDACTED>",
"keyAlias": "miyuan",
"keyPassword": "<REDACTED>"
```

- 口令已从本文档脱敏，切勿再把真实口令写进任何会被提交的文件；
- 建议通过本地 `local.properties` 或 CI Secret 注入，`build-profile.json5` 只保留占位符；
- 换证书后这里会一并更新，风险自然消除。

---

生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm')
