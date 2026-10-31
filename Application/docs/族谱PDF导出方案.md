# 觅源 · 族谱整本 PDF 导出方案

> 目标：把整部族谱（含谱序、世系、牒记谱文、家训等）在**端侧**渲染并生成一份可保存/可分享的 **PDF 文件**，入口放在「导入导出中心」。
>
> 分支：`1.02-huawei_yun` · DevEco SDK API 12 ~ 24 · Stage 模型

---

## 一、可行性结论（先说结论）

**完全可行，推荐「离屏 Canvas 渲染成图 → pdfService 组装成 PDF」的混合方案。**

HarmonyOS 的 `pdfService`（PDF Kit，API 12+，系统能力 `SystemCapability.OfficeService.PDFService.Core`）提供的是**文档级**操作能力：

- 能做的事：创建文档、增删/移动页、加背景图、水印、页眉页脚、书签、转图片；
- **不能做的事：没有「向页面上写入文字/矢量图形」的 API**（没有类似 `page.drawText()` 的能力，`PdfPage` 只有背景类接口）。

所以纯文字流式写 PDF 走不通，必须把每页内容先变成**图片**，再塞进 PDF 页面。这正是「Canvas 离屏渲染 → 截图 → 组 PDF」方案的由来。

三条候选路线对比：

| 路线 | 原理 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- | --- |
| A. 组件截图 + componentSnapshot | 直接把页面上可见的 UI 组件截图 | 实现最快 | 只能截**当前可见区域**，不能截滚动视口外内容；多页/超长谱无法完整导出 | ❌ 排除 |
| B. OffscreenCanvas 离屏渲染 + pdfService 组页 | 用离屏画布按 A4 尺寸逐页绘制（文字/线条/头像均为矢量绘制），转 PixelMap 存 JPEG/PNG，作为每页**背景图**写入 PDF | 内容矢量级清晰、页数不受限、可控制版式（页眉页脚、页码）、生成后仍可二次加文字水印/书签 | 渲染代码量中等（要自己排版换行）；图片页 PDF 文字不可检索/复制 | ✅ **推荐** |
| C. 服务端渲染 | App 上传 JSON，云端渲染 PDF 返回 | 端侧零渲染成本 | 引入后端依赖、延迟、隐私敏感数据上云 | ❌ 仅作备选（族谱含隐私，不推荐） |

**混合增强（方案 B 的进阶，v2 可选）：** 正文用 B 生成图片页；导出完成后，再对 PDF 调用 `addWatermark`（文字水印）、`addHeaderFooter`（页眉页脚）、`createBookmark`（按世代生成书签目录），这些是 pdfService 原生支持的，无需渲染。

---

## 二、技术栈与关键 API（均已对照官方文档核实）

### 2.1 模块清单

```typescript
import { pdfService } from '@kit.PDFKit';      // PDF 文档组装（API 12+）
import { image } from '@kit.ImageKit';         // ImagePacker：PixelMap → JPEG/PNG 编码
import { fileIo, picker } from '@kit.CoreFileKit'; // 文件读写 + 保存选择器（复用现有 ExportService 的用法）
import { common } from '@kit.ArkUI';           // UIAbilityContext
```

- `OffscreenCanvas` 是 ArkUI 全局构造器（`@kit.ArkUI` 体系），无需单独 import：
  `new OffscreenCanvas(width, height)`，`offCanvas.getContext('2d', settings)` 返回
  `OffscreenCanvasRenderingContext2D`，绘制接口与 Canvas 2D 上下文相同，**单位均为 vp**。

### 2.2 渲染链路（每页）

```
OffscreenCanvas(pageW, pageH)            // 离屏画布，尺寸 = PDF 页面对应的 vp 尺寸
  └─ OffscreenCanvasRenderingContext2D    // 绘制：fillText / measureText / rect / arc / roundRect / drawImage …
       └─ getPixelMap()                   // 画布像素 → image.PixelMap（接口 12+，Canvas 通用能力）
            └─ imagePacker.packToFile(pm, fd, { format: 'image/jpeg', quality: 92 })
                                          // PixelMap → JPEG 文件（11+；PNG 无 quality，文件大，仅封面用）
```

