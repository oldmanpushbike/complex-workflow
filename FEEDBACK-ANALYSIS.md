# 工作流包反馈分析 & 改进方案

> 基于 AI 狼人杀实战测试的全面回顾

---

## Q1: 包形态评估

### 五种形态对比

<table>
<tr>
  <th>维度</th>
  <th>🗂️ 文件夹（当前）</th>
  <th>🔌 Claude Plugin</th>
  <th>📦 npm 包</th>
  <th>🖥️ MCP Server</th>
  <th>🔗 Git Submodule</th>
</tr>
<tr>
  <td><strong>跨 Agent</strong></td>
  <td>✅ 通用</td>
  <td>❌ Claude 专用</td>
  <td>⚠️ 需工具</td>
  <td>⚠️ 协议开放</td>
  <td>✅ 通用</td>
</tr>
<tr>
  <td><strong>版本管理</strong></td>
  <td>⚠️ 手动 git</td>
  <td>❌ 无内置</td>
  <td>✅ semver</td>
  <td>✅ semver</td>
  <td>✅ git</td>
</tr>
<tr>
  <td><strong>可发现性</strong></td>
  <td>❌ 藏在本地</td>
  <td>⚠️ 插件市场</td>
  <td>✅ npm 搜索</td>
  <td>⚠️ MCP 注册表</td>
  <td>❌ 手动</td>
</tr>
<tr>
  <td><strong>门禁执行</strong></td>
  <td>❌ 靠自觉</td>
  <td>⚠️ Hook 可行</td>
  <td>❌ 只是文件</td>
  <td>✅ 程序化</td>
  <td>❌ 靠自觉</td>
</tr>
<tr>
  <td><strong>维护成本</strong></td>
  <td>✅ 极低</td>
  <td>⚠️ 依赖 SDK</td>
  <td>⚠️ npm 工具链</td>
  <td>❌ 需运维服务</td>
  <td>✅ 低</td>
</tr>
<tr>
  <td><strong>可移植性</strong></td>
  <td>✅ 复制即用</td>
  <td>❌ Claude 限定</td>
  <td>✅ npx 即用</td>
  <td>❌ 需跑服务</td>
  <td>⚠️ 依赖 git</td>
</tr>
</table>

### 结论：混合架构

```
          GitHub 仓库（唯一真源）
                 │
    ┌────────────┼────────────┐
    ▼            ▼            ▼
  文件夹        Plugin       CLI
（通用访问）  （Claude增强）（脚手架）
```

| 层 | 作用 | 面向谁 | 优先级 |
|---|---|---|---|
| **GitHub 仓库** | 版本控制、社区协作、文档站点 | 所有人 | P0 — 立刻 |
| **文件夹分发** | 项目内直接复制/引用 | Agent 运行时 | P0 — 保持 |
| **Claude Plugin** | Hook 自动加载、门禁提醒 | Claude 用户 | P2 — 后续 |
| **CLI 脚手架** | `npx werewolf-workflow init` | 开发者 | P3 — 远期 |

**核心理由：** 文件夹是唯一同时被 Claude 和 Codex 原生理解的形式。Plugin/MCP/CLI 是叠加层，不是替代层。就像 Git 本身——核心是 `.git` 文件夹，GitHub/CLI/GUI 是叠加工具。

---

## Q2: 中文化 + HTML 增强

### 设计原则

| 场景 | 用 Markdown | 用 HTML |
|---|---|---|
| Agent 需解析执行的指令 | ✅ | ❌ |
| 长文本（正文、说明、分析） | ✅ | ❌ |
| 决策对比表 | ⚠️ 可 | ✅ 更好 |
| 状态徽章/进度条 | ❌ | ✅ |
| 风险热力矩阵 | ❌ | ✅ |
| 学习卡片（icon+文字） | ❌ | ✅ |
| 代码块和模板 | ✅ | ❌ |

