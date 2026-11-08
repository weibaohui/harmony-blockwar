/**
 * AI 辅助：对新方块遍历「旋转 × 列」全部组合，模拟直落 + 消行后的盘面，
 * 用经典启发式权重打分（消行 +、空洞 -、平均高度 -、凹凸度 -），取最优解。
 * 结果由渲染层画成金色描边推荐落点。
 */

import { Engine, COLS, BOARD_ROWS } from './Engine';
import { PIECES } from './Tetromino';

export class AIResult {
  rot: number = 0;
  x: number = 0;
  landY: number = 0;
  score: number = 0;
}

export class PieceAI {
  /** 对当前棋盘上的当前方块计算最佳落点 */
  static best(engine: Engine): AIResult | null {
    if (engine.cur === null) {
      return null;
    }
    return PieceAI.bestFor(engine.board, engine.cur.idx);
  }

  /** 对任意形状计算最佳落点（🧬 变异道具用它比较七种形状） */
  static bestFor(board: number[][], idx: number): AIResult | null {
    let bestR = -1;
    let bestX = -1;
    let bestY = -1;
    let bestScore = -Infinity;

    for (let rot = 0; rot < 4; rot++) {
      const cells = PIECES[idx].cells[rot];
      for (let x = -2; x <= COLS; x++) {
        // 必须能在出生高度摆出该姿态（否则旋转/平移不可达，忽略）
        if (!PieceAI.fits(board, cells, x, 1)) {
          continue;
        }
        // 直落到最低合法位置
        let y = 1;
        while (PieceAI.fits(board, cells, x, y + 1)) {
          y += 1;
        }
        // 落底并模拟消行（重建法，避免 splice 索引偏移）
        const sim = PieceAI.cloneBoard(board);
        for (let i = 0; i < cells.length; i++) {
          const bx = x + cells[i][0];
          const by = y + cells[i][1];
          if (by >= 0) {
            sim[by][bx] = idx + 1;
          }
        }
        let lines = 0;
        const kept: number[][] = [];
        for (let r = 0; r < sim.length; r++) {
          let full = true;
          for (let c = 0; c < COLS; c++) {
            if (sim[r][c] === 0) {
              full = false;
              break;
            }
          }
          if (full) {
            lines += 1;
          } else {
            kept.push(sim[r]);
          }
        }
        while (kept.length < BOARD_ROWS) {
          const row: number[] = [];
          for (let c = 0; c < COLS; c++) {
            row.push(0);
          }
          kept.unshift(row);
        }
        const s = PieceAI.evaluate(kept, lines);
        if (s > bestScore) {
          bestScore = s;
          bestR = rot;
          bestX = x;
          bestY = y;
        }
      }
    }
    if (bestR < 0) {
      return null;
    }
    const res = new AIResult();
    res.rot = bestR;
    res.x = bestX;
    res.landY = bestY;
    res.score = bestScore;
    return res;
  }

  private static fits(board: number[][], cells: number[][], x: number, y: number): boolean {
    for (let i = 0; i < cells.length; i++) {
      const bx = x + cells[i][0];
      const by = y + cells[i][1];
      if (bx < 0 || bx >= COLS || by >= BOARD_ROWS) {
        return false;
      }
      if (by >= 0 && board[by][bx] !== 0) {
        return false;
      }
    }
    return true;
  }

  private static cloneBoard(board: number[][]): number[][] {
    const out: number[][] = [];
    for (let r = 0; r < board.length; r++) {
      out.push(board[r].slice());
    }
    return out;
  }

  /** 启发式打分：消行 +，空洞与凹凸度重罚，平均高度轻罚 */
  private static evaluate(board: number[][], lines: number): number {
    const heights: number[] = [];
    let holes = 0;
    for (let c = 0; c < COLS; c++) {
      let top = -1;
      for (let r = 0; r < board.length; r++) {
        if (board[r][c] !== 0) {
          top = r;
          break;
        }
      }
      heights.push(top < 0 ? 0 : board.length - top);
      // 空洞：最高砖块下方的空格
      if (top >= 0) {
        for (let r = top + 1; r < board.length; r++) {
          if (board[r][c] === 0) {
            holes += 1;
          }
        }
      }
    }
    let agg = 0;
    let bump = 0;
    let maxH = 0;
    for (let c = 0; c < COLS; c++) {
      agg += heights[c];
      maxH = Math.max(maxH, heights[c]);
      if (c > 0) {
        bump += Math.abs(heights[c] - heights[c - 1]);
      }
    }
    agg /= COLS;
    // 经典权重（Lee 2013）：a=-0.51, b=0.76, c=-0.36, d=-0.18
    return -0.510066 * agg + 0.760666 * lines - 0.35663 * holes - 0.184483 * bump - 0.05 * maxH;
  }
}
