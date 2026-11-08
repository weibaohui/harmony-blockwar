/**
 * Canvas 渲染器：把 Engine 的状态画到画布上。
 * 坐标单位与 ArkUI 组件一致（vp），宽高来自 Canvas onAreaChange。
 * 两种布局：
 * - 竖屏：棋盘上方一条紧凑信息条（HOLD + NEXT），棋盘放大居中
 * - 横屏：棋盘左侧 HOLD、右侧 NEXT
 */

import { Engine, Phase, GameMode, ROWS, COLS, BUFFER_ROWS, BOARD_ROWS, GARBAGE_INTERVAL_MS } from './Engine';
import { PIECES, GARBAGE_COLOR, GARBAGE_LIGHT, GARBAGE_DARK, PieceDef } from './Tetromino';

const BOARD_BG = '#141A2C';
const BOARD_GRID = 'rgba(255,255,255,0.05)';
const BOARD_BORDER = 'rgba(74,212,232,0.30)';
const PANEL_BG = 'rgba(23,28,49,0.92)';
const PANEL_BORDER = 'rgba(74,212,232,0.18)';
const TOAST_BG = 'rgba(10,13,26,0.78)';

const SIDE = 3.4;  // 横屏侧边面板宽（格数）
const GAP = 0.5;   // 面板与棋盘间距（格数）
const STRIP = 2.6; // 竖屏顶部信息条高（格数）

export class Renderer {
  private cell = 0;
  private bx = 0; // 棋盘左上角
  private by = 0;

  /** 当前格子尺寸（vp），供手势层换算滑动距离 */
  cellSize(): number {
    return this.cell;
  }

  draw(ctx: CanvasRenderingContext2D, W: number, H: number, eng: Engine, now: number): void {
    if (W < 24 || H < 24) {
      return;
    }
    ctx.clearRect(0, 0, W, H);
    if (W / H >= 1.05) {
      this.drawLandscape(ctx, W, H, eng, now);
    } else {
      this.drawPortrait(ctx, W, H, eng, now);
    }
  }

  // ---------------- 竖屏布局 ----------------

  private drawPortrait(ctx: CanvasRenderingContext2D, W: number, H: number, eng: Engine, now: number): void {
    let cell = Math.floor(Math.min(W / 10.8, H / (ROWS + STRIP + 0.4)));
    if (cell < 6) {
      cell = 6;
    }
    this.cell = cell;
    const bw = COLS * cell;
    const bh = ROWS * cell;
    const stripH = Math.floor(STRIP * cell);
    this.bx = Math.floor((W - bw) / 2);
    this.by = Math.floor((H - bh - stripH) / 2) + stripH;

    this.drawStrip(ctx, eng, this.bx, this.by - stripH, bw, stripH);
    this.drawBoardBase(ctx, bw, bh);
    this.drawSettled(ctx, bw, bh, eng, now);
    this.drawActive(ctx, eng);
    this.drawHazardBar(ctx, bw, bh, eng, now);
    this.drawToast(ctx, bw, bh, eng, now);
  }

  /** 竖屏顶部信息条：HOLD 在左，NEXT 三枚在右 */
  private drawStrip(ctx: CanvasRenderingContext2D, eng: Engine, x: number, y: number, w: number, h: number): void {
    const s = this.cell;
    const holdW = Math.floor(2.8 * s);
    this.rr(ctx, x, y, holdW, h, 8);
    ctx.fillStyle = PANEL_BG;
    ctx.fill();
    ctx.strokeStyle = PANEL_BORDER;
    ctx.lineWidth = 1;
    ctx.stroke();
    if (eng.holdIdx >= 0) {
      this.miniPiece(ctx, eng.holdIdx, x + holdW / 2, y + h / 2, s * 0.5, eng.canHold ? 1.0 : 0.35);
    }

    const nextW = Math.floor(6.2 * s);
    const nx = x + w - nextW;
    this.rr(ctx, nx, y, nextW, h, 8);
    ctx.fillStyle = PANEL_BG;
    ctx.fill();
    ctx.strokeStyle = PANEL_BORDER;
    ctx.lineWidth = 1;
    ctx.stroke();
    for (let i = 0; i < 3 && i < eng.queue.length; i++) {
      const cx = nx + nextW * (i + 0.5) / 3;
      const alpha = i === 0 ? 1.0 : (i === 1 ? 0.75 : 0.5);
      this.miniPiece(ctx, eng.queue[i], cx, y + h / 2, s * 0.42, alpha);
    }
  }

