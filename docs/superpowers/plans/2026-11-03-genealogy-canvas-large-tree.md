# 族谱画布大树渲染优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让欧式/苏式谱在 1000~5000 人规模下仍能完整浏览、平移可达四角、60fps 左右流畅拖动且不崩溃。

**Architecture:** 采用“布局一次算、按视口裁剪、只渲染可见卡片、大数据分级”的四层模型：数据层不向 UI 深拷贝树；布局层用带版本号的单例缓存；视口层用纯函数计算内容可视矩形与平移边界；渲染层只创建可视区（含缓冲区）内的组件，超出阈值自动进入宗支总览。

**Tech Stack:** HarmonyOS ArkTS / ArkUI（API 24）、现有 `GenealogyService` + `PersonNode`、`EuLayout` / `SuLayout`。

## Global Constraints

- 目标分支：`1.02-huawei_yun`，不修改云函数与 CloudDB schema。
- 不改变五种谱式的视觉语义（欧式左→右、苏式父→子、配偶红双线、朱砂+鎏金配色）。
- 所有新增/修改的 `.ets` 必须通过 ArkTS 严格检查：禁止 `any`、禁止未声明类型的对象字面量、禁止在 UI 组件中做 O(N) 以上的重复计算。
- 单屏任何时刻创建的卡片组件数 ≤ 250（含缓冲区）。
- 平移/缩放过程中不得重新执行 `EuLayout.compute` / `SuLayout.compute`（只允许首次进入、切换谱式、数据版本变化时各一次）。
- 平移边界必须能到达内容四角；不得再出现硬编码的 `320 / 240` 上限。
- 不通过 `@Prop` 传递 `PersonNode[]`（该结构含 father/mother/spouse 环，ArkUI 深拷贝会递归爆栈）。
- 性能验收以中端手机（如 Mate 60，非模拟器）为准。

## 实施状态（2026-11-03）

已完成：
- Task 1 视口数学与平移边界纯函数（`service/TreeViewport.ets`），Node 断言验证通过。
- Task 2 布局缓存（`service/TreeLayoutCache.ets`，按宗支 uid + revision 隔离）。
- Task 3 视口裁剪（`service/TreeCuller.ets`、`EuTree`、`SuTree`），线段增加稳定 `id`。
- Task 4 TreeCanvas 数据传递与边界修复（移除 `roots/people` 深拷贝，缓尺寸驱动边界，世代索引缓存）。
- 额外修复：`TreeMiniCard` 不再接收 `@Prop PersonNode`；`PagodaTree` 不再接收 `@Prop rows: PersonNode[][]`。

未实施（等待真机结果）：
- Task 5 连线 Canvas 化（当前仍用可见 Row，视口内数量已受控）。
- Task 6 大树宗支总览、Task 7 其余谱式懒加载、Task 8 性能埋点。

验证限制：当前环境没有 HarmonyOS SDK / `hvigorw`，无法编译与真机运行；仅完成纯函数断言与静态走查。下一步需在 DevEco Studio 编译后按 4.1/4.3 清单实测。

实现相对计划的差异（以代码为准）：
- 多宗支精确裁剪：`EuTree`/`SuTree` 新增 `contentTop`（该支在屏幕上的起点），`TreeCanvas` 预计算 `branchTops`，并把宗支标题高度计入起点；
- 边界升级为 `ViewportMath.clampScreenOffset`，`canvasW/canvasH` 统一存“屏幕尺寸”，避免标题/间隔不随 zoom 缩放造成的边界误差；`clampOffset` 保留为内容尺寸版；
- `TreeMiniCard` 的扁平化字段与 `PagodaTree` 的 `rootUids` 改造已并入 Task 3 的 Step 0。

---

## 一、问题定位（现状证据）

| 编号 | 现象 | 代码位置 | 根因 |
| --- | --- | --- | --- |
| P1 | 一次 build 内重复整树布局 | `components/tree/EuTree.ets:30,36,44,58,59,65`；`SuTree.ets:30,36,44,58,59,65` | `canvas()` 是普通方法，build 中被调用 5~6 次，每次 `EuLayout.compute` / `SuLayout.compute` 全量重算 |
| P2 | 平移/缩放每帧全量重建组件 | `view/TreeCanvas.ets:295-308`、`EuTree.ets:36-56` | `offsetX/offsetY` 每次 `onActionUpdate` 都改 `@Link`，触发子组件 build；线段 key 含坐标（`EuTree.ets:42`），坐标一变全部销毁重建 |
| P3 | 无视口裁剪，整棵树一次性挂载 | `EuTree.ets:36-56`、`SuTree.ets:36-56`、`PagodaTree.ets:42`、`ModernTree.ets:139`、`TreeCanvas.ets:175` | 每个族人一张卡（6~8 个 Text + shadow），每条线一个 Row；500~1000 人即数千节点 |
| P4 | `@Prop` 传整棵树导致深拷贝环状结构 | `pages/Index.ets:451`、`TreeCanvas.ets:22`、`EuTree.ets:13`、`SuTree.ets:13` | `PersonNode` 的 `father/mother/spouse/children` 互为引用，ArkUI `@Prop` 深拷贝会递归/爆栈，人数越多越容易崩 |
| P5 | 平移边界被重置为 0 后不再恢复 | `TreeCanvas.ets:61-64,246-248,263-265,324-335` | `onRootsChanged` 把 `canvasW/canvasH` 清 0；之后若组件尺寸没变，`onAreaChange` 不再触发，`canvasW` 永远 0 → `clampX` 上限只剩 160，表现为“拖到边界只看到几个人” |
| P6 | 边界公式含硬编码上限 | `TreeCanvas.ets:327,334` | `Math.min(..., 320)` / `Math.min(..., 240)` 把正向可拖距离写死，与内容宽度无关 |
| P7 | 缩放与平移变换顺序不明确 | `TreeCanvas.ets:281` + `EuTree.ets:60` | 父级 `scale(centerX:0,centerY:0)` + 子级 `translate` 叠加，视觉位移 = offset × zoom，但边界按未乘 zoom 的 offset 计算，缩小后拖不到右下角 |
| P8 | 世代索引每次 build 重建 Map 且逐项再查 | `TreeCanvas.ets:101-113,120-121` | `groups()`/`groupLabels()` 每次 build 调 `groupByGeneration()`，`GenerationIndex` 内又对每一项调用 `this.groups()[idx]`，复杂度 O(G×N) |
| P9 | 多宗支共享一份偏移与尺寸 | `TreeCanvas.ets:216-272` | 每个宗支单独一个 `EuTree`/`SuTree`，但 `canvasW` 取最大、`canvasH` 由外层实测；垂直偏移对所有宗支同时生效，边界与视觉不一致 |

**结论：** 崩溃与卡顿不是单一渲染问题，而是“布局重复计算（P1）+ 全量组件（P3）+ 每帧全量 diff（P2）+ 环状深拷贝（P4）”叠加；边界只显示几个人的直接原因是 P5/P6/P7。

---

## 二、目标架构

```
GenealogyService (单一数据源, version)
        │  gpVersion 变化
        ▼
TreeCanvas  ── 只持有 rootUids、viewport、版本号 ──┐
        │                                          │
        ▼                                          ▼
TreeLayoutCache (单例, 版本号 key)          ViewportMath (纯函数)
        │  EuCanvas / SuCanvas                    │ contentRect / clampOffset
        ▼                                          ▼
EuTree / SuTree ── 只渲染 visibleBoxes / visibleLines ── TreeMiniCard
        │
        └─ 人数 > 阈值 或 zoom < 0.4 → 宗支总览（聚合卡）
```