**要点与坑（来自官方文档说明）：**

1. `getPixelMap` 要求 Canvas 处于可见状态才会执行绘制指令队列 —— **离屏画布无此限制**（这正是选 OffscreenCanvas 的原因）；但要注意图形变换接口（translate/scale/rotate）与 `getPixelMap` 在不同帧执行时变换不生效，所以**先做完全部绘制（含变换），再单独一帧调 getPixelMap**，或干脆不用全局变换、直接算坐标。
2. 画布宽高**超过 8000 px 会退化为 CPU 渲染**，性能骤降 —— A4 竖版 2x 采样（约 1240×1754 px）远低于此线，安全。
3. `packToData(source: PixelMap, options)` 为 13+ 接口；**API 12 项目（本项目下限）请用 `packToFile`（11+）直接写文件 fd**，避免版本兼容问题。
4. ImagePacker 使用完毕后必须 `release()`；编码期间不要释放 PixelMap。
5. 中文字体：ArkUI Canvas 的 `font` 走系统字体（HarmonyOS Sans 内置中文），无需自带字体文件；如需宋体/楷体风格，可把字体文件打进资源后用 `CanvasRenderingContext2D` 的 `font` + `Font.registerFont`（12+）加载 —— v1 先用系统字体，够用。

### 2.3 PDF 组装链路

```
const doc = new pdfService.PdfDocument();
doc.createDocument(pageWpt, pageHpt);      // 单位：Points（1 inch = 72 pt）。A4 = 595.3 × 841.9 pt
// 逐页：
const page = doc.insertBlankPage(i, pageWpt, pageHpt);
const bg: pdfService.BackgroundInfo = new pdfService.BackgroundInfo();
bg.imagePath = 该页渲染出的图片沙箱路径;
bg.scale = 1.0;  bg.opacity = 1.0;  bg.isOnTop = false;
bg.verticalAlignment = BACKGROUND_ALIGNMENT_TOP;   // 铺满整页（图片尺寸与页面一致即可）
bg.horizontalAlignment = BACKGROUND_ALIGNMENT_LEFT;
doc.addBackground(bg, i, i, true, true);
doc.saveDocument(沙箱输出路径);              // 保存后文件才生效
doc.releaseDocument();                      // 必须释放，否则后续 loadDocument 会冲突
```

**要点与坑：**

1. `insertBlankPage(index, w, h)` 的 index 必须 **< 总页数**（新文档为 0 页时只能插第 0 页），因此生成多页时要**在正确的位置逐页追加**：第 0 页直接插 0，之后每页插入到 `pageCount` 处。
2. `saveDocument` 是同步接口，**文档不可同时读写** —— 若目标是覆盖同名文件，需先写临时路径再 `fileIo` 拷贝覆盖（官方示例如此）。
3. `addBackground` 是**耗时操作**（逐页遍历），页数多时建议放 `taskpool` 子线程处理（pdfService 对象本身需确认可跨线程 —— v1 先主线程同步做，A4 十几页内可接受；v2 大谱再评估线程化）。
4. 输出到**沙箱临时目录**（`context.tempDir` / `filesDir/exports/`，复用 `ExportService.writeTemp` 的目录约定），完成后走现有 `DocumentViewPicker.save()` 让用户选保存位置，再用 `fileIo.copyFileSync` 拷过去 —— 与现有 JSON/CSV 导出的保存体验完全一致。
5. 进阶能力（v2 可选，均为原生接口）：`addWatermark(TextWatermarkInfo)` 文字水印（支持字体/旋转/透明度）、`addHeaderFooter` 页眉页脚、`createBookmark` 按世代建书签、`insertPageFromDocument` 合并多个子文档（最大单次 1000 页）、`convertToImage` 反向验证。

---

## 三、PDF 版式设计（默认 A4 竖版，2 倍采样）

### 3.1 页面参数

