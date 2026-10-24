import { PersonNode } from '../model/PersonNode';
import { Person } from '../model/Person';

/** 欧式谱一个节点在画布上的位置 */
export class EuBox {
  node: PersonNode = new PersonNode(new Person());
  x: number = 0;
  y: number = 0;
  w: number = 120;
  h: number = 64;
  centerY: number = 0;
}

/** 连线线段 */
export class LineSeg {
  x1: number = 0;
  y1: number = 0;
  x2: number = 0;
  y2: number = 0;
}

/** 欧式谱画布 */
export class EuCanvas {
  boxes: EuBox[] = [];
  lines: LineSeg[] = [];
  width: number = 0;
  height: number = 0;
}

/**
 * 欧式谱布局（横轴世系图）。
 *
 * 采用自底向上的“叶子计数 + 纵向堆叠”算法：
 *  - 每个叶子节点占据一个行高 slot；
 *  - 父节点的纵向中心 = 首末子节点中心的中点；
 *  - 同一层的所有节点 x 相同（= depth * (卡片宽 + 列间距)），
 *    因此第 N 世永远在第 N 列，任何两个节点都不会重叠；
 *  - 相邻两列之间绘制水平连线，父中心到子中心绘制竖直/斜向连线。
 */
export class EuLayout {
  static compute(roots: PersonNode[], cardWidth: number, rowHeight: number, colGap: number,
    showSpouse: boolean, startY: number): EuCanvas {
    const canvas: EuCanvas = new EuCanvas();
    const placed: Map<string, EuBox> = new Map<string, EuBox>();
    let nextSlot: number = 0;

    // 自底向上：先排定所有叶子（每个叶子占一个行 slot），
    // 父节点的中心 = 首末子节点中心的中点，从而保证父节点始终位于子树中间。
    const place = (node: PersonNode, depth: number): EuBox => {
      const existing: EuBox | undefined = placed.get(node.uid);
      if (existing !== undefined) {
        return existing;
      }
      const box: EuBox = new EuBox();
      box.node = node;
      box.w = cardWidth;
      box.h = rowHeight - 16;
      box.x = depth * (cardWidth + colGap);
      if (node.children.length === 0) {
        box.y = startY + nextSlot * rowHeight;
        nextSlot = nextSlot + 1;
      } else {
        // 先递归排定全部子节点
        node.children.forEach((child: PersonNode): void => {
          place(child, depth + 1);
        });
        const centers: number[] = [];
        node.children.forEach((child: PersonNode): void => {
          const cb: EuBox | undefined = placed.get(child.uid);
          if (cb !== undefined) {
            centers.push(cb.y + cb.h / 2);
          }
        });
        if (centers.length === 0) {
          box.y = startY + nextSlot * rowHeight;
          nextSlot = nextSlot + 1;
        } else {
          let lo: number = centers[0];
          let hi: number = centers[0];
          centers.forEach((c: number): void => {
            if (c < lo) {
              lo = c;
            }
            if (c > hi) {
              hi = c;
            }
          });
          box.y = (lo + hi) / 2 - box.h / 2;
        }
      }
      box.centerY = box.y + box.h / 2;
      placed.set(node.uid, box);
      canvas.boxes.push(box);
      return box;
    };

    roots.forEach((r: PersonNode, idx: number): void => {
      place(r, 0);
      nextSlot = nextSlot + 0.5; // 宗支之间额外留白，避免重叠
    });

    // 连线：父右缘 → 折线 → 子左缘
    canvas.boxes.forEach((parentBox: EuBox): void => {
      parentBox.node.children.forEach((child: PersonNode): void => {
        const cb: EuBox | undefined = placed.get(child.uid);
        if (cb === undefined) {
          return;
        }
        const x1: number = parentBox.x + parentBox.w;
        const y1: number = parentBox.centerY;
        const x2: number = cb.x;
        const y2: number = cb.centerY;
        const midX: number = x1 + colGap / 2;
        const h1: LineSeg = new LineSeg();
        h1.x1 = x1;
        h1.y1 = y1;
        h1.x2 = midX;
        h1.y2 = y1;
        canvas.lines.push(h1);
        if (Math.abs(y2 - y1) > 1) {
          const v: LineSeg = new LineSeg();
          v.x1 = midX;
          v.y1 = Math.min(y1, y2);
          v.x2 = midX;
          v.y2 = Math.max(y1, y2);
          canvas.lines.push(v);
        }
        const h2: LineSeg = new LineSeg();
        h2.x1 = midX;
        h2.y1 = y2;
        h2.x2 = x2;
        h2.y2 = y2;
        canvas.lines.push(h2);
      });
    });

    let maxX: number = 0;
    let maxY: number = 0;
    canvas.boxes.forEach((b: EuBox): void => {
      if (b.x + b.w > maxX) {
        maxX = b.x + b.w;
      }
      if (b.y + b.h > maxY) {
        maxY = b.y + b.h;
      }
    });
    canvas.width = maxX + colGap;
    canvas.height = maxY + startY + 24;
    return canvas;
  }
}