**关键原则**

1. **布局只算一次**：`TreeLayoutCache` 以 `version + style + cardWidth + dense + rootUid` 为 key，命中直接返回同一对象。
2. **组件数只与视口有关**：`contentRect` 把屏幕偏移换算为内容坐标，裁剪加 1 屏缓冲。
3. **数据不进 `@Prop`**：`TreeCanvas` 只向子组件传 `rootUid: string` 与 `layoutVersion: number`，子组件从单例取树。
4. **边界由内容与视口推导**：`clampOffset` 纯函数，四角可达。
5. **大树分级**：超过阈值自动聚合宗支，点击下钻，保证首屏永远 < 250 个组件。

---

## 三、任务分解

### Task 1: 视口数学与平移边界纯函数

**Files:**
- Create: `Application/entry/src/main/ets/service/TreeViewport.ets`
- Test: `Application/entry/src/test/ets/test/TreeViewport.test.ets`（若仓库未启用单测，见 Step 2 的替代验证）

**Interfaces:**
- Produces:
  - `class ViewRect { x: number; y: number; w: number; h: number; intersects(x,y,w,h): boolean }`
  - `class ViewportMath { static contentRect(offsetX: number, offsetY: number, viewW: number, viewH: number, zoom: number, margin: number): ViewRect }`
  - `class ViewportMath { static clampOffset(value: number, contentSize: number, viewSize: number, zoom: number, pad: number): number }`

- [ ] **Step 1: 写失败用例**

```ts
// Application/entry/src/test/ets/test/TreeViewport.test.ets
import { describe, it, expect } from '@ohos/hypium';
import { ViewRect, ViewportMath } from '../../../main/ets/service/TreeViewport';

export default function treeViewportTest(): void {
  describe('TreeViewport', (): void => {
    it('contentRect_maps_screen_to_content', 0, (): void => {
      // 内容 1000x2000，视口 400x800，偏移 -100/-200，缩放 0.5
      const r: ViewRect = ViewportMath.contentRect(-100, -200, 400, 800, 0.5, 0);
      expect(r.x).assertEqual(200);
      expect(r.y).assertEqual(400);
      expect(r.w).assertEqual(800);
      expect(r.h).assertEqual(1600);
    });

    it('clampOffset_reaches_four_corners', 0, (): void => {
      // 内容 3000x6000，视口 400x800，缩放 1，pad 0
      expect(ViewportMath.clampOffset(-99999, 3000, 400, 1, 0)).assertEqual(-2600);
      expect(ViewportMath.clampOffset(99999, 3000, 400, 1, 0)).assertEqual(0);
      expect(ViewportMath.clampOffset(-99999, 6000, 800, 1, 0)).assertEqual(-5200);
      expect(ViewportMath.clampOffset(99999, 6000, 800, 1, 0)).assertEqual(0);
    });

    it('clampOffset_centers_small_content', 0, (): void => {
      // 内容比视口小：左右各留一半空白
      expect(ViewportMath.clampOffset(0, 200, 400, 1, 0)).assertEqual(100);
      expect(ViewportMath.clampOffset(99999, 200, 400, 1, 0)).assertEqual(100);
    });

    it('intersects_uses_half_open_interval', 0, (): void => {
      const r: ViewRect = new ViewRect(0, 0, 100, 100);
      expect(r.intersects(99, 99, 10, 10)).assertEqual(true);
      expect(r.intersects(100, 0, 10, 10)).assertEqual(false);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

在 DevEco Studio 中右键该测试文件 → Run；或命令行（若已安装 SDK）：

```bash
hvigorw test -p module=entry@default -p product=default
```

Expected: FAIL，提示 `TreeViewport` 模块不存在。

> 替代验证：仓库当前无 `entry/src/test` 与 `@ohos/hypium` 依赖。若不想引入测试基建，把上述断言改写为 `console.info` 的自检函数，在 `EntryAbility.onCreate` 中执行一次；但必须保留断言值，不得省略。

- [ ] **Step 3: 实现**

```ts
// Application/entry/src/main/ets/service/TreeViewport.ets

/** 内容坐标系中的可视矩形（单位 vp） */
export class ViewRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;

  constructor(x: number = 0, y: number = 0, w: number = 0, h: number = 0) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }

  intersects(x: number, y: number, w: number, h: number): boolean {
    return x < this.x + this.w && x + w > this.x &&
      y < this.y + this.h && y + h > this.y;
  }
}

/**
 * 视口数学。
 *
 * 变换约定（Task 3 会按此改造组件结构）：
 *   屏幕坐标 = 内容坐标 × zoom + offset
 * 因此内容可视矩形 = (-offset / zoom, 视口尺寸 / zoom)。
 * 旧实现把 translate 放在 scale 内部，位移会被二次缩放，禁止沿用。
 */
export class ViewportMath {
  static contentRect(offsetX: number, offsetY: number, viewW: number, viewH: number,
    zoom: number, margin: number): ViewRect {
    const z: number = zoom > 0 ? zoom : 1;
    const w: number = viewW / z + margin * 2;
    const h: number = viewH / z + margin * 2;
    return new ViewRect(-offsetX / z - margin, -offsetY / z - margin, w, h);
  }