**铁律：Agent 读 Markdown，人看 HTML。两者不互斥——HTML 嵌在 Markdown 里。**

### 中文化范围

| 文件 | 策略 |
|---|---|
| `AGENTS.md` | 双语（中文主体，英文关键词保留） |
| `CLAUDE.md` / `CODEX.md` | 中文 |
| 所有模板 | 中文，字段名中英对照 |
| `README.md` | 双语 |
| state-machine / fallback-matrix | 中文 |

### HTML 增强示例

**决策表（当前 vs 改进）：**

当前（纯 markdown）：
```
| # | Decision | Options | Choice |
|---|---|---|---|
| 1 | Scale | 7/9/custom | |
```

改进（HTML 嵌入）：
```html
<div style="border:2px solid #d4a574; border-radius:12px; padding:16px; margin:12px 0; background:#1a1a2e;">
  <h3 style="color:#d4a574;">🎯 决策 1：游戏规模</h3>
  <table>
    <tr style="background:#27ae60; color:white;">
      <td>⭐ 推荐</td><td>7人标准局</td><td>新手友好，最平衡</td>
    </tr>
    <tr>
      <td>B</td><td>9人进阶局</td><td>更多角色，更长时长</td>
    </tr>
    <tr>
      <td>C</td><td>自定义</td><td>完全自由配置</td>
    </tr>
  </table>
  <details>
    <summary>📚 为什么这个决策重要？</summary>
    <p>游戏规模会锁定后续的角色配置和 UI 布局...</p>
  </details>
</div>
```

---

## Q3: 人工门禁 → 学习型 Checkpoint

### 现状盘点

| 编号 | 触发点 | 当前行为 | 人工参与度 | 有教学内容？ |
|---|---|---|---|---|
| S0 | 需求模糊 | 停住问人类 | 🟢 必须 | ❌ |
| Gate 1 | 新功能设计决策 | 呈现选项（我们刚加的） | 🟢 必须 | ❌ |
| Gate 2 | grill-me 风险审查 | Agent↔Agent | 🟡 可跳过 | ❌ |
| S4 | 领域知识缺口 | 停住问人类 | 🟢 必须 | ❌ |
| S4 | 生产数据/计费/权限 | 停住问人类 | 🟢 必须 | ❌ |
| S5 | 工作量>2x估算 | 停住询问 | 🟢 必须 | ❌ |
| S7 | 验收标准失败 | 停住询问 | 🟢 必须 | ❌ |

**结论：6 个人工门禁，全是"stop sign"——拦住了但没教任何东西。**

### 重构方案：每个门禁输出六段结构

```
┌─────────────────────────────────────────────┐
│  📋 背景 (Context)                          │
│  现在发生了什么？为什么走到这个决策点？        │
├─────────────────────────────────────────────┤
│  🔍 分析 (Analysis)                         │
│  Agent 已经考虑了哪些因素？排除了哪些方案？     │
├─────────────────────────────────────────────┤
│  📚 经验课堂 (Learning)          ← 新增！    │
│  有经验的开发者会怎么看？业界常见做法是什么？   │
│  背后的设计原则、trade-off 理论               │
├─────────────────────────────────────────────┤
│  🎯 选项 (Options)                          │
│  A/B/C 方案，各自优缺点，风险和收益            │
├─────────────────────────────────────────────┤
│  ⭐ 推荐 (Recommendation)                    │
│  Agent 的最佳推荐 + 推理链路                  │
├─────────────────────────────────────────────┤
│  ✋ 你的决策 (Decision)                      │
│  人类的选择 → 驱动下一步                      │
└─────────────────────────────────────────────┘
```

### 以 AI 狼人杀为例，重新设计 Gate 1 输出

**📋 背景：**
> 你在构建一个全新的 AI 狼人杀 Web 游戏。OpenSpec 已完成技术可行性分析，
> 但在进入代码实现之前，有几个关键设计决策只有你能做——因为它们决定了
> 产品的"感觉"和用户的体验方向，这不是技术问题。