/** 苏式谱一个节点的位置 */
export class SuBox {
  node: PersonNode = new PersonNode(new Person());
  x: number = 0;
  y: number = 0;
  w: number = 120;
  h: number = 64;
}

export class SuCanvas {
  boxes: SuBox[] = [];
  lines: LineSeg[] = [];
  width: number = 0;
  height: number = 0;
}

/**
 * 苏式谱布局（竖式吊线图）。
 *
 * 采用“叶子计数 + 横向排布”：每个叶子占一个列宽 slot；
 * 父节点的横向中心 = 首末子节点中心的中点；
 * 同一层的所有节点 y 相同，因此世代层次分明、不会重叠。
 */
export class SuLayout {
  static compute(roots: PersonNode[], cardWidth: number, colGap: number, rowGap: number,
    startX: number, cardH: number): SuCanvas {
    const canvas: SuCanvas = new SuCanvas();
    const placed: Map<string, SuBox> = new Map<string, SuBox>();
    let nextSlot: number = 0;
    const slotW: number = cardWidth + colGap;

    const place = (node: PersonNode, depth: number): SuBox => {
      const existing: SuBox | undefined = placed.get(node.uid);
      if (existing !== undefined) {
        return existing;
      }
      const box: SuBox = new SuBox();
      box.node = node;
      box.w = cardWidth;
      box.h = cardH;
      box.y = depth * (cardH + rowGap);
      if (node.children.length === 0) {
        box.x = startX + nextSlot * slotW;
        nextSlot = nextSlot + 1;
      } else {
        node.children.forEach((child: PersonNode): void => {
          place(child, depth + 1);
        });
        const centers: number[] = [];
        node.children.forEach((child: PersonNode): void => {
          const cb: SuBox | undefined = placed.get(child.uid);
          if (cb !== undefined) {
            centers.push(cb.x + cb.w / 2);
          }
        });
        if (centers.length === 0) {
          box.x = startX + nextSlot * slotW;
          nextSlot = nextSlot + 1;
        } else {
          const c: number = (centers[0] + centers[centers.length - 1]) / 2;
          box.x = c - cardWidth / 2;
        }
      }
      placed.set(node.uid, box);
      canvas.boxes.push(box);
      return box;
    };

    roots.forEach((r: PersonNode): void => {
      place(r, 0);
      nextSlot = nextSlot + 0.5;
    });

    canvas.boxes.forEach((parentBox: SuBox): void => {
      if (parentBox.node.children.length === 0) {
        return;
      }
      const px: number = parentBox.x + parentBox.w / 2;
      const py: number = parentBox.y + parentBox.h;
      const busY: number = py + rowGap / 2;
      const v0: LineSeg = new LineSeg();
      v0.x1 = px;
      v0.y1 = py;
      v0.x2 = px;
      v0.y2 = busY;
      canvas.lines.push(v0);
      let minX: number = px;
      let maxX: number = px;
      parentBox.node.children.forEach((child: PersonNode): void => {
        const cb: SuBox | undefined = placed.get(child.uid);
        if (cb === undefined) {
          return;
        }
        const cx: number = cb.x + cb.w / 2;
        if (cx < minX) {
          minX = cx;
        }
        if (cx > maxX) {
          maxX = cx;
        }
        const v: LineSeg = new LineSeg();
        v.x1 = cx;
        v.y1 = busY;
        v.x2 = cx;
        v.y2 = cb.y;
        canvas.lines.push(v);
      });
      if (maxX - minX > 1) {
        const bus: LineSeg = new LineSeg();
        bus.x1 = minX;
        bus.y1 = busY;
        bus.x2 = maxX;
        bus.y2 = busY;
        canvas.lines.push(bus);
      }
    });

    let maxX2: number = 0;
    let maxY2: number = 0;
    canvas.boxes.forEach((b: SuBox): void => {
      if (b.x + b.w > maxX2) {
        maxX2 = b.x + b.w;
      }
      if (b.y + b.h > maxY2) {
        maxY2 = b.y + b.h;
      }
    });
    canvas.width = maxX2 + startX + 24;
    canvas.height = maxY2 + 24;
    return canvas;
  }
}
