/**
 * 游戏核心引擎：纯逻辑，不依赖 UI。
 * - 棋盘内部 22 行（顶部 2 行为隐藏缓冲区，符合 Tetris Guideline），可见 20 行
 * - 7-bag 随机发牌、SRS 旋转 + 踢墙、锁定延迟（400ms/最多重置 15 次）
 * - 幽灵投影、Hold、连击与 B2B 计分
 * - 两种模式：经典马拉松 / 危机模式（定时从底部顶起垃圾行）
 */

import { PIECES, kickTable } from './Tetromino';

export const COLS = 10;
export const ROWS = 20;          // 可见行数（渲染用）
export const BUFFER_ROWS = 2;    // 顶部隐藏缓冲区行数
export const BOARD_ROWS = ROWS + BUFFER_ROWS; // 棋盘内部总行数 22
export const LOCK_DELAY_MS = 400;
export const MAX_LOCK_RESETS = 15;
export const CLEAR_ANIM_MS = 180;
export const GARBAGE_INTERVAL_MS = 12000;
export const TOAST_MS = 1000;

export enum Phase { Ready, Running, Paused, Clearing, Over }
export enum GameMode { Classic, Hazard }

export class Piece {
  idx: number; // 0..6 对应 PIECES 下标
  rot: number;
  x: number;
  y: number;

  constructor(idx: number, rot: number, x: number, y: number) {
    this.idx = idx;
    this.rot = rot;
    this.x = x;
    this.y = y;
  }
}

export class Engine {
  static readonly GRAVITY: number[] =
    [900, 800, 700, 620, 540, 460, 380, 320, 260, 210, 170, 140, 115, 95, 80];

  board: number[][] = []; // BOARD_ROWS×COLS，取值：0=空，1..7=PIECES 下标+1，-1=垃圾砖
  phase: Phase = Phase.Ready;
  mode: GameMode = GameMode.Classic;
  score = 0;
  lines = 0;
  level = 1;
  combo = -1;
  b2b = false;
  cur: Piece | null = null;
  holdIdx = -1;
  canHold = true;
  queue: number[] = [];
  clearingRows: number[] = [];
  clearStart = 0;
  lastFall = 0;
  lockStart = 0;
  grounded = false;
  lockResets = 0;
  softDrop = false;
  // 危机模式
  pendingGarbage = 0;
  nextGarbageAt = 0;
  garbageFired = 0;
  // 浮动提示（渲染层显示）
  toast = '';
  toastAt = 0;

  private pausedFrom: Phase = Phase.Running;
  private pausedAt = 0;

  constructor() {
    this.prepareEmptyBoard();
  }

  start(mode: GameMode): void {
    this.mode = mode;
    this.prepareEmptyBoard();
    this.score = 0;
    this.lines = 0;
    this.level = 1;
    this.combo = -1;
    this.b2b = false;
    this.holdIdx = -1;
    this.canHold = true;
    this.queue = [];
    this.clearingRows = [];
    this.grounded = false;
    this.lockResets = 0;
    this.softDrop = false;
    this.pendingGarbage = 0;
    this.garbageFired = 0;
    this.toast = '';
    const now = Date.now();
    this.lastFall = now;
    this.nextGarbageAt = now + GARBAGE_INTERVAL_MS;
    this.ensureQueue();
    this.phase = Phase.Running;
    this.spawnFromQueue(now);
  }

  toMenu(): void {
    this.phase = Phase.Ready;
    this.cur = null;
  }

  pause(): void {
    if (this.phase === Phase.Running || this.phase === Phase.Clearing) {
      this.pausedFrom = this.phase;
      this.phase = Phase.Paused;
      this.pausedAt = Date.now();
    }
  }

  resume(): void {
    if (this.phase !== Phase.Paused) {
      return;
    }
    const dt = Date.now() - this.pausedAt;
    this.lastFall += dt;
    if (this.grounded) {
      this.lockStart += dt;
    }
    this.nextGarbageAt += dt;
    if (this.pausedFrom === Phase.Clearing) {
      this.clearStart += dt;
    }
    this.phase = this.pausedFrom;
  }

  /** 每帧推进，now = Date.now() */
  tick(now: number): void {
    if (this.phase === Phase.Clearing) {
      if (now - this.clearStart >= CLEAR_ANIM_MS) {
        this.finishClear();
      }
      return;
    }
    if (this.phase !== Phase.Running || this.cur === null) {
      return;
    }

    // 危机模式：垃圾行倒计时到达 → 挂起，等当前方块锁定后结算
    if (this.mode === GameMode.Hazard && now >= this.nextGarbageAt) {
      const rows = Math.min(4, 1 + Math.floor(this.garbageFired / 3));
      this.pendingGarbage = Math.min(6, this.pendingGarbage + rows);
      this.nextGarbageAt = now + GARBAGE_INTERVAL_MS;
      this.showToast('⚠ 垃圾行来袭');
    }

    const c = this.cur;
    const onGround = this.collidesAt(c, c.x, c.y + 1, c.rot);
    if (onGround) {
      if (!this.grounded) {
        this.grounded = true;
        this.lockStart = now;
      }
      if (now - this.lockStart >= LOCK_DELAY_MS) {
        this.lockPiece(now);
      }
      return;
    }
    this.grounded = false;

    // 重力下落
    let step = this.gravityMs();
    while (now - this.lastFall >= step) {
      this.lastFall += step;
      if (this.cur === null) {
        return;
      }
      const p = this.cur;
      if (this.collidesAt(p, p.x, p.y + 1, p.rot)) {
        return; // 触底，下一帧进入锁定计时
      }
      p.y += 1;
      step = this.gravityMs();
    }
  }

