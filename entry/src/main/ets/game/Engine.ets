/**
 * 游戏核心引擎：纯逻辑，不依赖 UI。
 * - 棋盘内部 22 行（顶部 2 行为隐藏缓冲区，符合 Tetris Guideline），可见 20 行
 * - 7-bag 随机发牌、SRS 旋转 + 踢墙、锁定延迟（400ms/最多重置 15 次）
 * - 幽灵投影、Hold、连击与 B2B 计分
 * - 两种模式：经典马拉松 / 危机模式（定时从底部顶起垃圾行）
 */

import { PIECES, kickTable } from './Tetromino';
import { PieceAI } from './AI';

export const COLS = 15;
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

/** 道具类型 */
export enum ItemType { Bomb, Mutate, Shuffle, ClearBottom, Slow }
export const ITEM_NAMES: string[] = ['爆炸', '变异', '捣乱', '清底', '减速'];
export const ITEM_DESCS: string[] = [
  '轰掉最高砖塔周围 5×5，砖块下落补位',
  'AI 算出当前局势最优形状，当场变身',
  '把后续所有方块顺序全部打乱',
  '直接移除底部两行堆叠',
  '重力放慢 2.5 倍，持续 10 秒',
];

export const BLAST_MS = 500;

/** 一次爆破特效事件：爆心 + 被清格子的原值（渲染层画碎片） */
export class BlastFx {
  cx: number = 0;        // 爆心列
  cy: number = 0;        // 爆心行（棋盘内部坐标）
  r: number = 1;         // 半径（1=3×3，2=5×5）
  cells: number[][] = []; // 被清格子 [行, 列]
  values: number[] = [];  // 被清格子原值（含藏弹编码）
  t: number = 0;          // 起爆时间戳
}

