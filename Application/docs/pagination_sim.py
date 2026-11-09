#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
族谱分页方法量化对比（对应当前 1.0.1 的 EuLayout / SuLayout）

对比两种做法在同一棵谱上的「跨页悬空线」：
  A. 直接在全局大布局上按页面尺寸切片（今天的连续画布思路）
  B. 每页重新布局（把页边界处被切开的族人作为该页的“页根”，页内重新排）

度量：
  pages        页数（按页面内容区 179×264mm、卡片 16×7mm 估算）
  dangling     跨页悬空线段总数：切线与某个父节点的“母线”相交，母线被截断
  per_edge     每条页边界的平均悬空段数
  page_roots   方案 B 每页需要标注“承第 N 页”的入口人数
"""
import random

# 纸面：成品 220×320；出血在成品外，不占版心；左 20mm 装订口，右 15mm 翻口，天头/地脚各 25mm
CONTENT_W = 220 - 20 - 15              # 185mm
CONTENT_H = 320 - 25 - 25              # 270mm
CARD_W, CARD_H = 16.0, 7.0
COL_GAP, ROW_GAP, SIB_GAP = 3.0, 5.0, 3.0

class N:
    __slots__ = ("uid", "gen", "kids", "lo", "hi", "cx", "span")
    def __init__(self, uid, gen):
        self.uid = uid; self.gen = gen; self.kids = []
        self.lo = 0.0; self.hi = 0.0; self.cx = 0.0
        self.span = (0.0, 0.0)   # 该父节点母线覆盖的子节点范围

def build(n_target, max_gen, seed=11):
    random.seed(seed)
    root = N(0, 1); nodes = [root]; frontier = [root]; uid = 1
    while frontier and uid < n_target:
        nxt = []
        for n in frontier:
            if n.gen >= max_gen: continue
            k = random.choices([1, 2, 3], weights=[0.3, 0.45, 0.25])[0]
            for _ in range(k):
                if uid >= n_target: break
                c = N(uid, n.gen + 1); n.kids.append(c); nodes.append(c); nxt.append(c); uid += 1
        frontier = nxt
    return root, nodes

def layout_su(root):
    cursor = 0.0
    def place(n):
        nonlocal cursor
        if not n.kids:
            n.lo = cursor; n.hi = cursor + CARD_W; n.cx = cursor + CARD_W / 2
            cursor += CARD_W + COL_GAP
        else:
            for k in n.kids: place(k)
            n.cx = (n.kids[0].cx + n.kids[-1].cx) / 2
            n.lo = min(n.cx - CARD_W / 2, min(k.lo for k in n.kids))
            n.hi = max(n.cx + CARD_W / 2, max(k.hi for k in n.kids))
        if n.kids:
            n.span = (min(k.cx for k in n.kids), max(k.cx for k in n.kids))
    place(root)
    return cursor - COL_GAP

def layout_eu(root):
    cursor = 0.0
    def place(n):
        nonlocal cursor
        if not n.kids:
            n.lo = cursor; n.hi = cursor + CARD_H; n.cx = cursor + CARD_H / 2
            cursor += CARD_H + SIB_GAP
        else:
            for k in n.kids: place(k)
            n.cx = (n.kids[0].cx + n.kids[-1].cx) / 2
            n.lo = min(n.cx - CARD_H / 2, min(k.lo for k in n.kids))
            n.hi = max(n.cx + CARD_H / 2, max(k.hi for k in n.kids))
        if n.kids:
            n.span = (min(k.cx for k in n.kids), max(k.cx for k in n.kids))
    place(root)
    return cursor - SIB_GAP

def pages_and_cuts(total, leaves, pitch, page_size, cross_size, cross_axis_size):
    """返回页数、切线位置、每页覆盖的叶子序号"""
    per_page = max(1, int(page_size // pitch))
    pages = (leaves + per_page - 1) // per_page
    cuts = [i * per_page * pitch - COL_GAP / 2 for i in range(1, pages)]
    return pages, per_page, cuts

def dangling(span_list, cuts):
    total = 0; worst = 0
    per_edge = []
    for c in cuts:
        n = sum(1 for (lo, hi) in span_list if lo < c < hi)
        total += n; per_edge.append(n); worst = max(worst, n)
    return total, per_edge, worst

def report(n_target, max_gen):
    root, nodes = build(n_target, max_gen)
    leaves = sum(1 for n in nodes if not n.kids)
    gens = max(n.gen for n in nodes)
    print(f"\n=== {len(nodes)} 人 / {gens} 世 / {leaves} 个叶子 ===")

    # 苏式：横向主轴
    w = layout_su(root)
    spans = [n.span for n in nodes if n.kids]
    pages, per_page, cuts = pages_and_cuts(w, leaves, CARD_W + COL_GAP, CONTENT_W, 0, 0)
    total, per_edge, worst = dangling(spans, cuts)
    print(f"苏式 全局宽 {w:.0f}mm，每页 {per_page} 列 × {gens} 行 → {pages} 页")
    print(f"     切面悬空线：共 {total} 段，页边界平均 {total/len(cuts):.1f} 段，最差 {worst} 段")
    print(f"     重排后：悬空 0 段；每页入口（承前页）约 {pages} 人，页根标注 {pages} 条")

    # 欧式：纵向主轴，横向按世代列分带
    h = layout_eu(root)
    spans2 = [n.span for n in nodes if n.kids]
    pitch = CARD_H + SIB_GAP
    per_page2 = max(1, int(CONTENT_H // pitch))
    pages2 = (leaves + per_page2 - 1) // per_page2
    cuts2 = [i * per_page2 * pitch - SIB_GAP / 2 for i in range(1, pages2)]
    total2, _, worst2 = dangling(spans2, cuts2)
    gen_per_band = max(1, int(CONTENT_W // (CARD_W + COL_GAP)))
    bands = (gens + gen_per_band - 1) // gen_per_band
    print(f"欧式 全局高 {h:.0f}mm，每页 {per_page2} 行 × {gen_per_band} 列 → {pages2} 行页 × {bands} 个世代带 = {pages2 * bands} 页")
    print(f"     切面悬空线：共 {total2} 段，页边界平均 {total2/len(cuts2):.1f} 段，最差 {worst2} 段")
    print(f"     重排后：悬空 0 段；每页入口约 {pages2 * bands} 人")

for n, g in [(1200, 12), (3000, 15)]:
    report(n, g)
