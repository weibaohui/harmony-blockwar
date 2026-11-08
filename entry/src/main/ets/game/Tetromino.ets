/**
 * 七种俄罗斯方块的形状定义 + SRS（Super Rotation System）旋转与踢墙表。
 * 坐标系：x 向右，y 向下（屏幕坐标系），SRS 的 y 轴正方向已做翻转。
 * 每个方块 4 个旋转态（0=初始, 1=R, 2=180°, 3=L），每态 4 个格子。
 */

export class PieceDef {
  readonly cells: number[][][]; // [rotation][cellIndex][x, y]
  readonly color: string;
  readonly light: string; // 顶部高光
  readonly dark: string;  // 底部阴影
  readonly isI: boolean;

  constructor(cells: number[][][], color: string, light: string, dark: string, isI: boolean) {
    this.cells = cells;
    this.color = color;
    this.light = light;
    this.dark = dark;
    this.isI = isI;
  }
}

const I_CELLS: number[][][] = [
  [[0, 1], [1, 1], [2, 1], [3, 1]],
  [[2, 0], [2, 1], [2, 2], [2, 3]],
  [[0, 2], [1, 2], [2, 2], [3, 2]],
  [[1, 0], [1, 1], [1, 2], [1, 3]],
];

const O_CELLS: number[][][] = [
  [[0, 0], [1, 0], [0, 1], [1, 1]],
  [[0, 0], [1, 0], [0, 1], [1, 1]],
  [[0, 0], [1, 0], [0, 1], [1, 1]],
  [[0, 0], [1, 0], [0, 1], [1, 1]],
];

const T_CELLS: number[][][] = [
  [[1, 0], [0, 1], [1, 1], [2, 1]],
  [[1, 0], [1, 1], [2, 1], [1, 2]],
  [[0, 1], [1, 1], [2, 1], [1, 2]],
  [[1, 0], [0, 1], [1, 1], [1, 2]],
];

const S_CELLS: number[][][] = [
  [[1, 0], [2, 0], [0, 1], [1, 1]],
  [[1, 0], [1, 1], [2, 1], [2, 2]],
  [[1, 1], [2, 1], [0, 2], [1, 2]],
  [[0, 0], [0, 1], [1, 1], [1, 2]],
];

const Z_CELLS: number[][][] = [
  [[0, 0], [1, 0], [1, 1], [2, 1]],
  [[2, 0], [1, 1], [2, 1], [1, 2]],
  [[0, 1], [1, 1], [1, 2], [2, 2]],
  [[1, 0], [0, 1], [1, 1], [0, 2]],
];

const J_CELLS: number[][][] = [
  [[0, 0], [0, 1], [1, 1], [2, 1]],
  [[1, 0], [2, 0], [1, 1], [1, 2]],
  [[0, 1], [1, 1], [2, 1], [2, 2]],
  [[1, 0], [1, 1], [0, 2], [1, 2]],
];

const L_CELLS: number[][][] = [
  [[2, 0], [0, 1], [1, 1], [2, 1]],
  [[1, 0], [1, 1], [1, 2], [2, 2]],
  [[0, 1], [1, 1], [2, 1], [0, 2]],
  [[0, 0], [1, 0], [1, 1], [1, 2]],
];

/** 板上的取值：0=空，1..7=对应 PIECES 下标+1，-1=垃圾行砖块 */
export const PIECES: PieceDef[] = [
  new PieceDef(I_CELLS, '#21C9DE', '#7FEFF9', '#0E8FA3', true),
  new PieceDef(O_CELLS, '#F7C531', '#FFE58A', '#C08F0D', false),
  new PieceDef(T_CELLS, '#A45CD6', '#D19CF0', '#6E339B', false),
  new PieceDef(S_CELLS, '#53C653', '#9AEB9A', '#2F8C2F', false),
  new PieceDef(Z_CELLS, '#E85151', '#FF9C9C', '#AC2B2B', false),
  new PieceDef(J_CELLS, '#4A7BE0', '#94B3F0', '#2B4E9E', false),
  new PieceDef(L_CELLS, '#EF8C3B', '#FFC08A', '#B85E15', false),
];

/** 垃圾行砖块配色（危机模式） */
export const GARBAGE_COLOR = '#565E72';
export const GARBAGE_LIGHT = '#7A8298';
export const GARBAGE_DARK = '#3A4152';

/** 踢墙表（JLSTZ 通用），key 为 "from>to"，值为 [dx, dy] 尝试序列，y 向下为正 */
const KICKS_JLSTZ: Record<string, number[][]> = {
  '0>1': [[0, 0], [-1, 0], [-1, -1], [0, 2], [-1, 2]],
  '1>0': [[0, 0], [1, 0], [1, 1], [0, -2], [1, -2]],
  '1>2': [[0, 0], [1, 0], [1, 1], [0, -2], [1, -2]],
  '2>1': [[0, 0], [-1, 0], [-1, -1], [0, 2], [-1, 2]],
  '2>3': [[0, 0], [1, 0], [1, -1], [0, 2], [1, 2]],
  '3>2': [[0, 0], [-1, 0], [-1, 1], [0, -2], [-1, -2]],
  '3>0': [[0, 0], [-1, 0], [-1, 1], [0, -2], [-1, -2]],
  '0>3': [[0, 0], [1, 0], [1, -1], [0, 2], [1, 2]],
};

/** I 型专用踢墙表 */
const KICKS_I: Record<string, number[][]> = {
  '0>1': [[0, 0], [-2, 0], [1, 0], [-2, 1], [1, -2]],
  '1>0': [[0, 0], [2, 0], [-1, 0], [2, -1], [-1, 2]],
  '1>2': [[0, 0], [-1, 0], [2, 0], [-1, -2], [2, 1]],
  '2>1': [[0, 0], [1, 0], [-2, 0], [1, 2], [-2, -1]],
  '2>3': [[0, 0], [2, 0], [-1, 0], [2, -1], [-1, 2]],
  '3>2': [[0, 0], [-2, 0], [1, 0], [-2, 1], [1, -2]],
  '3>0': [[0, 0], [1, 0], [-2, 0], [1, 2], [-2, -1]],
  '0>3': [[0, 0], [-1, 0], [2, 0], [-1, -2], [2, 1]],
};

export function kickTable(isI: boolean, from: number, to: number): number[][] {
  const key = `${from}>${to}`;
  const table = isI ? KICKS_I : KICKS_JLSTZ;
  const k = table[key];
  if (k === undefined) {
    return [[0, 0]];
  }
  return k;
}