  gravityMs(): number {
    if (this.softDrop) {
      return 40;
    }
    if (this.mode === GameMode.Hazard) {
      return 420;
    }
    const i = Math.min(this.level, Engine.GRAVITY.length) - 1;
    return Engine.GRAVITY[i];
  }

  // ---------------- 玩家操作 ----------------

  moveH(dx: number): boolean {
    if (this.phase !== Phase.Running || this.cur === null) {
      return false;
    }
    const p = this.cur;
    if (this.collidesAt(p, p.x + dx, p.y, p.rot)) {
      return false;
    }
    p.x += dx;
    this.onSuccessfulMove();
    return true;
  }

  /** dir: 1=顺时针, -1=逆时针 */
  rotate(dir: number): boolean {
    if (this.phase !== Phase.Running || this.cur === null) {
      return false;
    }
    const p = this.cur;
    const nr = (p.rot + dir + 4) % 4;
    const kicks = kickTable(PIECES[p.idx].isI, p.rot, nr);
    for (let i = 0; i < kicks.length; i++) {
      const dx = kicks[i][0];
      const dy = kicks[i][1];
      if (!this.collidesAt(p, p.x + dx, p.y + dy, nr)) {
        p.rot = nr;
        p.x += dx;
        p.y += dy;
        this.onSuccessfulMove();
        return true;
      }
    }
    return false;
  }

  softDropStep(): boolean {
    if (this.phase !== Phase.Running || this.cur === null) {
      return false;
    }
    const p = this.cur;
    if (this.collidesAt(p, p.x, p.y + 1, p.rot)) {
      return false;
    }
    p.y += 1;
    this.score += 1;
    this.lastFall = Date.now();
    return true;
  }

  hardDrop(): void {
    if (this.phase !== Phase.Running || this.cur === null) {
      return;
    }
    const dist = this.ghostY() - this.cur.y;
    this.cur.y += dist;
    this.score += 2 * dist;
    this.lastFall = Date.now();
    this.lockPiece(Date.now());
  }

  hold(): void {
    if (this.phase !== Phase.Running || this.cur === null || !this.canHold) {
      return;
    }
    const curIdx = this.cur.idx;
    const swapped = this.holdIdx;
    this.holdIdx = curIdx;
    this.canHold = false;
    if (swapped < 0) {
      this.cur = null;
      this.ensureQueue();
      this.spawnFromQueue(Date.now());
    } else {
      this.spawnPiece(swapped, Date.now());
    }
  }

  ghostY(): number {
    if (this.cur === null) {
      return 0;
    }
    const p = this.cur;
    let gy = p.y;
    while (!this.collidesAt(p, p.x, gy + 1, p.rot)) {
      gy += 1;
    }
    return gy;
  }

  // ---------------- 内部逻辑 ----------------

  private prepareEmptyBoard(): void {
    this.board = [];
    for (let r = 0; r < BOARD_ROWS; r++) {
      const row: number[] = [];
      for (let c = 0; c < COLS; c++) {
        row.push(0);
      }
      this.board.push(row);
    }
  }

  private ensureQueue(): void {
    while (this.queue.length < 7) {
      const bag: number[] = [];
      for (let i = 0; i < 7; i++) {
        bag.push(i);
      }
      // Fisher-Yates 洗牌（7-bag）
      for (let i = 6; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const t = bag[i];
        bag[i] = bag[j];
        bag[j] = t;
      }
      for (let i = 0; i < bag.length; i++) {
        this.queue.push(bag[i]);
      }
    }
  }

  private spawnFromQueue(now: number): void {
    // 危机模式：在锁定边界结算挂起的垃圾行
    if (this.mode === GameMode.Hazard && this.pendingGarbage > 0) {
      this.pushGarbage(this.pendingGarbage);
      this.pendingGarbage = 0;
    }
    this.ensureQueue();
    const idx = this.queue.splice(0, 1)[0];
    this.spawnPiece(idx, now);
  }

  private spawnPiece(idx: number, now: number): void {
    // 出生点：可见区顶部再往上（缓冲区），大部分方块只有底部露出
    const isI = idx === 0;
    const px = isI ? 3 : (idx === 1 ? 4 : 3);
    const py = 1;
    const p = new Piece(idx, 0, px, py);
    this.grounded = false;
    this.lockResets = 0;
    this.lastFall = now;
    if (this.collidesAt(p, px, py, 0)) {
      this.cur = p;
      this.phase = Phase.Over;
      this.showToast('游戏结束');
      return;
    }
    this.cur = p;
    this.lockStart = 0;
  }