**🔍 分析：**
> Agent 已评估了技术约束（现有 Next.js 16 栈、无后端 = 纯前端游戏逻辑、
> LLM API 通过 Next.js Route Handler 代理）、竞品参考（网易狼人杀、Among Us）、
> 以及狼人杀游戏设计的最佳实践。

**📚 经验课堂：**
> 游戏设计的"黄金圆圈"法则：**Why → How → What**。先定"为什么玩"（体验目标），
> 再定"怎么玩"（机制），最后定"长什么样"（视觉）。很多项目翻车是因为反过来
> ——先画 UI 再想机制。我们的顺序是对的：OpenSpec 先定了游戏循环和状态机，
> 现在才让你定视觉风格。

**🎯 选项：**
> ...（A/B/C 方案，含优缺点对比表）

**⭐ 推荐：**
> Agent 推荐 A（暗黑奇幻风），理由：与狼人杀的主题（夜晚/悬疑/推理）天然契合；
> 暗色调下金色点缀在视觉上引导注意力到关键操作；Tailwind CSS 的暗色模式
> 工具类最多，开发效率最高。

**✋ 你的决策：** `[待填写]`

### 新增文件：`workflow/learning-checkpoints.md`

定义每个门禁的教学模板和 HTML 输出规范。

---

## Q4: GitHub 仓库化

### 仓库结构

```
codex-claude-complex-workflow/
├── README.md                     # 中英双语，徽章、快速开始
├── AGENTS.md                     # 共享契约
├── CLAUDE.md / CODEX.md          # Agent 启动指南
├── CHANGELOG.md
├── LICENSE (MIT)
│
├── workflow/
│   ├── state-machine.md          # 状态机定义（中文）
│   ├── fallback-matrix.md        # 降级矩阵
│   ├── learning-checkpoints.md   # 🆕 学习型门禁框架
│   │
│   ├── templates/                # 7 个制品模板（中文+HTML增强）
│   │   ├── 01-openspec-proposal.md
│   │   ├── 02-grill-me-report.md
│   │   ├── 03-task-skill-map.md
│   │   ├── 04-implementation-plan.md
│   │   ├── 05-verification-log.md
│   │   ├── 06-adr.md
│   │   └── 07-task-retro.md
│   │
│   ├── reviews/                  # 审查报告模板
│   └── handoffs/                 # Agent 交接文件模板
│
├── examples/                     # 🆕 真实项目示例
│   └── ai-werewolf/              # 本次项目的完整工作流记录
│       ├── 01-openspec-proposal.md
│       ├── 02-grill-me-report.md
│       ├── 03-task-skill-map.md
│       ├── 05-verification-log.md
│       ├── 06-adr.md
│       └── 07-task-retro.md
│
├── docs/                         # 🆕 GitHub Pages 文档站
│   ├── index.html
│   ├── quick-start.md
│   └── concepts/
│       └── learning-checkpoints.md
│
└── .github/
    ├── workflows/ci.yml
    └── ISSUE_TEMPLATE/
```

### 版本路线图

| 版本 | 内容 | 状态 |
|---|---|---|
| v1.0.0 | 当前状态 + Gate 1 人类审批修正 | ✅ 今天已完成 |
| v1.1.0 | 全中文化 + HTML 增强模板 + 学习型门禁框架 | 📋 本次 |
| v1.2.0 | examples/ 目录 + 狼人杀示例 | 📋 本次 |
| v2.0.0 | Claude Plugin + CLI 脚手架 | 🔮 远期 |

### 社区策略

- **Issues**：接受"在我的项目里跑这套工作流遇到什么问题"的反馈
- **Discussions**：工作流设计哲学讨论（比如这次的 grill-me 拆分）
- **PR**：新的 ADR 模板、状态机变体、语言翻译