  /**
   * 平移边界。
   * - 内容大于视口：offset ∈ [viewW - contentW×zoom, 0]
   * - 内容小于视口：居中，offset = (viewW - contentW×zoom) / 2
   * - pad 为允许露出的背景留白（默认 24vp）
   */
  static clampOffset(value: number, contentSize: number, viewSize: number,
    zoom: number, pad: number): number {
    const z: number = zoom > 0 ? zoom : 1;
    const scaled: number = contentSize * z;
    if (scaled <= viewSize) {
      return (viewSize - scaled) / 2;
    }
    const min: number = viewSize - scaled - pad;
    const max: number = pad;
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Expected: 4 个用例全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add Application/entry/src/main/ets/service/TreeViewport.ets Application/entry/src/test
git commit -m "feat(tree): 新增视口数学与平移边界纯函数"
```

---

### Task 2: 布局缓存（消除重复 compute）

**Files:**
- Create: `Application/entry/src/main/ets/service/TreeLayoutCache.ets`
- Modify: `Application/entry/src/main/ets/service/TreeLayout.ets`（仅导出类型，无逻辑改动）

**Interfaces:**
- Consumes: `EuLayout.compute(roots, cardWidth, rowHeight, colGap, showSpouse, startY): EuCanvas`；`SuLayout.compute(roots, cardWidth, dense, showSpouse): SuCanvas`
- Produces:
  - `class TreeLayoutCache { static getInstance(): TreeLayoutCache; invalidate(): void; eu(rootKey: string, roots, cardWidth, rowHeight, showSpouse, startY): EuCanvas; su(rootKey: string, roots, cardWidth, dense, showSpouse): SuCanvas }`
  - `rootKey` 为宗支根 uid（单支渲染时必传）；多宗支共享一个 `EuCanvas` 会导致互相串图，禁止省略。

- [ ] **Step 1: 实现缓存**

```ts
// Application/entry/src/main/ets/service/TreeLayoutCache.ets
import { PersonNode } from '../model/PersonNode';
import { EuCanvas, EuLayout, SuCanvas, SuLayout } from './TreeLayout';

/**
 * 布局缓存：同一宗支 + 同一显示参数只计算一次。
 *
 * 用 Map 而不是单个字段：欧式/苏式按宗支拆成多个 EuTree/SuTree 实例，
 * 每个实例有自己的 rootUid，单字段缓存会让第二支拿到第一支的坐标。
 */
export class TreeLayoutCache {
  private static instance: TreeLayoutCache | null = null;
  private euMap: Map<string, EuCanvas> = new Map<string, EuCanvas>();
  private suMap: Map<string, SuCanvas> = new Map<string, SuCanvas>();
  private revision: number = 0;
  private static readonly MAX_ENTRIES: number = 64;

  static getInstance(): TreeLayoutCache {
    if (TreeLayoutCache.instance === null) {
      TreeLayoutCache.instance = new TreeLayoutCache();
    }
    return TreeLayoutCache.instance;
  }

  invalidate(): void {
    this.revision = this.revision + 1;
    this.euMap.clear();
    this.suMap.clear();
  }

  eu(rootKey: string, roots: PersonNode[], cardWidth: number, rowHeight: number,
    showSpouse: boolean, startY: number): EuCanvas {
    const key: string = rootKey + '|' + this.revision.toString() + '|' +
      cardWidth.toString() + '|' + rowHeight.toString() + '|' +
      showSpouse.toString() + '|' + startY.toString();
    const hit: EuCanvas | undefined = this.euMap.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const canvas: EuCanvas = EuLayout.compute(roots, cardWidth, rowHeight, 30, showSpouse, startY);
    if (this.euMap.size >= TreeLayoutCache.MAX_ENTRIES) {
      this.euMap.clear();
    }
    this.euMap.set(key, canvas);
    return canvas;
  }

  su(rootKey: string, roots: PersonNode[], cardWidth: number,
    dense: boolean, showSpouse: boolean): SuCanvas {
    const key: string = rootKey + '|' + this.revision.toString() + '|' +
      cardWidth.toString() + '|' + dense.toString() + '|' + showSpouse.toString();
    const hit: SuCanvas | undefined = this.suMap.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const canvas: SuCanvas = SuLayout.compute(roots, cardWidth, dense, showSpouse);
    if (this.suMap.size >= TreeLayoutCache.MAX_ENTRIES) {
      this.suMap.clear();
    }
    this.suMap.set(key, canvas);
    return canvas;
  }
}
```

- [ ] **Step 2: 接入数据变更失效**

在 `view/TreeCanvas.ets` 增加（`refreshRootUids` 在 Task 4 提供；本步骤先只做失效与偏移归零，避免依赖未完成的方法）：

```ts
@StorageProp('gpVersion') @Watch('onDataVersionChanged') dataVersion: number = 0;

onDataVersionChanged(): void {
  TreeLayoutCache.getInstance().invalidate();
  this.offsetX = 0;
  this.offsetY = 0;
}
```

> `canvasW/canvasH` 在 Task 4 才会移除 `onRootsChanged`，本步骤不要提前引用不存在的字段。
> Task 4 会复用这条 `@StorageProp('gpVersion')` 声明并扩展回调，不要重复添加第二个同名属性。

Expected: 新增族人、导入、同步后，下一次 build 使用新布局；同一次 build 内多次取用返回同一对象。

- [ ] **Step 3: 验证对象复用**

在 `EuTree.build()` 中计算 `const canvas: EuCanvas = TreeLayoutCache.getInstance().eu(this.rootUid, ...)`，随后打印：

```ts
hilog.debug(0x0000, 'TreePerf', 'layoutReuse boxes=%{public}d lines=%{public}d',
  canvas.boxes.length, canvas.lines.length);
```

Expected: 同一帧内多条日志的 `boxes/lines` 数量一致且只出现一次布局日志（可在 `EuLayout.compute` 首行加 `hilog.debug` 计数）；两个宗支的 `boxes` 数量不同，说明 key 隔离生效。

- [ ] **Step 4: 提交**

```bash
git add Application/entry/src/main/ets/service/TreeLayoutCache.ets Application/entry/src/main/ets/view/TreeCanvas.ets
git commit -m "perf(tree): 新增布局缓存并接入数据版本失效"
```

---

### Task 3: EuTree / SuTree 视口裁剪 + 变换顺序修正

**Files:**
- Create: `Application/entry/src/main/ets/service/TreeCuller.ets`
- Modify: `Application/entry/src/main/ets/service/TreeLayout.ets`（`LineSeg` 增加稳定 `id`）
- Modify: `Application/entry/src/main/ets/components/tree/EuTree.ets`
- Modify: `Application/entry/src/main/ets/components/tree/SuTree.ets`
- Modify: `Application/entry/src/main/ets/components/tree/TreeMiniCard.ets`（移除 `@Prop node: PersonNode`）
- Modify: `Application/entry/src/main/ets/components/tree/PagodaTree.ets`（移除 `@Prop rows: PersonNode[][]`）
- Delete: 无

**Interfaces:**
- Consumes: `TreeLayoutCache.eu()/su()`、`ViewportMath.contentRect()`、`ViewRect.intersects()`
- Produces:
  - `LineSeg` 新增字段 `id: number`
  - `class TreeCuller { static euBoxes(boxes: EuBox[], view: ViewRect): EuBox[]; static suBoxes(boxes: SuBox[], view: ViewRect): SuBox[]; static lines(lines: LineSeg[], view: ViewRect): LineSeg[] }`
  - `EuTree` / `SuTree` 新增 `@Prop viewWidth: number`、`@Prop viewHeight: number`、`@Prop zoom: number`、`@Prop rootUid: string`、`@Prop layoutVersion: number`
  - `TreeMiniCard` 改为接收 `person: Person`、`spouseText: string`、`spouseUid: string`、`childCount: number`、`descendants: number`
  - `PagodaTree` 改为接收 `rootUids: string[]` 与 `layoutVersion: number`

- [ ] **Step 0: 清除 TreeMiniCard / PagodaTree 的环状 @Prop（崩溃根因）**

`TreeMiniCard.ets` 删除 `@Prop node: PersonNode`，改为：

```ts
@Prop person: Person = new Person();
@Prop spouseText: string = '';
@Prop spouseUid: string = '';
@Prop childCount: number = 0;
@Prop descendants: number = 0;
```

`EuTree` / `SuTree` 的调用处改为：

```ts
TreeMiniCard({
  person: box.node.person,
  spouseText: box.node.spouseText(),
  spouseUid: box.node.spouse === null ? '' : box.node.spouse.uid,
  childCount: box.node.children.length,
  descendants: box.node.descendants,
  cardWidth: box.w,
  cardHeight: box.h,
  highlight: box.node.uid === this.highlightUid,
  dense: this.dense,
  onTapPerson: (uid: string): void => { this.onTapPerson(uid); }
})
```

`PagodaTree.ets` 删除 `@Prop rows: PersonNode[][]`，改为：

```ts
@Prop @Watch('onChanged') rootUids: string[] = [];
@Prop @Watch('onChanged') layoutVersion: number = 0;
@State rows: PersonNode[][] = [];
```

在 `aboutToAppear` 与 `onChanged` 中从 `GenealogyService.getInstance().getRoots()` 按 `rootUids` 重建 rows；`TreeCanvas` 调用改为：

```ts
PagodaTree({
  rootUids: this.rootUids,
  layoutVersion: this.dataVersion,
  highlightUid: this.highlightUid,
  compact: this.isNarrow(),
  onTapPerson: (uid: string): void => { this.onTapPerson(uid); }
})
```

Expected: `grep -rn "@Prop.*PersonNode"` 在组件属性中不再有结果（EuTree/SuTree 内部的局部变量不算）。

- [ ] **Step 1: 实现裁剪器与稳定线段 id**

```ts
// Application/entry/src/main/ets/service/TreeCuller.ets
import { EuBox, LineSeg, SuBox } from './TreeLayout';
import { ViewRect } from './TreeViewport';

const LINE_PAD: number = 2;

/** 只保留与视口相交的元素；返回新数组，调用方负责缓存 */
export class TreeCuller {
  static euBoxes(boxes: EuBox[], view: ViewRect): EuBox[] {
    const out: EuBox[] = [];
    for (let i: number = 0; i < boxes.length; i = i + 1) {
      const b: EuBox = boxes[i];
      if (view.intersects(b.x, b.y, b.w, b.h)) {
        out.push(b);
      }
    }
    return out;
  }

  static suBoxes(boxes: SuBox[], view: ViewRect): SuBox[] {
    const out: SuBox[] = [];
    for (let i: number = 0; i < boxes.length; i = i + 1) {
      const b: SuBox = boxes[i];
      if (view.intersects(b.x, b.y, b.w, b.h)) {
        out.push(b);
      }
    }
    return out;
  }

  static lines(lines: LineSeg[], view: ViewRect): LineSeg[] {
    const out: LineSeg[] = [];
    for (let i: number = 0; i < lines.length; i = i + 1) {
      const s: LineSeg = lines[i];
      const x: number = Math.min(s.x1, s.x2) - LINE_PAD;
      const y: number = Math.min(s.y1, s.y2) - LINE_PAD;
      const w: number = Math.abs(s.x2 - s.x1) + LINE_PAD * 2;
      const h: number = Math.abs(s.y2 - s.y1) + LINE_PAD * 2;
      if (view.intersects(x, y, w, h)) {
        out.push(s);
      }
    }
    return out;
  }
}
```

- [ ] **Step 2: 给 LineSeg 增加稳定 id**

`TreeLayout.ets` 中修改：

```ts
export class LineSeg {
  /** 稳定唯一 id：裁剪后数组下标会变化，不能作为 ForEach key */
  id: number = 0;
  x1: number = 0;
  y1: number = 0;
  x2: number = 0;
  y2: number = 0;
  red: boolean = false;
}
```

所有 `lines.push(...)` 之前统一赋 id。为减少改动点，在每个 `compute()` 内新增一个局部函数，并替换原有的 `pushLine` 调用：

```ts
const attach = (s: LineSeg): LineSeg => {
  s.id = canvas.lines.length;
  canvas.lines.push(s);
  return s;
};
```

`pushLine()` / `pushDoubleLine()` 内部改为接收 `canvas.lines` 与下一个 id：

```ts
function pushLine(lines: LineSeg[], x1: number, y1: number, x2: number, y2: number): void {
  const s: LineSeg = new LineSeg();
  s.id = lines.length;
  s.x1 = x1;
  s.y1 = y1;
  s.x2 = x2;
  s.y2 = y2;
  s.red = false;
  lines.push(s);
}
```

`pushDoubleLine()` 中两条线分别赋值 `a.id = lines.length; lines.push(a);` 与 `b.id = lines.length; lines.push(b);`。`EuLayout.compute` 中直接 `canvas.lines.push(spine)` 的那一处（约 378 行）改为 `spine.id = canvas.lines.length; canvas.lines.push(spine);`。

- [ ] **Step 3: 改造 EuTree（替换整个文件）**

```ts
// Application/entry/src/main/ets/components/tree/EuTree.ets
import { PersonNode } from '../../model/PersonNode';
import { EuBox, EuCanvas, LineSeg } from '../../service/TreeLayout';
import { TreeLayoutCache } from '../../service/TreeLayoutCache';
import { TreeCuller } from '../../service/TreeCuller';
import { ViewRect, ViewportMath } from '../../service/TreeViewport';
import { TreeMiniCard } from './TreeMiniCard';
import { Theme } from '../../theme/Theme';
import { GenealogyService } from '../../service/GenealogyService';

/**
 * 欧式谱画布。
 * 变换约定：屏幕 = 内容 × zoom + offset（外层 translate，内层 scale）。
 * 只渲染视口内（含 1 屏缓冲）的卡片与连线。
 */
@Component
export struct EuTree {
  @Prop @Watch('onViewportChanged') rootUid: string = '';
  @Prop @Watch('onViewportChanged') layoutVersion: number = 0;
  @Prop cardWidth: number = 112;
  @Prop highlightUid: string = '';
  @Prop dense: boolean = false;
  @Prop showSpouse: boolean = true;
  @Prop @Watch('onViewportChanged') viewWidth: number = 0;
  @Prop @Watch('onViewportChanged') viewHeight: number = 0;
  @Prop @Watch('onViewportChanged') zoom: number = 1;
  @Link @Watch('onViewportChanged') offsetX: number;
  @Link @Watch('onViewportChanged') offsetY: number;
  @State visibleBoxes: EuBox[] = [];
  @State visibleLines: LineSeg[] = [];
  @State contentW: number = 0;
  @State contentH: number = 0;
  private lastViewKey: string = '';
  onTapPerson: (uid: string) => void = (uid: string): void => {};
  onSize: (w: number, h: number) => void = (w: number, h: number): void => {};

  aboutToAppear(): void {
    this.refresh();
  }

  private rowHeight(): number {
    return this.dense ? 66 : 78;
  }

  private root(): PersonNode | null {
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    for (let i: number = 0; i < roots.length; i = i + 1) {
      if (roots[i].uid === this.rootUid) {
        return roots[i];
      }
    }
    return null;
  }

  private canvas(): EuCanvas {
    const r: PersonNode | null = this.root();
    const roots: PersonNode[] = r === null ? [] : [r];
    return TreeLayoutCache.getInstance().eu(this.rootUid, roots, this.cardWidth, this.rowHeight(),
      this.showSpouse, 6);
  }

  private viewKey(): string {
    return this.rootUid + '|' + this.offsetX.toString() + '|' + this.offsetY.toString() + '|' +
      this.viewWidth.toString() + '|' + this.viewHeight.toString() + '|' +
      this.zoom.toString() + '|' + this.layoutVersion.toString();
  }

  /** 只做裁剪，不做布局；同一视口 key 下重复调用直接返回 */
  private refresh(): void {
    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return;
    }
    const key: string = this.viewKey();
    if (key === this.lastViewKey) {
      return;
    }
    this.lastViewKey = key;
    const canvas: EuCanvas = this.canvas();
    this.contentW = canvas.width;
    this.contentH = canvas.height;
    const view: ViewRect = ViewportMath.contentRect(this.offsetX, this.offsetY,
      this.viewWidth, this.viewHeight, this.zoom, this.viewWidth);
    this.visibleBoxes = TreeCuller.euBoxes(canvas.boxes, view);
    this.visibleLines = TreeCuller.lines(canvas.lines, view);
    this.onSize(canvas.width, canvas.height);
  }

  onViewportChanged(): void {
    this.refresh();
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.visibleLines, (seg: LineSeg) => {
          Row()
            .width(Math.max(Math.abs(seg.x2 - seg.x1), 1.5))
            .height(Math.max(Math.abs(seg.y2 - seg.y1), 1.5))
            .backgroundColor(seg.red ? Theme.primary : Theme.goldLight)
            .position({ x: Math.min(seg.x1, seg.x2), y: Math.min(seg.y1, seg.y2) })
        }, (seg: LineSeg) => 'ln_' + seg.id.toString())

        ForEach(this.visibleBoxes, (box: EuBox) => {
          TreeMiniCard({
            node: box.node,
            cardWidth: box.w,
            cardHeight: box.h,
            highlight: box.node.uid === this.highlightUid,
            dense: this.dense,
            onTapPerson: (uid: string): void => {
              this.onTapPerson(uid);
            }
          })
            .position({ x: box.x, y: box.y })
        }, (box: EuBox) => 'bx_' + box.node.uid)
      }
      .width(this.contentW)
      .height(this.contentH)
      .scale({ x: this.zoom, y: this.zoom, centerX: 0, centerY: 0 })
    }
    .width(this.contentW * this.zoom)
    .height(this.contentH * this.zoom)
    .translate({ x: this.offsetX, y: this.offsetY })
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((): void => {
      this.refresh();
    })
  }
}
```

> 关键点：
> - `@Watch` 可以修饰 `@Link` 与 `@Prop`，因此 offset/zoom/视口变化都会触发一次裁剪，而不会重新布局。
> - `onSize` 每次 `refresh` 都可能调用，父级必须做“相同值不赋值”判断，否则会形成 state 回环。
> - 线段 key 必须使用稳定 id（见 Step 2 的 `LineSeg.id`），不能用裁剪数组下标，否则视口移动时全部线重建。

- [ ] **Step 4: 改造 SuTree（与 EuTree 同构）**

`SuTree.ets` 按 Step 3 同样的结构替换，差异只有：
- `canvas()` 调用 `TreeLayoutCache.getInstance().su(this.rootUid, roots, this.cardWidth, this.dense, this.showSpouse)`
- `TreeCuller.suBoxes(...)`
- 卡片 key 用 `'su_bx_' + box.node.uid`
- `rowHeight` 不参与 Su 布局
- 同样需要 `@Prop @Watch('onViewportChanged') rootUid/viewWidth/viewHeight/zoom/layoutVersion` 与 `@Link @Watch('onViewportChanged') offsetX/offsetY`

- [ ] **Step 5: 验收**

1. 1000 人欧式谱：拖动 10 秒连续记录 `hilog` 中 `visibleBoxes.length`，应稳定在 20~250，不得出现 1000。
2. 拖动过程中在 `EuLayout.compute` 首行加计数日志，应只在进入/切谱式/数据变化时出现。
3. 缩放到 20% 后拖到右下角，最后一位族人可见。

- [ ] **Step 6: 提交**

```bash
git add Application/entry/src/main/ets/service/TreeCuller.ets Application/entry/src/main/ets/components/tree/EuTree.ets Application/entry/src/main/ets/components/tree/SuTree.ets
git commit -m "perf(tree): 欧式/苏式改为视口裁剪渲染并修正变换顺序"
```

---

### Task 4: TreeCanvas 数据传递与边界修复

**Files:**
- Modify: `Application/entry/src/main/ets/view/TreeCanvas.ets:20-373`
- Modify: `Application/entry/src/main/ets/pages/Index.ets:446-462`

**Interfaces:**
- Consumes: `GenealogyService.getInstance().getRoots()`、`TreeLayoutCache`、`ViewportMath.clampOffset()`
- Produces: `TreeCanvas` 不再接收 `roots/people`，只读 `gpVersion`

- [ ] **Step 1: 移除环状深拷贝并建立 rootUids**

`TreeCanvas` 删除：

```ts
@Prop @Watch('onRootsChanged') roots: PersonNode[] = [];
@Prop people: Person[] = [];
```

替换为：

```ts
@StorageProp('gpVersion') @Watch('onDataVersionChanged') dataVersion: number = 0;
@State rootUids: string[] = [];
@State peopleCount: number = 0;
```

新增初始化与版本回调（`aboutToAppear` 里调用一次）：

```ts
aboutToAppear(): void {
  this.refreshRootUids();
  this.centerSuIfReady();
}