| 项 | 值 | 说明 |
| --- | --- | --- |
| 页面尺寸 | 595.3 × 841.9 pt（A4 竖版） | v2 可加 A5 / 16 开选项 |
| 渲染采样 | 2x（约 1240 × 1754 px） | 平衡清晰度与内存；手机屏幕外打印 2x 足够 |
| 页边距 | 上 60pt / 下 60pt / 左右 56pt | 上下各留 1 个页眉页脚条（32pt 高） |
| 正文区域 | 宽 483pt，高 721pt | 排版计算基准 |
| 正文字号 | 11pt（行高 1.7） | 世系图/表格 9pt |
| 页面结构 | 页眉：谱名 + 章节名；页脚：页码 | 由绘制层直接画进画布（比 v2 再叠 PDF 页眉页脚更稳） |

### 3.2 文档结构（页序）

```
P1  封面      谱名（大字）· 姓氏 · 堂号/郡望 · 始祖 · 导出日期 · 族众统计一行
P2  谱序      book.preface（自动换行，超长跨页）
P3  凡例/家训  book.editingNotes + book.familyRules
P4  字派谱    book.generationPoem（大字横排，可居中）
P5  世系图    按默认谱式渲染整棵树（缩放适配页面宽度）：
              欧式/苏式/宝塔式/现代式均可用 Canvas 矢量绘制
              （世系图绘制复用 TreeBuilder/TreeLayout 的布局数据 + 简化重绘）
              树过宽时按世代切成多页横向拼接
P6+ 牒记谱文  按世代分章：
              每章标题「第 X 世」单独一行（跨页续排）
              每人一条：姓名（粗）· 世/字派（右对齐）· 配偶行 · 正文行
              一人条尽量不跨页（放不下则整条移到下页）
              头像：有 avatar 的在条目前画 40pt 圆角头像（drawImage）
末页 尾页     「觅源 · 鸿蒙族谱」+ 导出时间 + 隐私声明行
```

> 说明：现有 `DieRecord.ets` 是 UI 组件，无法直接截图导出；但 `ExportService.toMarkdown()` 已实现了同样的「按世序逐人成条」文本拼装逻辑（配偶描述、字派、生卒、籍贯、职业、生平），**PDF 排版器直接复用这段文案逻辑**，只是把「一行一行 Markdown」换成「在 Canvas 上按版式规则绘制」，避免两套规则漂移。

### 3.3 排版核心规则

1. **自动换行**：用 `ctx.measureText()` 逐字/逐词测宽切行（中文按字符切即可），行宽 = 正文区宽 − 首行缩进。
2. **段落/条目跨页**：维护一个「当前 y 游标」，每条绘制前预估高度（行数×行高 + 固定行高），超页就 `finishPage()` 开新页并重新画页眉。
3. **隐私**：与现有导出一致提供「含隐私 / 脱敏」开关 —— 脱敏时手机号、微信号不绘制（`ExportService.fieldOf` 已有此判定，直接复用）。
4. **头像**：`avatar` 存的是应用沙箱/URI 路径，用 `image.createImageSource(uri).createPixelMap()` 解码后 `drawImage`；解码失败静默跳过该头像。
5. **深色模式**：PDF 固定浅色版式（打印场景），不受 App 深色模式影响。

---

## 四、代码结构（新增/改动文件）

```
entry/src/main/ets/
├── service/
│   ├── PdfExportService.ets        [新增] PDF 导出主服务（约 400 行）
│   │     - exportPdf(people, book, opts, onProgress) : Promise<string>  // 返回沙箱路径
│   │     - 内部：分页排版引擎 + 每页 OffscreenCanvas 绘制 + packToFile + pdfService 组页
│   ├── ExportService.ets           [小改] 抽出 toMarkdown 的文案拼装为可复用静态方法
│   │     （spouseMarkdown、buildParagraph 的文案部分 → 供 PdfExportService 复用，UI 组件不动）
├── view/
│   └── PdfExportSheet.ets          [新增] 导出参数弹层：
│         - 隐私开关（默认脱敏）
│         - 是否包含封面/世系图/头像（默认全含）
│         - 进度条 + 取消（生成期间）
└── pages/
    └── ImportExport.ets            [小改] 「导出」区新增一行
          ExportRow('PDF 成册', '封面+谱序+世系图+牒记，可直接打印或分享', 'PDF', () => this.doExportPdf())
          doExportPdf(): 弹参数层 → PdfExportService.exportPdf → saveAsFile 保存对话框
```

