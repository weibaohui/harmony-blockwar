import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Engine, Phase, GameMode } from '../game/Engine';
import { Renderer } from '../game/Renderer';
import { PieceAI, AIResult } from '../game/AI';

// ---------- 配色 ----------
const PAGE_BG = '#0E1122';
const CARD = '#171C31';
const CARD_LINE = '#2A3152';
const TEXT = '#E8EAF2';
const SUB = '#9AA0B5';
const CYAN = '#4AD4E8';
const RED = '#FF5A5A';
const GOLD = '#FFD24A';

@Entry
@Component
struct Index {
  // ---------- HUD 状态 ----------
  @State phase: number = Phase.Ready;
  @State mode: number = GameMode.Classic;
  @State score: number = 0;
  @State bestClassic: number = 0;
  @State bestHazard: number = 0;
  @State lines: number = 0;
  @State level: number = 1;
  @State newBest: boolean = false;
  @State warn: boolean = false;
  @State warnIn: number = 0;
  @State warnCount: number = 0;
  @State aiOn: boolean = false;
  @State itemIcons: string[] = [];
  @State settingsOpen: boolean = false;
  @State itemRatePct: number = 35;
  @State banner: string[] | null = null; // 道具生效卡片 [图标, 名称, 描述]

  // ---------- 引擎与画布 ----------
  private eng: Engine = new Engine();
  private rd: Renderer = new Renderer();
  private renderSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderSettings);
  private cvW: number = 0;
  private cvH: number = 0;
  private timerId: number = -1;
  private store: preferences.Preferences | null = null;
  private aiResult: AIResult | null = null;
  private aiSeq: number = -1;
  private autopilot: boolean = false; // AI 自动驾驶：真实方块自动转向/平移到推荐位
  private aiFails: number = 0;
  private settingsWasRunning: boolean = false;
  private bannerUntil: number = 0;
  private bannerSeenAt: number = 0;

  // 手势累计
  private lastGX: number = 0;
  private lastGY: number = 0;
  private accX: number = 0;
  private accY: number = 0;
  private gStart: number = 0;

  aboutToAppear(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const opt: preferences.Options = { name: 'blockwar' };
      this.store = preferences.getPreferencesSync(ctx, opt);
      this.bestClassic = this.store.getSync('best_classic', 0) as number;
      this.bestHazard = this.store.getSync('best_hazard', 0) as number;
      this.aiOn = this.store.getSync('ai_assist', false) as boolean;
      this.itemRatePct = this.store.getSync('item_rate', 35) as number;
      this.eng.itemRate = this.itemRatePct / 100;
    } catch (e) {
      // 存储不可用时仅丢失最高分记录
    }
  }

  aboutToDisappear(): void {
    this.stopLoop();
  }

  onPageHide(): void {
    // 切后台自动暂停
    if (this.eng.phase === Phase.Running || this.eng.phase === Phase.Clearing) {
      this.eng.pause();
    }
  }

  onBackPress(): boolean {
    // 游戏中返回键先暂停，不退出应用
    if (this.eng.phase === Phase.Running || this.eng.phase === Phase.Clearing) {
      this.eng.pause();
      return true;
    }
    return false;
  }

  build() {
    Column() {
      this.hudBar()
      Stack() {
        Canvas(this.canvasCtx)
          .width('100%')
          .height('100%')
          .onReady(() => {
            this.startLoop();
          })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.cvW = newValue.width as number;
            this.cvH = newValue.height as number;
          })

        if (this.phase === Phase.Ready) {
          this.readyOverlay()
        }
        if (this.phase === Phase.Paused) {
          this.pauseOverlay()
        }
        if (this.phase === Phase.Over) {
          this.overOverlay()
        }
        if (this.settingsOpen) {
          this.settingsOverlay()
        }
        if (this.banner !== null) {
          this.bannerOverlay()
        }
      }
      .layoutWeight(1)
      .width('100%')
      // 手势：点按旋转 / 拖动移动与软降 / 快速下滑硬降 / 上滑暂存（玩家操作即接管，取消自动定位）
      .gesture(
        TapGesture({ count: 1 })
          .onAction(() => {
            if (this.eng.phase === Phase.Running) {
              this.autopilot = false;
              this.eng.rotate(1);
            }
          })
      )
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 6 })
          .onActionStart((e: GestureEvent) => {
            this.autopilot = false;
            this.lastGX = e.offsetX;
            this.lastGY = e.offsetY;
            this.gStart = Date.now();
          })
          .onActionUpdate((e: GestureEvent) => {
            if (this.eng.phase !== Phase.Running) {
              return;
            }
            const step = Math.max(10, this.rd.cellSize() * 0.85);
            this.accX += e.offsetX - this.lastGX;
            this.lastGX = e.offsetX;
            this.accY += e.offsetY - this.lastGY;
            this.lastGY = e.offsetY;
            while (this.accX >= step) {
              this.eng.moveH(1);
              this.accX -= step;
            }
            while (this.accX <= -step) {
              this.eng.moveH(-1);
              this.accX += step;
            }
            while (this.accY >= step) {
              this.eng.softDropStep();
              this.accY -= step;
            }
            if (this.accY < -step) {
              this.accY = -step;
            }
          })
          .onActionEnd((e: GestureEvent) => {
            this.accX = 0;
            this.accY = 0;
            if (this.eng.phase !== Phase.Running) {
              return;
            }
            const step = Math.max(10, this.rd.cellSize() * 0.85);
            const dy = e.offsetY;
            if (dy >= step * 2.2 && Date.now() - this.gStart < 300) {
              this.eng.hardDrop();
            } else if (dy <= -step * 1.4) {
              this.eng.hold();
            }
          })
      )
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BG)
  }

  // ---------------- HUD ----------------

  @Builder
  hudBar() {
    Row({ space: 8 }) {
      Text('方块战争')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(CYAN)
      Text(this.mode === GameMode.Classic ? '经典' : '危机')
        .fontSize(11)
        .fontColor(this.mode === GameMode.Classic ? CYAN : RED)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(9)
        .backgroundColor(CARD)
        .border({ width: 1, color: CARD_LINE })
      if (this.mode === GameMode.Hazard && this.phase !== Phase.Ready) {
        Text(this.warn ? `⚠ x${this.warnCount}` : `⏱ ${this.warnIn}s`)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(RED)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor('rgba(255,90,90,0.12)')
          .border({ width: 1, color: 'rgba(255,90,90,0.4)' })
      }
      Blank()
      this.stat(`${this.score}`, TEXT)
      this.stat(`${this.mode === GameMode.Classic ? this.bestClassic : this.bestHazard}`, GOLD)
      this.stat(`${this.lines}`, CYAN)
      this.stat(`Lv.${this.level}`, '#B58CFF')
      if (this.phase === Phase.Running || this.phase === Phase.Paused || this.phase === Phase.Clearing) {
        Text('⚙')
          .fontSize(15)
          .fontColor(this.settingsOpen ? GOLD : SUB)
          .textAlign(TextAlign.Center)
          .width(34)
          .height(34)
          .borderRadius(12)
          .backgroundColor(this.settingsOpen ? 'rgba(255,210,74,0.16)' : CARD)
          .border({ width: 1, color: this.settingsOpen ? 'rgba(255,210,74,0.55)' : CARD_LINE })
          .onClick(() => {
            this.openSettings();
          })
        Text('⚡')
          .fontSize(14)
          .fontColor(this.aiOn ? GOLD : SUB)
          .textAlign(TextAlign.Center)
          .width(34)
          .height(34)
          .borderRadius(12)
          .backgroundColor(this.aiOn ? 'rgba(255,210,74,0.16)' : CARD)
          .border({ width: 1, color: this.aiOn ? 'rgba(255,210,74,0.55)' : CARD_LINE })
          .onClick(() => this.toggleAI())
        Text(this.phase === Phase.Paused ? '▶' : '⏸')
          .fontSize(16)
          .fontColor(TEXT)
          .textAlign(TextAlign.Center)
          .width(34)
          .height(34)
          .borderRadius(12)
          .backgroundColor(CARD)
          .border({ width: 1, color: CARD_LINE })
          .onClick(() => this.togglePause())
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 6 })
  }

  @Builder
  stat(value: string, color: string) {
    Text(value)
      .fontSize(17)
      .fontWeight(FontWeight.Bold)
      .fontColor(color)
      .maxLines(1)
      .backgroundColor(CARD)
      .borderRadius(10)
      .border({ width: 1, color: CARD_LINE })
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }

  // ---------------- 道具生效卡片 ----------------

  @Builder
  bannerOverlay() {
    Column({ space: 6 }) {
      Text(this.banner![0])
        .fontSize(54)
      Text(this.banner![1])
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(GOLD)
      Text(this.banner![2])
        .fontSize(13)
        .fontColor(TEXT)
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 26, right: 26, top: 18, bottom: 18 })
    .borderRadius(20)
    .backgroundColor('rgba(23,28,49,0.95)')
    .border({ width: 2, color: GOLD })
    .shadow({ radius: 24, color: 'rgba(255,210,74,0.35)', offsetX: 0, offsetY: 0 })
  }

  // ---------------- 弹层 ----------------

  @Builder
  settingsOverlay() {
    Column() {
      Column({ space: 16 }) {
        Row({ space: 10 }) {
          Text('设置')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT)
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(SUB)
            .textAlign(TextAlign.Center)
            .width(32)
            .height(32)
            .borderRadius(11)
            .backgroundColor(CARD)
            .border({ width: 1, color: CARD_LINE })
            .onClick(() => {
              this.closeSettings();
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          Text('道具概率')
            .fontSize(13)
            .fontColor(SUB)
          Slider({ value: this.itemRatePct, min: 0, max: 100, step: 5 })
            .width(150)
            .selectedColor(GOLD)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.itemRatePct = Math.round(value);
              this.eng.itemRate = this.itemRatePct / 100;
              try {
                if (this.store !== null) {
                  this.store.putSync('item_rate', this.itemRatePct);
                  this.store.flush();
                }
              } catch (e) {
                // 忽略持久化失败
              }
            })
          Text(`${this.itemRatePct}%`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(GOLD)
            .width(52)
            .textAlign(TextAlign.End)
        }
        .width('100%')
      }
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .borderRadius(16)
      .backgroundColor('rgba(23,28,49,0.97)')
      .border({ width: 1, color: CARD_LINE })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(8,10,20,0.6)')
    .onClick(() => {
      this.closeSettings();
    })
  }

  private openSettings(): void {
    this.settingsWasRunning = this.eng.phase === Phase.Running || this.eng.phase === Phase.Clearing;
    if (this.settingsWasRunning) {
      this.eng.pause();
    }
    this.settingsOpen = true;
  }

  private closeSettings(): void {
    if (this.settingsOpen && this.settingsWasRunning && this.eng.phase === Phase.Paused) {
      this.eng.resume();
    }
    this.settingsOpen = false;
  }

  @Builder
  overlayBtn(text: string, bg: string, fg: string, onTap: () => void) {
    Button(text)
      .width(240)
      .height(50)
      .borderRadius(25)
      .fontSize(17)
      .fontWeight(FontWeight.Bold)
      .backgroundColor(bg)
      .fontColor(fg)
      .onClick(() => onTap())
  }

  @Builder
  readyOverlay() {
    Column({ space: 14 }) {
      Text('方块战争')
        .fontSize(44)
        .fontWeight(FontWeight.Bold)
        .fontColor(CYAN)
      Column({ space: 10 }) {
        Button('经典模式')
          .width(240)
          .height(50)
          .borderRadius(25)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .backgroundColor(CYAN)
          .fontColor('#0E1122')
          .onClick(() => {
            this.startGame(GameMode.Classic);
          })
        Button('危机模式')
          .width(240)
          .height(50)
          .borderRadius(25)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .backgroundColor(RED)
          .fontColor('#1A0A0A')
          .onClick(() => {
            this.startGame(GameMode.Hazard);
          })
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(8,10,20,0.86)')
  }

  @Builder
  pauseOverlay() {
    Column({ space: 12 }) {
      Text('已暂停')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
      Button('继续游戏')
        .width(240)
        .height(50)
        .borderRadius(25)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .backgroundColor(CYAN)
        .fontColor('#0E1122')
        .onClick(() => {
          this.eng.resume();
        })
      Button('重新开始')
        .width(240)
        .height(50)
        .borderRadius(25)
        .fontSize(16)
        .backgroundColor(CARD)
        .fontColor(TEXT)
        .border({ width: 1, color: CARD_LINE })
        .onClick(() => {
          this.startGame(this.mode as GameMode);
        })
      Button('换模式')
        .width(240)
        .height(50)
        .borderRadius(25)
        .fontSize(16)
        .backgroundColor(CARD)
        .fontColor(SUB)
        .border({ width: 1, color: CARD_LINE })
        .onClick(() => {
          this.eng.toMenu();
        })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(8,10,20,0.86)')
  }

  @Builder
  overOverlay() {
    Column({ space: 12 }) {
      Text('游戏结束')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT)
      if (this.newBest) {
        Text('🏆 新纪录！')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(GOLD)
      }
      Text(`${this.score}`)
        .fontSize(52)
        .fontWeight(FontWeight.Bold)
        .fontColor(GOLD)
      Text(`${this.lines} 行 · Lv.${this.level}`)
        .fontSize(14)
        .fontColor(SUB)
      Button('再来一局')
        .width(240)
        .height(50)
        .borderRadius(25)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .backgroundColor(CYAN)
        .fontColor('#0E1122')
        .onClick(() => {
          this.startGame(this.mode as GameMode);
        })
      Button('换模式')
        .width(240)
        .height(50)
        .borderRadius(25)
        .fontSize(16)
        .backgroundColor(CARD)
        .fontColor(SUB)
        .border({ width: 1, color: CARD_LINE })
        .onClick(() => {
          this.eng.toMenu();
        })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(8,10,20,0.86)')
  }

  // ---------------- 游戏循环 ----------------

  private startLoop(): void {
    if (this.timerId >= 0) {
      return;
    }
    this.timerId = setInterval(() => {
      this.loopStep();
    }, 16);
  }

  private stopLoop(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private loopStep(): void {
    const now = Date.now();
    this.eng.tick(now);
    // AI 辅助：出新方块（或刚开启）时计算最佳姿态与落点
    if (this.aiOn) {
      if (this.eng.pieceSeq !== this.aiSeq) {
        this.aiSeq = this.eng.pieceSeq;
        this.aiResult = PieceAI.best(this.eng);
        this.autopilot = this.aiResult !== null;
        this.aiFails = 0;
      }
    } else if (this.aiResult !== null) {
      this.aiResult = null;
      this.autopilot = false;
    }
    // 自动驾驶：真实方块逐帧转向/平移到推荐位，到位或受阻即停
    if (this.autopilot && this.eng.phase === Phase.Running && this.eng.cur !== null && this.aiResult !== null) {
      const c = this.eng.cur;
      if (c.rot !== this.aiResult.rot) {
        const diff = (this.aiResult.rot - c.rot + 4) % 4;
        if (!this.eng.rotate(diff <= 2 ? 1 : -1)) {
          this.autopilot = false; // 旋转受阻，放弃本次自动定位
        }
      } else if (c.x !== this.aiResult.x) {
        const dx = this.aiResult.x > c.x ? 1 : -1;
        if (this.eng.moveH(dx)) {
          this.aiFails = 0;
        } else {
          this.aiFails += 1;
          if (this.aiFails > 1) {
            this.autopilot = false; // 连续平移受阻，放弃
          }
        }
      } else {
        this.autopilot = false; // 已到位
      }
    }
    this.rd.draw(this.canvasCtx, this.cvW, this.cvH, this.eng, now, this.aiResult);

    // 同步 HUD 状态（仅在变化时赋值，减少无谓刷新）
    const e = this.eng;
    if (e.score !== this.score) {
      this.score = e.score;
    }
    if (e.lines !== this.lines) {
      this.lines = e.lines;
    }
    if (e.level !== this.level) {
      this.level = e.level;
    }
    if (e.phase !== this.phase) {
      this.phase = e.phase;
      if (e.phase === Phase.Over) {
        this.handleOver();
      }
    }
    const hasWarn = e.pendingGarbage > 0;
    if (hasWarn !== this.warn) {
      this.warn = hasWarn;
    }
    if (e.pendingGarbage !== this.warnCount) {
      this.warnCount = e.pendingGarbage;
    }
    // 道具生效大卡片（引擎侧触发：消行掉落当场生效 / 藏弹引爆）
    if (e.banner !== null && e.bannerAt !== this.bannerSeenAt) {
      this.bannerSeenAt = e.bannerAt;
      this.banner = e.banner;
      this.bannerUntil = now + 2200;
    }
    if (this.banner !== null && now > this.bannerUntil) {
      this.banner = null;
    }
    if (e.mode === GameMode.Hazard && e.phase === Phase.Running) {
      const s = Math.max(0, Math.ceil((e.nextGarbageAt - now) / 1000));
      if (s !== this.warnIn) {
        this.warnIn = s;
      }
    }
  }

  private togglePause(): void {
    if (this.eng.phase === Phase.Paused) {
      this.eng.resume();
    } else if (this.eng.phase === Phase.Running || this.eng.phase === Phase.Clearing) {
      this.eng.pause();
    }
  }

  private toggleAI(): void {
    this.aiOn = !this.aiOn;
    this.aiSeq = -1; // 强制下一帧重算
    if (!this.aiOn && this.aiResult !== null) {
      this.aiResult = null;
    }
    try {
      if (this.store !== null) {
        this.store.putSync('ai_assist', this.aiOn);
        this.store.flush();
      }
    } catch (e) {
      // 忽略持久化失败
    }
  }

  private startGame(mode: GameMode): void {
    this.newBest = false;
    this.mode = mode;
    this.score = 0;
    this.lines = 0;
    this.level = 1;
    this.warnIn = 0;
    this.warn = false;
    this.aiSeq = -1;
    this.aiResult = null;
    this.autopilot = false;
    this.aiFails = 0;
    this.eng.start(mode);
    this.phase = this.eng.phase;
  }

  private handleOver(): void {
    const isClassic = this.eng.mode === GameMode.Classic;
    const prev = isClassic ? this.bestClassic : this.bestHazard;
    if (this.eng.score > prev) {
      this.newBest = true;
      try {
        if (this.store !== null) {
          this.store.putSync(isClassic ? 'best_classic' : 'best_hazard', this.eng.score);
          this.store.flush();
        }
      } catch (e) {
        // 忽略持久化失败
      }
      if (isClassic) {
        this.bestClassic = this.eng.score;
      } else {
        this.bestHazard = this.eng.score;
      }
    } else {
      this.newBest = false;
    }
  }
}