private refreshRootUids(): void {
  const svc: GenealogyService = GenealogyService.getInstance();
  const roots: PersonNode[] = svc.getRoots();
  this.rootUids = roots.map((r: PersonNode): string => r.uid);
  this.peopleCount = svc.getPeople().length;
  this.rebuildCanvasSize();
}

onDataVersionChanged(): void {
  TreeLayoutCache.getInstance().invalidate();
  this.refreshRootUids();
  this.offsetX = 0;
  this.offsetY = 0;
}
```

同时修改原来依赖 `this.roots/this.people` 的三处：

```ts
// centerSuIfReady()
if (!this.pendingCenter || this.style !== TreeStyle.SU || this.rootUids.length === 0) {
  return;
}
this.pendingCenter = false;
const first: PersonNode[] = GenealogyService.getInstance().getRoots();
const cx: number = suRootCenterX([first[0]], this.cardWidth(), this.isNarrow());

// 空态判断（build 内）
if (this.peopleCount === 0) {
  EmptyHint({ icon: '🌱', title: '族谱暂无人物', desc: '点击右下角“＋”创建始祖，开启家族记录' })
}

// buildRows()：把 this.roots 换成 GenealogyService.getInstance().getRoots()
```

`Index.ets` 的 `TreeCanvas({...})` 删除 `roots` 与 `people` 两行；`ForEach` 改为遍历 `this.rootUids`，子组件用 `rootUid` 定位宗支。分支标题所需的姓名与后代数也从服务取，不再依赖 `@Prop`：

```ts
private rootName(uid: string): string {
  const p: Person | null = GenealogyService.getInstance().getPerson(uid);
  return p === null ? '' : p.name;
}

