# 方块战争 BlockWar 🧱

**HarmonyOS 彩屏俄罗斯方块** —— 纯 ArkTS + Canvas 手写游戏核心，零第三方依赖。

参考 Kindle 时代经典俄罗斯方块 / 方块战争（Tetris Battle）玩法：经典马拉松之外，
还有一个"危机模式"——垃圾行不断从底部顶起，看你能顶多久。

![mode](https://img.shields.io/badge/modes-经典·危机-4AD4E8) ![deps](https://img.shields.io/badge/dependencies-0-53C653)

## 特性

- **标准规则**：SRS 旋转系统（含 I 型专用踢墙表）、7-bag 随机发牌、幽灵投影、Hold 暂存、软/硬降
- **计分**：单消 100 / 双消 300 / 三消 500 / 四消 800 ×等级，B2B 四连消 ×1.5，连击奖励，软降 +1/行、硬降 +2/行
- **两种模式**
  - 🎯 经典马拉松：每 10 行提速一级（15 级速度表）
  - ⚠️ 危机模式（方块战争味）：每 12 秒从底部顶起 1~4 行垃圾行（随机留 1 个洞），堆到顶就结束
- **操作**：纯触屏手势——拖动移动/软降、点按旋转、快速下滑硬降、上滑 Hold
- **AI 辅助 + 自动驾驶**（HUD ⚡ 开关）：每出一个新方块，遍历全部「旋转 × 列」组合模拟硬降消行后的盘面，按经典启发式权重（消行 +/空洞 −/平均高度 −/凹凸度 −）选出最佳姿态与落点；**真实方块自动旋转、平移到推荐位**（逐帧巡航，玩家一旦手动操作立即接管），棋盘上以金色描边标出最终落点
- **道具系统（掉落即当场生效）**：消行掉落（四消必得 / 双三消 +20% / 单消=基础概率，⚙ 可调 0~100%）触发瞬间自动执行并弹出金色大卡片——
  💥 爆炸（轰掉最高砖塔周围 5×5，碎片飞散）、🧬 变异（AI 选当前局势最优形状当场变身）、
  🎲 捣乱（打乱后续队列）、🧹 清底（移除底部两行）、🐢 减速（重力放慢 2.5 倍 10 秒）
- **藏弹方块（暗雷）**：15% 的新方块里藏 1 格隐形炸弹——随满行被消时引爆；两枚炸弹相邻会互相引爆；
  爆破 3×3 且连锁传播，被清列下落补位。可以故意把两块弹拼在一起定点爆破
- **其他**：锁定延迟（400ms/15 次重置）、消行白闪动画、Toast 提示（TETRIS/B2B/升级）、最高分本地持久化、切后台自动暂停、返回键先暂停、游戏时保持亮屏、深色沉浸界面

## 工程

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   # 入口 Ability
├── game/
│   ├── Tetromino.ets               # 7 种方块定义 + SRS 踢墙表
│   ├── Engine.ets                  # 纯逻辑引擎（不依赖 UI，方便单测/AI 对战扩展）
│   ├── AI.ets                      # PieceAI：旋转×落点全遍历 + 启发式评估（AI 辅助）
│   └── Renderer.ets                # Canvas 渲染器（vp 坐标系）
└── pages/Index.ets                 # 页面：HUD/按钮/手势/弹层/存档
```

## 构建 & 运行

```bash
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

> 本仓库提交的 `build-profile.json5` 为空签名配置（构建出 unsigned hap）。
> 本机调试请在 DevEco Studio 里打开项目 → File > Project Structure → Signing Configs 勾选
> "Automatically generate signature"，签名材料写入本机 `~/.ohos/config/`，
> 建议对该文件 `git update-index --skip-worktree` 避免把签名配置推上来。

## 调研结论（为什么不用游戏引擎）

支持 HarmonyOS NEXT 的通用游戏引擎目前是 **Cocos Creator、团结引擎（Unity 中国）、LayaAir** 三家国产引擎，
但对一个 10×20 格子的方块游戏来说都是杀鸡用牛刀（引入引擎层、体积和构建链复杂度）。
GitHub/Gitee 上也没有可以直接二开的成熟鸿蒙 Tetris 项目（调研时点），
参考对象是通用语言实现的规则范本：[vue-tetris](https://github.com/Binaryify/vue-tetris)、
[flutter-tetris](https://github.com/boyan01/flutter-tetris) 的 SRS/计分实现。

本项目的架构（纯逻辑 Engine 与渲染/UI 解耦）为后续留了口子：

- [ ] 方块战争对战模式：本地 AI 对手，消行送垃圾行
- [ ] 音效 / 震动反馈
- [ ] 触控板 / 键盘输入
- [ ] 若扩展为更大的 2D/3D 游戏，再评估 Cocos Creator（3.2 起支持 HarmonyOS）

## License

MIT