  // ---------------- 横屏布局 ----------------

  private drawLandscape(ctx: CanvasRenderingContext2D, W: number, H: number, eng: Engine, now: number): void {
    let cell = Math.floor(Math.min(W / (COLS + (SIDE + GAP) * 2), H / (ROWS + 0.8)));
    if (cell < 6) {
      cell = 6;
    }
    this.cell = cell;
    const bw = COLS * cell;
    const bh = ROWS * cell;
    const leftW = Math.floor((SIDE + GAP) * cell);
    this.bx = Math.floor((W - (bw + leftW * 2)) / 2) + leftW;
    this.by = Math.floor((H - bh) / 2);

    this.drawSidePanels(ctx, eng);
    this.drawBoardBase(ctx, bw, bh);
    this.drawSettled(ctx, bw, bh, eng, now);
    this.drawActive(ctx, eng);
    this.drawHazardBar(ctx, bw, bh, eng, now);
    this.drawToast(ctx, bw, bh, eng, now);
  }

  /** 横屏侧面板：HOLD 左、NEXT 右 */
  private drawSidePanels(ctx: CanvasRenderingContext2D, eng: Engine): void {
    const s = this.cell;
    const panelW = Math.floor(SIDE * s);
    const leftX = this.bx - Math.floor((SIDE + GAP) * s);
    const rightX = this.bx + COLS * s + Math.floor(GAP * s);

    this.rr(ctx, leftX, this.by, panelW, Math.floor(4.2 * s), 8);
    ctx.fillStyle = PANEL_BG;
    ctx.fill();
    ctx.strokeStyle = PANEL_BORDER;
    ctx.lineWidth = 1;
    ctx.stroke();
    if (eng.holdIdx >= 0) {
      this.miniPiece(ctx, eng.holdIdx, leftX + panelW / 2, this.by + 2.1 * s, s * 0.62, eng.canHold ? 1.0 : 0.35);
    }

    const nextH = Math.floor(9.6 * s);
    this.rr(ctx, rightX, this.by, panelW, nextH, 8);
    ctx.fillStyle = PANEL_BG;
    ctx.fill();
    ctx.strokeStyle = PANEL_BORDER;
    ctx.lineWidth = 1;
    ctx.stroke();
    for (let i = 0; i < 3 && i < eng.queue.length; i++) {
      const cy = this.by + (1.7 + i * 2.6) * s;
      const alpha = i === 0 ? 1.0 : (i === 1 ? 0.75 : 0.5);
      this.miniPiece(ctx, eng.queue[i], rightX + panelW / 2, cy, s * (i === 0 ? 0.62 : 0.5), alpha);
    }
  }

  // ---------------- 棋盘与动态元素 ----------------