private rootDescendants(uid: string): number {
  const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
  for (let i: number = 0; i < roots.length; i = i + 1) {
    if (roots[i].uid === uid) {
      return roots[i].descendants;
    }
  }
  return 0;
}
```

```ts
ForEach(this.rootUids, (uid: string, ri: number) => {
  Column() {
    if (this.rootUids.length > 1) {
      Row() {
        Text('宗支 ' + (ri + 1).toString() + '：' + this.rootName(uid))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.primary)
        Text('后代 ' + this.rootDescendants(uid).toString() + ' 人')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ bottom: Spacing.S })
    }
    EuTree({
      rootUid: uid,
      layoutVersion: this.dataVersion,
      cardWidth: this.cardWidth(),
      dense: this.isNarrow(),
      showSpouse: true,
      viewWidth: this.viewW,
      viewHeight: this.viewH,
      zoom: this.zoom,
      offsetX: $offsetX,
      offsetY: $offsetY,
      highlightUid: this.highlightUid,
      onTapPerson: (id: string): void => {
        this.onTapPerson(id);
      },
      onSize: (w: number, h: number): void => {
        this.collectSize(w, h);
      }
    })
  }
  .width('100%')
  .alignItems(HorizontalAlign.Start)
  .margin({ bottom: Spacing.XXL })
}, (uid: string) => 'root_' + uid)
```

> `SuTree` 分支同样把 `rootUid`、`layoutVersion`、`viewWidth/viewHeight`、`zoom` 传入；`offsetX/offsetY` 仍用 `$offsetX/$offsetY`。

- [ ] **Step 2: 用缓存尺寸驱动边界**

```ts
@State canvasW: number = 0;
@State canvasH: number = 0;

/** 只在数据/谱式/宽度变化时调用，不要在手势回调里调用 */
private rebuildCanvasSize(): void {
  const cache: TreeLayoutCache = TreeLayoutCache.getInstance();
  const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
  let w: number = 0;
  let h: number = 0;
  for (let i: number = 0; i < roots.length; i = i + 1) {
    if (this.style === TreeStyle.SU) {
      const c: SuCanvas = cache.su(roots[i].uid, [roots[i]], this.cardWidth(), this.isNarrow(), true);
      w = Math.max(w, c.width);
      h = h + c.height + Spacing.XXL;
    } else {
      const c: EuCanvas = cache.eu(roots[i].uid, [roots[i]], this.cardWidth(),
        this.isNarrow() ? 66 : 78, true, 6);
      w = Math.max(w, c.width);
      h = h + c.height + Spacing.XXL;
    }
  }
  this.canvasW = w;
  this.canvasH = h;
  this.offsetX = this.clampX(this.offsetX);
  this.offsetY = this.clampY(this.offsetY);
}

