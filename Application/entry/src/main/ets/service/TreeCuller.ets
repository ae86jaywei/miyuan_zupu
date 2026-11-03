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