export class Piece {
  idx: number; // 0..6 对应 PIECES 下标
  rot: number;
  x: number;
  y: number;
  bombCell: number = -1; // 藏弹格下标（0..3，-1 无弹），锁定后写入棋盘值 +10

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
  pieceSeq = 0; // 每次出新方块自增，供 AI 辅助检测重新计算
  slowUntil = 0;             // 🐢 减速截止时间
  itemRate = 0.35;           // 道具基础掉落概率（设置面板可调，消行数越多在此基础上加成）
  // 道具生效大卡片（页面层展示，[图标, 名称, 描述]）
  banner: string[] | null = null;
  bannerAt = 0;
  blasts: BlastFx[] = []; // 进行中的爆破特效
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
    this.slowUntil = 0;
    this.banner = null;
    this.bannerAt = 0;
    this.blasts = [];
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
    this.slowUntil += dt;
    if (this.pausedFrom === Phase.Clearing) {
      this.clearStart += dt;
    }
    this.phase = this.pausedFrom;
  }

  /** 每帧推进，now = Date.now() */
  tick(now: number): void {
    // 清理过期爆破特效
    while (this.blasts.length > 0 && now - this.blasts[0].t > BLAST_MS + 400) {
      this.blasts.shift();
    }
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
    let g: number;
    if (this.softDrop) {
      g = 40;
    } else if (this.mode === GameMode.Hazard) {
      g = 420;
    } else {
      const i = Math.min(this.level, Engine.GRAVITY.length) - 1;
      g = Engine.GRAVITY[i];
    }
    if (Date.now() < this.slowUntil) {
      g = Math.floor(g * 2.5);
    }
    return g;
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

  // ---------------- 道具（掉落即当场生效） ----------------

  /** 当场执行指定道具（消行掉落时调用） */
  applyItem(t: number): void {
    if (t === ItemType.Bomb) {
      this.applyBombAtPeak();
      this.banner = ['💥', ITEM_NAMES[ItemType.Bomb], ITEM_DESCS[ItemType.Bomb]];
    } else if (t === ItemType.Mutate) {
      this.applyMutate();
      this.banner = ['🧬', ITEM_NAMES[ItemType.Mutate], ITEM_DESCS[ItemType.Mutate]];
    } else if (t === ItemType.Shuffle) {
      this.useShuffle();
      this.banner = ['🎲', ITEM_NAMES[ItemType.Shuffle], ITEM_DESCS[ItemType.Shuffle]];
    } else if (t === ItemType.ClearBottom) {
      this.useClearBottom();
      this.banner = ['🧹', ITEM_NAMES[ItemType.ClearBottom], ITEM_DESCS[ItemType.ClearBottom]];
    } else if (t === ItemType.Slow) {
      this.useSlow();
      this.banner = ['🐢', ITEM_NAMES[ItemType.Slow], ITEM_DESCS[ItemType.Slow]];
    }
    this.bannerAt = Date.now();
  }

  /** 💥 轰掉最高砖塔周围 5×5，被波及列下落补位 */
  private applyBombAtPeak(): void {
    let bestC = -1;
    let bestH = 0;
    for (let c = 0; c < COLS; c++) {
      let top = -1;
      for (let r = 0; r < BOARD_ROWS; r++) {
        if (this.board[r][c] !== 0) {
          top = r;
          break;
        }
      }
      const h = top < 0 ? 0 : BOARD_ROWS - top;
      if (h > bestH) {
        bestH = h;
        bestC = c;
      }
    }
    if (bestC < 0 || bestH <= 0) {
      return;
    }
    const ccx = bestC;
    const ccy = BOARD_ROWS - Math.ceil(bestH / 2);
    const R = 2;
    let cleared = 0;
    const fx = new BlastFx();
    fx.cx = ccx;
    fx.cy = ccy;
    fx.r = R;
    fx.t = Date.now();
    for (let bx = ccx - R; bx <= ccx + R; bx++) {
      if (bx < 0 || bx >= COLS) {
        continue;
      }
      for (let by = ccy - R; by <= ccy + R; by++) {
        if (by < 0 || by >= BOARD_ROWS) {
          continue;
        }
        if (this.board[by][bx] !== 0) {
          fx.values.push(this.board[by][bx]);
          fx.cells.push([by, bx]);
          this.board[by][bx] = 0;
          cleared += 1;
        }
      }
    }
    if (cleared === 0) {
      return;
    }
    this.blasts.push(fx);
    for (let c = 0; c < COLS; c++) {
      this.compactColumn(c);
    }
    this.score += cleared * 12;
    this.showToast(`💥 -${cleared}`);
  }

  /** 🧬 变异：把当前方块替换为 AI 认定最优的形状 */
  private applyMutate(): void {
    if (this.cur === null) {
      return;
    }
    let bestIdx = -1;
    let bestS = -Infinity;
    for (let i = 0; i < 7; i++) {
      const r = PieceAI.bestFor(this.board, i);
      if (r !== null && r.score > bestS) {
        bestS = r.score;
        bestIdx = i;
      }
    }
    if (bestIdx < 0) {
      return;
    }
    this.replaceCurrentPiece(bestIdx);
  }

  /** 变异：把当前方块替换为指定形状，原地不行则小幅平移/上移找合法位 */
  replaceCurrentPiece(newIdx: number): boolean {
    if (this.phase !== Phase.Running || this.cur === null) {
      return false;
    }
    const old = this.cur;
    const dxs = [0, -1, 1, -2, 2];
    for (let d = 0; d < dxs.length; d++) {
      const nx = old.x + dxs[d];
      for (let y = Math.max(old.y, 1); y >= 1; y--) {
        if (!this.collidesAt(new Piece(newIdx, 0, nx, y), nx, y, 0)) {
          const np = new Piece(newIdx, 0, nx, y);
          np.bombCell = old.bombCell; // 变异保留藏弹
          this.cur = np;
          this.grounded = false;
          this.lockResets = 0;
          this.lastFall = Date.now();
          return true;
        }
      }
    }
    return false;
  }

  /** 列内重力：非零砖块沉底，空格上浮 */
  private compactColumn(c: number): void {
    const col: number[] = [];
    for (let r = BOARD_ROWS - 1; r >= 0; r--) {
      if (this.board[r][c] !== 0) {
        col.push(this.board[r][c]);
      }
    }
    for (let r = BOARD_ROWS - 1; r >= 0; r--) {
      const k = BOARD_ROWS - 1 - r;
      this.board[r][c] = k < col.length ? col[k] : 0;
    }
  }

  /** 🎲 捣乱：打乱后续队列 */
  private useShuffle(): boolean {
    if (this.queue.length < 2) {
      return false;
    }
    for (let i = this.queue.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const t = this.queue[i];
      this.queue[i] = this.queue[j];
      this.queue[j] = t;
    }
    this.showToast('🎲');
    return true;
  }

  /** 🧹 清底：移除底部两行 */
  private useClearBottom(): boolean {
    this.board.splice(BOARD_ROWS - 2, 2);
    for (let i = 0; i < 2; i++) {
      const row: number[] = [];
      for (let c = 0; c < COLS; c++) {
        row.push(0);
      }
      this.board.unshift(row);
    }
    this.score += 80;
    this.showToast('🧹');
    return true;
  }

  /** 🐢 减速：重力放慢 2.5 倍，持续 10 秒 */
  private useSlow(): boolean {
    this.slowUntil = Math.max(this.slowUntil, Date.now()) + 10000;
    this.showToast('🐢');
    return true;
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
    this.pieceSeq += 1;
    // 出生点：可见区顶部再往上（缓冲区），水平居中
    const isI = idx === 0;
    const px = isI ? Math.floor((COLS - 4) / 2)
      : (idx === 1 ? Math.floor((COLS - 2) / 2) : Math.floor((COLS - 3) / 2));
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
    // 15% 概率藏一枚隐形炸弹
    if (Math.random() < 0.15) {
      p.bombCell = Math.floor(Math.random() * 4);
    }
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
      this.board[by][bx] = p.idx + 1 + (i === p.bombCell ? 10 : 0);
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
    // 满行初检 → 藏弹引爆（满行炸弹 / 相邻炸弹对，3×3 连锁）→ 重检满行
    let full = this.findFullRows();
    if (this.detonateBombs(full)) {
      full = this.findFullRows();
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

    // 道具掉落即当场生效：四消必得，其余按设置的基础概率（双行以上 +0.2 加成）
    const chance = n >= 4 ? 1 : Math.min(1, this.itemRate + (n >= 2 ? 0.2 : 0));
    if (Math.random() < chance) {
      this.applyItem(Math.floor(Math.random() * 5));
    }
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

  private findFullRows(): number[] {
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
    return full;
  }

  /**
   * 藏弹引爆。棋盘值 >10 的格子是炸弹。
   * 引爆条件：① 位于本次消除的满行；② 两枚炸弹正交相邻（互相引爆）。
   * 爆破 3×3，波及到的其他炸弹连锁；被清列做重力下落补位。
   */
  private detonateBombs(full: number[]): boolean {
    const bombs = new Set<number>(); // key = r * COLS + c
    for (let r = 0; r < BOARD_ROWS; r++) {
      for (let c = 0; c < COLS; c++) {
        if (this.board[r][c] > 10) {
          bombs.add(r * COLS + c);
        }
      }
    }
    if (bombs.size === 0) {
      return false;
    }
    const fullSet = new Set<number>(full);
    const detonating = new Set<number>();
    for (const key of bombs) {
      const r = Math.floor(key / COLS);
      if (fullSet.has(r)) {
        detonating.add(key); // ① 随满行被消除
        continue;
      }
      const c = key % COLS;
      const nb: number[] = [key - COLS, key + COLS];
      if (c > 0) {
        nb.push(key - 1);
      }
      if (c < COLS - 1) {
        nb.push(key + 1);
      }
      for (let i = 0; i < nb.length; i++) {
        if (bombs.has(nb[i])) {
          detonating.add(key); // ② 相邻炸弹互相引爆
          detonating.add(nb[i]);
        }
      }
    }
    // 连锁：爆破波及到的炸弹继续引爆
    const exploded = new Set<number>();
    while (detonating.size > 0) {
      let key = -1;
      for (const k of detonating) {
        key = k;
        break;
      }
      detonating.delete(key);
      if (key < 0 || exploded.has(key)) {
        continue;
      }
      exploded.add(key);
      const r = Math.floor(key / COLS);
      const c = key % COLS;
      for (let dr = -1; dr <= 1; dr++) {
        for (let dc = -1; dc <= 1; dc++) {
          const nr = r + dr;
          const nc = c + dc;
          if (nr < 0 || nr >= BOARD_ROWS || nc < 0 || nc >= COLS) {
            continue;
          }
          const nkey = nr * COLS + nc;
          if (this.board[nr][nc] > 10 && !exploded.has(nkey)) {
            detonating.add(nkey);
          }
        }
      }
    }
    // 清除爆破区域（记录特效）+ 列内下落补位
    let cleared = 0;
    const colsAffected = new Set<number>();
    const now = Date.now();
    for (const key of exploded) {
      const r = Math.floor(key / COLS);
      const c = key % COLS;
      const fx = new BlastFx();
      fx.cx = c;
      fx.cy = r;
      fx.r = 1;
      fx.t = now;
      for (let dr = -1; dr <= 1; dr++) {
        for (let dc = -1; dc <= 1; dc++) {
          const nr = r + dr;
          const nc = c + dc;
          if (nr < 0 || nr >= BOARD_ROWS || nc < 0 || nc >= COLS) {
            continue;
          }
          if (this.board[nr][nc] !== 0) {
            fx.values.push(this.board[nr][nc]);
            fx.cells.push([nr, nc]);
            this.board[nr][nc] = 0;
            cleared += 1;
            colsAffected.add(nc);
          }
        }
      }
      this.blasts.push(fx);
    }
    if (cleared === 0) {
      return false;
    }
    for (const c of colsAffected) {
      this.compactColumn(c);
    }
    this.score += cleared * 10;
    this.showToast(`💣 x${exploded.size} -${cleared}`);
    this.banner = ['💣', '连环爆破', '藏弹引爆 3×3 连锁'];
    this.bannerAt = Date.now();
    return true;
  }
}