private clampX(v: number): number {
  return ViewportMath.clampOffset(v, this.canvasW, this.viewW, this.zoom, 24);
}

private clampY(v: number): number {
  return ViewportMath.clampOffset(v, this.canvasH, this.viewH, this.zoom, 24);
}
```

`collectSize` 只在值变化时写 state，避免 `refresh → onSize → state → refresh` 回环：

```ts
private collectSize(w: number, h: number): void {
  if (Math.abs(w - this.canvasW) < 1 && Math.abs(h - this.canvasH) < 1) {
    return;
  }
  this.canvasW = Math.max(this.canvasW, w);
  this.canvasH = Math.max(this.canvasH, h);
}
```

- [ ] **Step 3: 修正平移边界回归点**

- 删除 `onRootsChanged()` 方法及其调用（`@Watch` 一并删除）。
- `onStyleChanged()` 中不再把 `canvasW/canvasH` 清 0，改为 `this.rebuildCanvasSize()`。
- `onZoomChanged()` 改为同时把偏移按新 zoom 夹回：

```ts
onZoomChanged(): void {
  this.offsetX = this.clampX(this.offsetX);
  this.offsetY = this.clampY(this.offsetY);
}
```

- 删除 `clampX`/`clampY` 中的 `320`、`240`。
- 把 `EuTree`/`SuTree` 的 `onSize` 改为 `collectSize`（见 Step 2）。

- [ ] **Step 4: 修正世代索引的 O(G×N)**

```ts
@State genLabels: string[] = [];
@State genCounts: number[] = [];

private rebuildGenerations(): void {
  const map: Map<number, number> = new Map<number, number>();
  GenealogyService.getInstance().getPeople().forEach((p: Person): void => {
    const n: number | undefined = map.get(p.generation);
    map.set(p.generation, n === undefined ? 1 : n + 1);
  });
  const gens: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
  this.genLabels = gens.map((g: number): string => generationLabel(g));
  this.genCounts = gens.map((g: number): number => map.get(g) as number);
}
```

在 `refreshRootUids()` 末尾调用一次；`GenerationIndex` 改为只遍历 `genLabels/genCounts`：

```ts
ForEach(this.genLabels, (label: string, idx: number) => {
  Text(label + ' · ' + this.genCounts[idx].toString() + '人')
    // 其余样式不变
}, (label: string, idx: number) => 'idx_' + label + idx.toString())
```

同时删除 `groups()` / `groupLabels()` 在 `GenerationIndex` 中的调用；`groups()` 仍保留给现代谱式使用。

- [ ] **Step 5: 验收**

1. 新增 200 个族人后，不重启，拖到画布最右/最下，最后一位可见。
2. 缩放 20%→150%→20%，四角均可到达。
3. 拖动时不再触发 `TreeBuilder.build`（在 `TreeBuilder.build` 首行加日志确认）。

- [ ] **Step 6: 提交**

```bash
git add Application/entry/src/main/ets/view/TreeCanvas.ets Application/entry/src/main/ets/pages/Index.ets
git commit -m "fix(tree): 修复平移边界失效与环状深拷贝，缓存世代索引"
```

---

### Task 5: 线条 Canvas 化（可选但推荐，目标 5000+ 人）

**Files:**
- Create: `Application/entry/src/main/ets/components/tree/TreeLineLayer.ets`
- Modify: `EuTree.ets` / `SuTree.ets`（用 `TreeLineLayer` 替换线条 ForEach）

**Interfaces:**
- Consumes: `LineSeg[]`（已裁剪）、`offsetX/offsetY`、`zoom`、`viewWidth/viewHeight`
- Produces: `TreeLineLayer` 组件

- [ ] **Step 1: 实现视口大小的覆盖层**

```ts
// Application/entry/src/main/ets/components/tree/TreeLineLayer.ets
import { LineSeg } from '../../service/TreeLayout';
import { Theme } from '../../theme/Theme';

/**
 * 连线绘制层。
 * Canvas 尺寸固定为视口大小（px），绘制时先平移/缩放，再按内容坐标画线；
 * 避免为每一条线创建 Row 组件，也避免超大 Canvas surface。
 */
@Component
export struct TreeLineLayer {
  @Prop @Watch('redraw') lines: LineSeg[] = [];
  @Prop @Watch('redraw') offsetX: number = 0;
  @Prop @Watch('redraw') offsetY: number = 0;
  @Prop @Watch('redraw') zoom: number = 1;
  @Prop @Watch('redraw') viewWidth: number = 0;
  @Prop @Watch('redraw') viewHeight: number = 0;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  redraw(): void {
    this.draw();
  }

  private draw(): void {
    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return;
    }
    const k: number = vp2px(1);
    const wPx: number = vp2px(this.viewWidth);
    const hPx: number = vp2px(this.viewHeight);
    const c: CanvasRenderingContext2D = this.ctx;
    c.clearRect(0, 0, wPx, hPx);
    c.save();
    c.translate(this.offsetX * k, this.offsetY * k);
    c.scale(this.zoom * k, this.zoom * k);
    for (let i: number = 0; i < this.lines.length; i = i + 1) {
      const s: LineSeg = this.lines[i];
      c.strokeStyle = s.red ? Theme.primary : Theme.goldLight;
      c.lineWidth = (s.red ? 1.5 : 1) * k;
      c.beginPath();
      c.moveTo(s.x1, s.y1);
      c.lineTo(s.x2, s.y2);
      c.stroke();
    }
    c.restore();
  }

  build() {
    Canvas(this.ctx)
      .width(this.viewWidth)
      .height(this.viewHeight)
      .onReady((): void => {
        this.draw();
      })
  }
}
```

> `Canvas` 的 `width/height` 用 vp，context 的坐标单位是 px，因此绘制时统一乘 `vp2px(1)`；否则高 DPI 设备上线条位置会整体缩小。

- [ ] **Step 2: 在 EuTree / SuTree 中挂载覆盖层**

`TreeLineLayer` 必须与卡片层**同级**，不能放进已经 translate/scale 的卡片层内，否则会被二次变换；也不能用普通 `Column` 串联，否则 Canvas 会占掉布局高度。用 `Stack` 叠放：

```ts
Stack({ alignContent: Alignment.TopStart }) {
  // 连线层：固定视口大小，自己处理 offset/zoom
  TreeLineLayer({
    lines: this.visibleLines,
    offsetX: this.offsetX,
    offsetY: this.offsetY,
    zoom: this.zoom,
    viewWidth: this.viewWidth,
    viewHeight: this.viewHeight
  })
    .position({ x: 0, y: 0 })

  // 卡片层：保留原来的 scale + translate
  Column() {
    ForEach(this.visibleBoxes, (box: EuBox) => {
      // TreeMiniCard(...)
    }, (box: EuBox) => 'bx_' + box.node.uid)
  }
  .width(this.contentW)
  .height(this.contentH)
  .scale({ x: this.zoom, y: this.zoom, centerX: 0, centerY: 0 })
  .translate({ x: this.offsetX, y: this.offsetY })
}
.width(this.viewWidth)
.height(this.viewHeight)
.clip(true)
```

删除 `EuTree`/`SuTree` 中原来的 `ForEach(this.visibleLines, ...)` 线段 Row。

- [ ] **Step 3: 验收**

- 5000 人欧式谱拖动 60 秒不崩溃，帧率 ≥ 45fps（可用 DevEco Profiler）。
- 线条视觉与原实现一致（婚约双线、金色世系线）。

- [ ] **Step 4: 提交**

```bash
git add Application/entry/src/main/ets/components/tree/TreeLineLayer.ets Application/entry/src/main/ets/components/tree/EuTree.ets Application/entry/src/main/ets/components/tree/SuTree.ets
git commit -m "perf(tree): 连线改用视口 Canvas 绘制"
```

---

### Task 6: 大树分级（宗支总览 + 下钻）

**Files:**
- Create: `Application/entry/src/main/ets/components/tree/BranchOverview.ets`
- Modify: `Application/entry/src/main/ets/view/TreeCanvas.ets`
- Modify: `Application/entry/src/main/ets/model/Enums.ets`（若需新增样式枚举，避免）

**Interfaces:**
- Consumes: `rootUids: string[]`、`layoutVersion: number`
- Produces: `BranchOverview({ rootUids, layoutVersion, onOpenBranch: (uid: string) => void })`

- [ ] **Step 1: 定义阈值与状态**

```ts
/** 大树阈值：超过后默认进入宗支总览 */
const LARGE_TREE: number = 800;
```

`TreeCanvas` 增加：

```ts
@State branchUid: string = '';