进度反馈：`onProgress(0~1)` 按「已渲染页数 / 总页数」上报（总页数在排版阶段一次性算出，因为分页规则确定）。

**错误处理**：`createDocument`/`saveDocument` 返回 false、`packToFile` 抛错、头像解码失败等统一 try/catch，失败 toast 并清理临时文件；任何一页失败即中止（不做半截 PDF）。

---

## 五、性能与内存估算（以 100 人 / 10 世代为例）

| 环节 | 估算 | 说明 |
| --- | --- | --- |
| 每页画布 | 1240×1754 px ≈ 8.7 MB（RGBA） | 一次只存活一页画布，渲染完即释放 |
| 每页 JPEG | 约 80~200 KB | quality 92；100 人牒记约 15~25 页，合计 < 5 MB |
| PDF 文档 | 与图片同量级 | 背景图模式 |
| 总耗时 | 约 3~8 秒 | 大头在 JPEG 编码；主线程同步执行 + 进度条可接受 |

> 500 人以上的大谱：单页图片数多、总耗时可到 30s+。v2 优化项：`taskpool` 子线程渲染、quality 降到 85、头像降级为不绘制。**v1 先保 200 人内流畅**，超过 200 人时弹层内提示「谱较大，导出时间较长」。

---

## 六、风险清单

| 风险 | 等级 | 应对 |
| --- | --- | --- |
| `getPixelMap` 在离屏画布上的行为与可见 Canvas 有差异（帧时序） | 中 | 渲染与取图分两次任务队列执行（绘制完 `await` 一帧再取）；实现时先写最小验证页 |
| `insertBlankPage` 对空文档/页序边界（index 必须 < 总页数） | 低 | 严格按「第 0 页插 0，其后插 pageCount」实现，单测覆盖 1 页/多页 |
| `addBackground` 图片尺寸与页面 pt 不一致导致缩放偏差 | 中 | 图片宽高固定 = 页面 px（2x），scale 设 1.0，铺满对齐左上角；用 `convertToImage` 反向抽检 |
| API 12 下限下 `packToData` 不可用 | 低 | 全链路只依赖 `packToFile`（11+） |
| 大谱主线程卡顿 | 低 | v1 加人数阈值提示；v2 线程化 |
| 中文竖排/繁体需求 | 低 | 不做；v1 仅横排简体中文 |

---

## 七、实施计划（v1）

1. **T1 · 最小链路验证（1 个文件草稿即可）**：OffscreenCanvas 画一段中文 + 一个圆 → getPixelMap → packToFile 出 JPEG → 单页 PDF 背景 → saveDocument 出 PDF；确认中文渲染与图片铺页对齐。
2. **T2 · 排版引擎**：分页器 + 封面/谱序/字派/家训页；复用 toMarkdown 文案逻辑。
3. **T3 · 牒记主体**：按世代分章、逐人条目、跨页不拆条、头像、脱敏开关。
4. **T4 · 世系图页**：基于 TreeBuilder/TreeLayout 数据绘制默认谱式（先做欧式横轴，最易适配 A4；其余谱式 v2）。
5. **T5 · UI 接入**：ImportExport 新增入口 + 参数弹层 + 进度 + 保存对话框；临时文件清理。
6. **T6 · 验证**：20 人演示谱 + 200 人生成谱各导出一次，检查版式/跨页/脱敏/头像/页码。

> v2 备选增强（不阻塞 v1）：文字水印（addWatermark）、世代书签（createBookmark）、A5/16开、五谱式全量世系图、子线程渲染、导出后一键分享（ShareService 已有）。