  private onSuccessfulMove(): void {
    if (!this.grounded || this.cur === null) {
      return;
    }
    if (this.lockResets >= MAX_LOCK_RESETS) {
      return;
    }
    // 触底后移动/旋转成功 → 重置锁定计时（次数封顶防无限延迟）
    this.lockStart = Date.now();
    this.lockResets += 1;
  }

  private lockPiece(now: number): void {
    const p = this.cur;
    if (p === null) {
      return;
    }
    const cells = PIECES[p.idx].cells[p.rot];
    // 防御：锁定位置非法说明堆已顶出（正常流程不可达）
    if (this.collidesAt(p, p.x, p.y, p.rot)) {
      this.cur = null;
      this.phase = Phase.Over;
      this.showToast('游戏结束');
      return;
    }
    let aboveVisible = 0;
    for (let i = 0; i < cells.length; i++) {
      const bx = p.x + cells[i][0];
      const by = p.y + cells[i][1];
      if (by < 0) {
        aboveVisible += 1;
        continue;
      }
      this.board[by][bx] = p.idx + 1;
      if (by < BUFFER_ROWS) {
        aboveVisible += 1;
      }
    }
    this.cur = null;
    this.grounded = false;
    this.canHold = true; // 落定后恢复 Hold 资格
    // Lock Out：整个方块都锁在可见区之上 → 游戏结束
    if (aboveVisible >= cells.length) {
      this.phase = Phase.Over;
      this.showToast('游戏结束');
      return;
    }
    // 检测满行
    const full: number[] = [];
    for (let r = 0; r < BOARD_ROWS; r++) {
      let ok = true;
      for (let c = 0; c < COLS; c++) {
        if (this.board[r][c] === 0) {
          ok = false;
          break;
        }
      }
      if (ok) {
        full.push(r);
      }
    }
    if (full.length > 0) {
      this.combo += 1;
      this.clearingRows = full;
      this.clearStart = now;
      this.phase = Phase.Clearing;
    } else {
      this.combo = -1;
      this.spawnFromQueue(now);
    }
  }

  private finishClear(): void {
    const n = this.clearingRows.length;
    const kept: number[][] = [];
    for (let r = 0; r < BOARD_ROWS; r++) {
      if (this.clearingRows.indexOf(r) < 0) {
        kept.push(this.board[r]);
      }
    }
    while (kept.length < BOARD_ROWS) {
      const row: number[] = [];
      for (let c = 0; c < COLS; c++) {
        row.push(0);
      }
      kept.unshift(row);
    }
    this.board = kept;
    this.clearingRows = [];

    // 计分：基础分 × 等级，四连消 B2B ×1.5，连击奖励
    const base = [0, 100, 300, 500, 800][n];
    let pts = base * this.level;
    if (n === 4) {
      if (this.b2b) {
        pts = Math.floor(pts * 1.5);
        this.showToast(`B2B TETRIS +${pts}`);
      } else {
        this.showToast(`TETRIS +${pts}`);
      }
      this.b2b = true;
    } else {
      this.b2b = false;
      if (n === 2) {
        this.showToast(`双消 +${pts}`);
      } else if (n === 3) {
        this.showToast(`三消 +${pts}`);
      } else {
        this.showToast(`+${pts}`);
      }
    }
    if (this.combo > 0) {
      pts += 50 * this.combo * this.level;
      this.showToast(`连击 x${this.combo + 1}`);
    }
    this.score += pts;
    this.lines += n;
    const newLevel = Math.floor(this.lines / 10) + 1;
    if (newLevel > this.level) {
      this.showToast(`⬆ Lv.${newLevel}`);
    }
    this.level = newLevel;

    this.phase = Phase.Running;
    this.spawnFromQueue(Date.now());
  }

  private pushGarbage(n: number): void {
    for (let i = 0; i < n; i++) {
      this.board.shift(); // 顶行（缓冲区）移出
      const row: number[] = [];
      const hole = Math.floor(Math.random() * COLS);
      for (let c = 0; c < COLS; c++) {
        row.push(c === hole ? 0 : -1);
      }
      this.board.push(row);
      this.garbageFired += 1;
    }
  }

  private collidesAt(p: Piece, nx: number, ny: number, nrot: number): boolean {
    const cells = PIECES[p.idx].cells[nrot];
    for (let i = 0; i < cells.length; i++) {
      const bx = nx + cells[i][0];
      const by = ny + cells[i][1];
      if (bx < 0 || bx >= COLS || by >= BOARD_ROWS) {
        return true;
      }
      if (by >= 0 && this.board[by][bx] !== 0) {
        return true;
      }
    }
    return false;
  }

  private showToast(text: string): void {
    this.toast = text;
    this.toastAt = Date.now();
  }
}
