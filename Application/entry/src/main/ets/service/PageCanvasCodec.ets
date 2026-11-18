import { PersonNode } from 'common_base';
import { EuBox, EuCanvas, LineSeg, SuBox, SuCanvas } from './TreeLayout';
import { PaginationService } from './PaginationService';

/**
 * 单页布局（欧式/苏式）的磁盘序列化。
 *
 * 只存 uid 与几何：恢复时按 uid 挂回当前 PersonNode，
 * 这样节点被删除时能直接判定缓存失效，不会还原出过期人物。
 */
class CanvasBoxRec {
  uid: string = '';
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
  centerY: number = 0;
}

/** 一页布局的磁盘格式（欧式/苏式共用，按 style 区分） */
class CanvasRec {
  width: number = 0;
  height: number = 0;
  rootUid: string = '';
  boxes: CanvasBoxRec[] = [];
  lines: LineSeg[] = [];
}

export class PageCanvasCodec {
  /** 布局 → JSON */
  static encode(canvas: EuCanvas | SuCanvas, style: string): string {
    const rec: CanvasRec = new CanvasRec();
    rec.width = canvas.width;
    rec.height = canvas.height;
    rec.rootUid = canvas.rootBox === null ? '' : canvas.rootBox.node.uid;
    if (style === 'su') {
      const su: SuCanvas = canvas as SuCanvas;
      for (let i: number = 0; i < su.boxes.length; i = i + 1) {
        const b: SuBox = su.boxes[i];
        const br: CanvasBoxRec = new CanvasBoxRec();
        br.uid = b.node.uid;
        br.x = b.x;
        br.y = b.y;
        br.w = b.w;
        br.h = b.h;
        rec.boxes.push(br);
      }
    } else {
      const eu: EuCanvas = canvas as EuCanvas;
      for (let i: number = 0; i < eu.boxes.length; i = i + 1) {
        const b: EuBox = eu.boxes[i];
        const br: CanvasBoxRec = new CanvasBoxRec();
        br.uid = b.node.uid;
        br.x = b.x;
        br.y = b.y;
        br.w = b.w;
        br.h = b.h;
        br.centerY = b.centerY;
        rec.boxes.push(br);
      }
    }
    rec.lines = canvas.lines;
    return JSON.stringify(rec);
  }

  /** JSON → 布局；任一节点已不存在时返回 null（调用方回退实时布局） */
  static decode(json: string, style: string): EuCanvas | SuCanvas | null {
    const rec: CanvasRec = JSON.parse(json) as CanvasRec;
    const nodes: Map<string, PersonNode> = PaginationService.nodeIndexOfCurrentBook();
    if (style === 'su') {
      const su: SuCanvas = new SuCanvas();
      su.width = rec.width;
      su.height = rec.height;
      for (let i: number = 0; i < rec.boxes.length; i = i + 1) {
        const br: CanvasBoxRec = rec.boxes[i];
        const node: PersonNode | undefined = nodes.get(br.uid);
        if (node === undefined) {
          return null;
        }
        const b: SuBox = new SuBox();
        b.node = node;
        b.x = br.x;
        b.y = br.y;
        b.w = br.w;
        b.h = br.h;
        su.boxes.push(b);
        if (rec.rootUid.length > 0 && rec.rootUid === br.uid) {
          su.rootBox = b;
        }
      }
      su.lines = rec.lines;
      return su;
    }
    const eu: EuCanvas = new EuCanvas();
    eu.width = rec.width;
    eu.height = rec.height;
    for (let i: number = 0; i < rec.boxes.length; i = i + 1) {
      const br: CanvasBoxRec = rec.boxes[i];
      const node: PersonNode | undefined = nodes.get(br.uid);
      if (node === undefined) {
        return null;
      }
      const b: EuBox = new EuBox();
      b.node = node;
      b.x = br.x;
      b.y = br.y;
      b.w = br.w;
      b.h = br.h;
      b.centerY = br.centerY;
      eu.boxes.push(b);
      if (rec.rootUid.length > 0 && rec.rootUid === br.uid) {
        eu.rootBox = b;
      }
    }
    eu.lines = rec.lines;
    return eu;
  }
}