private overviewMode(): boolean {
  return this.peopleCount > LARGE_TREE && this.branchUid.length === 0;
}
```

- [ ] **Step 2: 实现宗支总览卡片**

`BranchOverview` 每个宗支一张卡。只接收 uid 等扁平字段，不接收 `PersonNode`（避免环状深拷贝）：

```ts
class BranchInfo {
  uid: string = '';
  name: string = '';
  generation: number = 1;
  descendants: number = 0;
}

@Component
export struct BranchOverview {
  @Prop @Watch('onChanged') rootUids: string[] = [];
  @Prop @Watch('onChanged') layoutVersion: number = 0;
  @State branches: BranchInfo[] = [];
  onOpenBranch: (uid: string) => void = (uid: string): void => {};

  aboutToAppear(): void {
    this.rebuild();
  }

  onChanged(): void {
    this.rebuild();
  }

  private rebuild(): void {
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    const out: BranchInfo[] = [];
    for (let i: number = 0; i < roots.length; i = i + 1) {
      if (this.rootUids.indexOf(roots[i].uid) < 0) {
        continue;
      }
      const b: BranchInfo = new BranchInfo();
      b.uid = roots[i].uid;
      b.name = roots[i].person.name;
      b.generation = roots[i].person.generation;
      b.descendants = roots[i].descendants;
      out.push(b);
    }
    this.branches = out;
  }