  private drawBoardBase(ctx: CanvasRenderingContext2D, bw: number, bh: number): void {
    const x = this.bx;
    const y = this.by;
    this.rr(ctx, x - 4, y - 4, bw + 8, bh + 8, 10);
    ctx.fillStyle = BOARD_BG;
    ctx.fill();
    ctx.strokeStyle = BOARD_GRID;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let c = 1; c < COLS; c++) {
      ctx.moveTo(x + c * this.cell, y);
      ctx.lineTo(x + c * this.cell, y + bh);
    }
    for (let r = 1; r < ROWS; r++) {
      ctx.moveTo(x, y + r * this.cell);
      ctx.lineTo(x + bw, y + r * this.cell);
    }
    ctx.stroke();
    this.rr(ctx, x - 4, y - 4, bw + 8, bh + 8, 10);
    ctx.strokeStyle = BOARD_BORDER;
    ctx.lineWidth = 2;
    ctx.stroke();
  }

  private drawSettled(ctx: CanvasRenderingContext2D, bw: number, bh: number, eng: Engine, now: number): void {
    const s = this.cell;
    for (let r = BUFFER_ROWS; r < BOARD_ROWS; r++) {
      for (let c = 0; c < COLS; c++) {
        const v = eng.board[r][c];
        if (v === 0) {
          continue;
        }
        const x = this.bx + c * s;
        const y = this.by + (r - BUFFER_ROWS) * s;
        if (v === -1) {
          this.block(ctx, x, y, s, GARBAGE_COLOR, GARBAGE_LIGHT, GARBAGE_DARK, 1.0);
        } else {
          const def = PIECES[v - 1];
          this.block(ctx, x, y, s, def.color, def.light, def.dark, 1.0);
        }
      }
    }
    // 消行白闪动画
    if (eng.phase === Phase.Clearing && eng.clearingRows.length > 0) {
      const t = Math.min(1, (now - eng.clearStart) / 180);
      const a = Math.max(0, 0.9 - t);
      ctx.fillStyle = `rgba(255,255,255,${a.toFixed(3)})`;
      for (let i = 0; i < eng.clearingRows.length; i++) {
        if (eng.clearingRows[i] < BUFFER_ROWS) {
          continue;
        }
        ctx.fillRect(this.bx, this.by + (eng.clearingRows[i] - BUFFER_ROWS) * s, bw, s);
      }
    }
  }

  private drawActive(ctx: CanvasRenderingContext2D, eng: Engine): void {
    if (eng.cur === null) {
      return;
    }
    if (eng.phase !== Phase.Running) {
      return;
    }
    const p = eng.cur;
    const def = PIECES[p.idx];
    const cells = def.cells[p.rot];
    const s = this.cell;
    // 幽灵投影
    const gy = eng.ghostY();
    if (gy > p.y) {
      ctx.strokeStyle = def.color;
      ctx.lineWidth = 2;
      for (let i = 0; i < cells.length; i++) {
        const bx = p.x + cells[i][0];
        const by = gy + cells[i][1];
        if (by < BUFFER_ROWS) {
          continue;
        }
        this.rr(ctx, this.bx + bx * s + 2, this.by + (by - BUFFER_ROWS) * s + 2, s - 4, s - 4, Math.max(2, s * 0.16));
        ctx.globalAlpha = 0.45;
        ctx.stroke();
        ctx.globalAlpha = 1.0;
      }
    }
    // 当前方块
    for (let i = 0; i < cells.length; i++) {
      const bx = p.x + cells[i][0];
      const by = p.y + cells[i][1];
      if (by < BUFFER_ROWS) {
        continue;
      }
      this.block(ctx, this.bx + bx * s, this.by + (by - BUFFER_ROWS) * s, s, def.color, def.light, def.dark, 1.0);
    }
  }

  private drawHazardBar(ctx: CanvasRenderingContext2D, bw: number, bh: number, eng: Engine, now: number): void {
    if (eng.mode !== GameMode.Hazard) {
      return;
    }
    if (eng.phase !== Phase.Running && eng.phase !== Phase.Clearing) {
      return;
    }
    // 倒计时进度条（棋盘顶部）
    const remain = Math.max(0, eng.nextGarbageAt - now);
    const frac = Math.max(0, Math.min(1, remain / GARBAGE_INTERVAL_MS));
    ctx.fillStyle = 'rgba(255,90,90,0.85)';
    ctx.fillRect(this.bx, this.by, bw * frac, 3);

    // 垃圾行挂起时：红色脉冲边框（数量提示在 HUD）
    if (eng.pendingGarbage > 0) {
      const a = 0.4 + 0.3 * Math.sin(now / 130);
      this.rr(ctx, this.bx - 4, this.by - 4, bw + 8, bh + 8, 10);
      ctx.strokeStyle = `rgba(255,90,90,${a.toFixed(3)})`;
      ctx.lineWidth = 4;
      ctx.stroke();
    }
  }

  private drawToast(ctx: CanvasRenderingContext2D, bw: number, bh: number, eng: Engine, now: number): void {
    if (eng.toast === '') {
      return;
    }
    const dt = now - eng.toastAt;
    if (dt < 0 || dt > 1000) {
      return;
    }
    const a = 1 - dt / 1000;
    const fs = Math.max(14, this.cell * 0.85);
    ctx.font = `bold ${fs}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    const tw = ctx.measureText(eng.toast).width;
    const cx = this.bx + bw / 2;
    const cy = this.by + bh * 0.3;
    this.rr(ctx, cx - tw / 2 - fs * 0.6, cy - fs * 0.85, tw + fs * 1.2, fs * 1.7, fs * 0.85);
    ctx.fillStyle = TOAST_BG;
    ctx.globalAlpha = a;
    ctx.fill();
    ctx.fillStyle = '#FFFFFF';
    ctx.fillText(eng.toast, cx, cy);
    ctx.globalAlpha = 1.0;
  }

  // ---------------- 基础图元 ----------------

  /** 圆角方块：主体色 + 顶部高光 + 底部阴影边 */
  private block(ctx: CanvasRenderingContext2D, x: number, y: number, s: number,
    color: string, light: string, dark: string, alpha: number): void {
    const r = Math.max(2, s * 0.16);
    const pad = Math.max(1, s * 0.05);
    const w = s - pad * 2;
    this.rr(ctx, x + pad, y + pad, w, w, r);
    ctx.fillStyle = color;
    ctx.globalAlpha = alpha;
    ctx.fill();
    // 顶部高光条
    this.rr(ctx, x + pad + w * 0.14, y + pad + w * 0.10, w * 0.72, w * 0.26, r * 0.5);
    ctx.fillStyle = light;
    ctx.globalAlpha = 0.4 * alpha;
    ctx.fill();
    // 底边阴影线
    this.rr(ctx, x + pad + w * 0.10, y + pad + w * 0.82, w * 0.8, w * 0.10, r * 0.4);
    ctx.fillStyle = dark;
    ctx.globalAlpha = 0.5 * alpha;
    ctx.fill();
    ctx.globalAlpha = 1.0;
  }

  private miniPiece(ctx: CanvasRenderingContext2D, idx: number, cx: number, cy: number, s: number, alpha: number): void {
    const def: PieceDef = PIECES[idx];
    const cells = def.cells[0];
    let minX = 9;
    let maxX = -9;
    let minY = 9;
    let maxY = -9;
    for (let i = 0; i < cells.length; i++) {
      if (cells[i][0] < minX) {
        minX = cells[i][0];
      }
      if (cells[i][0] > maxX) {
        maxX = cells[i][0];
      }
      if (cells[i][1] < minY) {
        minY = cells[i][1];
      }
      if (cells[i][1] > maxY) {
        maxY = cells[i][1];
      }
    }
    const w = (maxX - minX + 1) * s;
    const h = (maxY - minY + 1) * s;
    const x0 = cx - w / 2 - minX * s;
    const y0 = cy - h / 2 - minY * s;
    for (let i = 0; i < cells.length; i++) {
      this.block(ctx, x0 + cells[i][0] * s, y0 + cells[i][1] * s, s, def.color, def.light, def.dark, alpha);
    }
  }

  private rr(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
    const rad = Math.min(r, w / 2, h / 2);
    ctx.beginPath();
    ctx.moveTo(x + rad, y);
    ctx.arcTo(x + w, y, x + w, y + h, rad);
    ctx.arcTo(x + w, y + h, x, y + h, rad);
    ctx.arcTo(x, y + h, x, y, rad);
    ctx.arcTo(x, y, x + w, y, rad);
    ctx.closePath();
  }
}