  build() {
    Column() {
      ForEach(this.branches, (b: BranchInfo) => {
        Row() {
          Column() {
            Text(b.name).fontSize(16).fontWeight(FontWeight.Medium)
            Text('第' + b.generation.toString() + '世 · 后代 ' + b.descendants.toString() + ' 人')
              .fontSize(11).fontColor(Theme.inkTertiary).margin({ top: 2 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('展开 ›').fontSize(12).fontColor(Theme.primary)
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Theme.card)
        .borderRadius(12)
        .margin({ bottom: 8 })
        .onClick((): void => {
          this.onOpenBranch(b.uid);
        })
      }, (b: BranchInfo) => 'branch_' + b.uid)
    }
    .width('100%')
  }
}
```

- [ ] **Step 3: 接入 TreeCanvas**

`Step 1` 已定义 `branchUid` 与 `overviewMode()`，此处只补“总览/下钻的宗支过滤”：

```ts
/** 总览态返回全部宗支；下钻态只返回当前宗支 */
private visibleRootUids(): string[] {
  if (this.branchUid.length === 0) {
    return this.rootUids;
  }
  return this.rootUids.filter((uid: string): boolean => uid === this.branchUid);
}

private branchName(): string {
  const p: Person | null = GenealogyService.getInstance().getPerson(this.branchUid);
  return p === null ? '' : p.name;
}
```

`build()` 中按模式二选一：

```ts
if (this.overviewMode()) {
  BranchOverview({
    rootUids: this.rootUids,
    layoutVersion: this.dataVersion,
    onOpenBranch: (uid: string): void => {
      this.branchUid = uid;
      this.offsetX = 0;
      this.offsetY = 0;
      this.rebuildCanvasSize();
    }
  })
} else {
  if (this.branchUid.length > 0) {
    Row() {
      Text('‹ 返回总览')
        .fontSize(12)
        .fontColor(Theme.primary)
        .onClick((): void => {
          this.branchUid = '';
          this.offsetX = 0;
          this.offsetY = 0;
          this.rebuildCanvasSize();
        })
      Text(this.branchName())
        .fontSize(13)
        .fontColor(Theme.ink)
        .margin({ left: Spacing.S })
    }
    .width('100%')
    .padding({ bottom: Spacing.S })
  }
  // 原 ForEach 改为 this.visibleRootUids()，其余不变
}
```

同时把 `rebuildCanvasSize()` 的遍历范围改为 `visibleRootUids()`：

```ts
const all: PersonNode[] = GenealogyService.getInstance().getRoots();
const roots: PersonNode[] = all.filter((r: PersonNode): boolean => {
  return this.branchUid.length === 0 || r.uid === this.branchUid;
});
```

- [ ] **Step 4: 验收**

- 2000 人进入谱系页，首屏 ≤ 1s，组件数 ≤ 30。
- 点击宗支后进入该支，再返回总览，状态正确。
- 缩放到 ≤ 40% 时显示概览提示，不出现长时间白屏。

- [ ] **Step 5: 提交**

```bash
git add Application/entry/src/main/ets/components/tree/BranchOverview.ets Application/entry/src/main/ets/view/TreeCanvas.ets
git commit -m "feat(tree): 大树自动进入宗支总览并支持下钻"
```

---

### Task 7: 其余三种谱式虚拟化

**Files:**
- Create: `Application/entry/src/main/ets/util/FlatListSource.ets`
- Modify: `Application/entry/src/main/ets/components/tree/DieRecord.ets`（由外层承载）
- Modify: `Application/entry/src/main/ets/view/TreeCanvas.ets:159-212`
- Modify: `Application/entry/src/main/ets/components/tree/ModernTree.ets`
- Modify: `Application/entry/src/main/ets/components/tree/PagodaTree.ets`

**Interfaces:**
- Consumes: 现有 `groups(): Person[][]`
- Produces: `class FlatListSource<T> implements IDataSource`

- [ ] **Step 1: 实现通用懒加载数据源**

```ts
// Application/entry/src/main/ets/util/FlatListSource.ets

/** LazyForEach 通用数据源：一次只保留数据引用，按需取项 */
export class FlatListSource<T> implements IDataSource {
  private data: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): T {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  setData(data: T[]): void {
    this.data = data;
    this.listeners.forEach((l: DataChangeListener): void => {
      l.onDataReloaded();
    });
  }
}
```

- [ ] **Step 2: 牒记式改为 List + LazyForEach**

`TreeCanvas` 中 `TreeStyle.DIE` 分支不再用 `ForEach(groups)` + 内层 `ForEach(grp)`，改为：

```ts
private dieSource: FlatListSource<Person> = new FlatListSource<Person>();

private rebuildDieSource(): void {
  const people: Person[] = GenealogyService.getInstance().getPeople().slice();
  people.sort((a: Person, b: Person): number => {
    if (a.generation !== b.generation) {
      return a.generation - b.generation;
    }
    return a.uid.localeCompare(b.uid);
  });
  this.dieSource.setData(people);
}
```

在 `refreshRootUids()` 与 `onDataVersionChanged()` 中调用 `rebuildDieSource()`。渲染：

```ts
List({ space: Spacing.M }) {
  LazyForEach(this.dieSource, (p: Person) => {
    ListItem() {
      DieRecord({ person: p, index: 0, showPrivate: this.showPrivate,
        highlight: p.uid === this.highlightUid,
        onTapPerson: (uid: string): void => { this.onTapPerson(uid); } })
    }
  }, (p: Person) => 'die_' + p.uid)
}
.width('100%')
.layoutWeight(1)
.cachedCount(6)
```

- [ ] **Step 3: 宝塔式 / 现代式改为 List 分页**

- `PagodaTree`：外层 `List`，每个 `ListItem` 为一世（`row`），`cachedCount(3)`。
- `ModernTree`：外层 `List`，每个 `ListItem` 为一世，世代内 `Flex` 保留换行；`cachedCount(3)`。

- [ ] **Step 4: 验收**

- 2000 人牒记式滚动流畅，首屏不一次性创建 2000 条。
- 宝塔式/现代式首屏只创建 2~3 世。

- [ ] **Step 5: 提交**

```bash
git add Application/entry/src/main/ets/view/TreeCanvas.ets Application/entry/src/main/ets/components/tree/DieRecord.ets Application/entry/src/main/ets/components/tree/ModernTree.ets Application/entry/src/main/ets/components/tree/PagodaTree.ets
git commit -m "perf(tree): 牒记/宝塔/现代谱式改用懒加载列表"
```

---

### Task 8: 性能可观测与自动降级

**Files:**
- Create: `Application/entry/src/main/ets/util/TreePerf.ets`
- Modify: `Application/entry/src/main/ets/view/TreeCanvas.ets`

**Interfaces:**
- Produces: `class TreePerf { static begin(name: string): void; static end(name: string, extra: string): void; static shouldDegrade(visibleCards: number): boolean }`

- [ ] **Step 1: 埋点**

```ts
import { hilog } from '@kit.PerformanceAnalysisKit';

export class TreePerf {
  private static marks: Map<string, number> = new Map<string, number>();

  static begin(name: string): void {
    TreePerf.marks.set(name, Date.now());
  }

  static end(name: string, extra: string): void {
    const start: number | undefined = TreePerf.marks.get(name);
    if (start === undefined) {
      return;
    }
    const cost: number = Date.now() - start;
    hilog.info(0x0000, 'TreePerf', '%{public}s cost=%{public}dms %{public}s', name, cost, extra);
  }

  static shouldDegrade(visibleCards: number): boolean {
    return visibleCards > 250;
  }
}
```

在 `EuTree.refresh()` 中包裹 `TreePerf.begin('cull')/end('cull', ...)`；在 `TreeLayoutCache.eu()` 首次计算时打点 `layout`。

- [ ] **Step 2: 性能保护模式**

超大树首次进入时把默认缩放降到 0.6 并提示，避免用户一进来就在 100% 下拖拽超宽画布；同时让 `TreePerf.shouldDegrade()` 真正参与判断。

```ts
@State perfMode: boolean = false;
@State perfTip: string = '';

private applyPerfMode(): void {
  if (this.perfMode || this.peopleCount <= LARGE_TREE) {
    return;
  }
  this.perfMode = true;
  if (this.zoom > 0.6) {
    AppStorage.setOrCreate<number>('gpZoom', 0.6);
  }
  this.perfTip = '族人较多，已自动缩小并启用按需渲染';
}
```

在 `refreshRootUids()` 末尾调用 `this.applyPerfMode()`；在 `TreeToolbar()` 的缩放行下方展示 `this.perfTip`（有值才显示）。`TreePerf.shouldDegrade()` 在 `EuTree.refresh()` 中作为日志告警使用：可见卡片超过 250 时输出 warn，便于现场定位异常视口。

- [ ] **Step 3: 验收**

`hilog -T TreePerf` 可见：1000 人布局 < 120ms、裁剪 < 5ms、可见卡片 < 250。

- [ ] **Step 4: 提交**

```bash
git add Application/entry/src/main/ets/util/TreePerf.ets Application/entry/src/main/ets/view/TreeCanvas.ets
git commit -m "feat(tree): 增加渲染性能埋点与自动降级"
```

---

## 四、验收与回归清单

### 4.1 性能指标（中端机实测）

| 规模 | 首屏进入 | 拖动帧率 | 可见组件数 | 内存增量 |
| --- | --- | --- | --- | --- |
| 200 人 | < 400ms | 60fps | < 120 | < 30MB |
| 1000 人 | < 900ms | ≥ 55fps | < 200 | < 80MB |
| 3000 人 | < 1.5s | ≥ 50fps | < 220 | < 120MB |
| 5000 人 | < 2s（概览态） | ≥ 45fps | < 30（概览） | < 150MB |

### 4.2 功能回归

- [ ] 五种谱式切换正常，切换后偏移归零、始祖可见。
- [ ] 欧式/苏式：拖到最右/最下能看到最后一位族人；缩小后四角可达。
- [ ] 点击卡片、配偶、子女跳转正常。
- [ ] 高亮人物（`highlightUid`）在裁剪后仍能定位（若不在视口，提供“定位”按钮把 offset 移到该节点）。
- [ ] 隐私模式、公开模式、深色模式显示正常。
- [ ] 新增/编辑/删除/导入/云同步后画布刷新，不崩溃。
- [ ] 多宗支、单亲、继室/妾室、环形关系数据不崩溃。

### 4.3 崩溃回归

- [ ] 1000 人连续拖动 60 秒。
- [ ] 5000 人切换 5 种谱式各 3 次。
- [ ] 缩放 20% ↔ 150% 连续 20 次。
- [ ] 后台切回、横竖屏切换各 5 次。

---

## 五、风险与回滚

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| `@Prop` 改普通参数后数据不刷新 | 画面不更新 | 统一由 `gpVersion` 驱动 `refresh()`；子组件 `aboutToAppear` 与 `@Watch` 都调用一次 |
| Canvas 绘制单位 vp/px 混用 | 线条错位 | `TreeLineLayer` 统一用 `vp2px`，在 Step 1 写明换算 |
| 裁剪后点击高亮人物不可见 | 体验倒退 | 增加“定位到人物”按钮，按节点坐标重算 offset |
| 概览模式阈值过低 | 用户觉得“看不到谱” | 阈值可配置（`LARGE_TREE`），默认 800；首次进入可在设置页关闭 |
| 无自动化测试环境 | 回归靠手工 | Task 1 的纯函数单测必须保留；其余以真机清单为准 |

**回滚策略：** 每个 Task 独立提交；若 Canvas 化（Task 5）出现渲染问题，直接 revert 该提交即可回到“裁剪 + 组件线条”的稳定版本。

---

## 六、实施顺序与预估

| 阶段 | 任务 | 目的 |
| --- | --- | --- |
| P0 稳定性（先做） | Task 1、2、4 | 修复边界失效、重复布局、环状深拷贝，先止血 |
| P1 性能 | Task 3、5 | 视口裁剪 + Canvas 线条，解决卡顿 |
| P2 大树体验 | Task 6、7 | 概览/下钻 + 其余谱式懒加载 |
| P3 保障 | Task 8 | 埋点、降级、回归 |

P0 完成即可消除“拖到边界只显示几个人”和大部分崩溃；P1 完成后 1000~3000 人可正常使用；P2 覆盖 5000+ 人。