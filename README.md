# Codex ↔ Claude 复杂项目工作流（双向编排 + 复利系统）

> 一套可复制的 AI Agent 协作工作流。从"靠自觉遵守"的软约束，演进到"确定性脚本强制执行"的硬约束。
> 核心目标：**让每次项目实践都沉淀为下次的杠杆，产生复利。**

[![Version](https://img.shields.io/badge/version-1.3.0-blue)](https://github.com/oldmanpushbike/complex-workflow/releases)
[![Status](https://img.shields.io/badge/status-active-brightgreen)]()

---

## 架构全景（三层复利系统）

```
┌──────────────────────────────────────────────────────────┐
│  L1 主循环层                                              │
│  S0→S1→S2→S3→S4→S5→S6→S7→S8→S9 主干                    │
│  └── 门禁失败 → 反馈注入 → 回退重试 → 人类升级            │
│  └── 中断恢复 → 文件系统回归检测 → 模式切换               │
│  └── Retro → OpenSpec 跨功能学习弧                        │
├──────────────────────────────────────────────────────────┤
│  L2 确定性门禁层                                           │
│  dispatcher (调度器) ← 硬编码路由决策树，零LLM             │
│  gate-check.sh ← 7门禁产物检查 + --enforce 硬阻断         │
│  feature-state.json ← JSON Schema 结构化状态              │
│  validate-state.sh ← Schema 独立校验 + --fix 自修复       │
│  ci-gate-guard.sh ← CI/CD 门禁守护                        │
│  .claude/settings.json ← Hook 实时拦截                    │
├──────────────────────────────────────────────────────────┤
│  L3 评估与进化层                                           │
│  score.py ← 7维评分引擎（纯算术，零LLM）                   │
│  dashboard.html ← 可视化仪表盘                            │
│  extract-lessons.sh ← Lesson 自动提取                     │
│  pipeline.md ← 经验三级进化（Lesson→Pattern→Instinct）     │
└──────────────────────────────────────────────────────────┘
```

### 从软到硬的演进

| 版本 | 约束类型 |  Agent 如何遵守 |
|---|---|---|
| v1.0–v1.1 | 纯软约束 | 读 md → 自觉遵守 |
| v1.2.0 | 设计完备 | + Schema + 模板 + 完整协议定义 |
| **v1.3.0** | **硬执行** | **+ 6个确定性脚本 + CI enforce + Hook拦截** |

---

## 运行模型

每个功能走同一条主干：

```text
S0 Intake → S1 OpenSpec → S2 grill-me → S3 修正规格 → S4 任务映射
    → S5 实现 → S6 双审 → S7 验证 → S8 知识沉淀 → S9 归档
```

S4 后可分支并行，但所有分支必须在 S6 审查 + S7 验证处汇合。
S8 沉淀的经验通过 `pipeline.md` 回流到下一个功能的 S0。

### 反馈循环（核心复利机制）

```
gate-check 失败 → 根因分析 → 修正注入 → 回退到正确状态 → 重试
                                          ↓ (≥3次失败)
                                    人类 Checkpoint (六段教学格式)
```

失败不是死胡同——Retro → Lesson → Pattern → Instinct 三级进化，
确保每个坑只踩一次。

---

## 两种模式，同一契约

### Mode A：Codex 编排

```text
Codex: 主干（OpenSpec → ... → 归档）
Claude: grill-me 挑战者 + 代码审查者 + 后备实现者
```

### Mode B：Claude 编排

```text
Claude: 主干（OpenSpec → ... → 归档）
Codex: grill-me 挑战者 + 代码审查者 + 后备实现者
```

编排者是启动功能的那一方。契约、门禁和制品完全相同。

---

## 角色（对称）

| 能力 | Codex | Claude Code |
|---|---|---|
| 编排者 | Mode A 默认 | Mode B 默认 |
| OpenSpec 作者 | ✓ | ✓ |
| grill-me 挑战者 | ✓ | ✓ |
| 技能路由 | ✓ | ✓ |
| 实现者 | 主要 (Mode A) | 后备；主要 (Mode B) |
| 架构审查 | 后备 | 主要 |
| 代码审查 | ✓ | ✓ |
| 验证者 | ✓ | ✓ |

任一 Agent 可填充任一角色。

---

## 确定性脚本（硬执行层）

**全部零 LLM 调用，纯 Bash/Python，可放进 CI：**

| 脚本 | 用途 | 用法 |
|---|---|---|
| `dispatch.sh` | 主会话退化执行器 | `bash workflow/scripts/dispatch.sh <feature-id> --json` |
| `gate-check.sh` | 7门禁产物检查 | `bash workflow/scripts/gate-check.sh <feature-id> [--enforce] [--schema-only]` |
| `ci-gate-guard.sh` | CI/CD 门禁守护 | `bash workflow/scripts/ci-gate-guard.sh [--strict]` |
| `validate-state.sh` | Schema 校验 | `bash workflow/scripts/validate-state.sh <feature-id> [--fix]` |
| `score.py` | 7维评分引擎 | `python workflow/eval/score.py --feature <feature-id>` |
| `extract-lessons.sh` | Lesson 提取 | `bash workflow/experience/extract-lessons.sh [<feature-id>\|--all\|--check]` |

### 如何使用 dispatch.sh

Agent 会话启动后，不再自己读一堆 md 判断该干什么：

```bash
$ bash workflow/scripts/dispatch.sh ai-werewolf --json
{
  "featureId": "ai-werewolf",
  "currentState": "S5",
  "mode": "single-agent",
  "nextAction": {
    "role": "orchestrator",
    "action": "implement",
    "description": "继续 S5 实现。按 task-skill-map 完成下一个未完成的任务",
    "requiredReads": ["01-openspec-proposal.md", "03-task-skill-map.md"],
    "blockers": [],
    "humanCheckpoint": null
  }
}
```

Agent 照 `nextAction` 执行即可——主会话退化为纯执行器。

---

## 跨 Agent 通信

按顺序尝试三个通道：

1. **MCP**（首选）— Agent 间实时工具调用
2. **CLI** — 通过 Shell 调用并捕获输出
3. **交接文件** — `workflow/handoffs/`，下一会话读取

若全部失败 → **单 Agent 模式**：门禁不减，审查标记 `single-agent`，等待另一方回归后续跑。

---

## 降级：当另一方不可达

核心韧性规则——**不停止工作流**：

| 场景 | 动作 |
|---|---|
| 无法联系对方做 grill-me | 手动执行 grill-me，标记 `source: manual-grill` |
| 无法联系对方做审查 | 换帽自审（实现者→怀疑者→验证者），标记 `single-agent` |
| 无法联系对方做验证 | 自行验证，记录残余风险 |
| 对方 Agent 回归 | 读交接文件，审查 delta；`resume-protocol.md` 自动检测 |

详细矩阵：`workflow/fallback-matrix.md`

---

## 经验三级进化管道

```
Lesson（教训）  ← 从 retro 自动提取，单功能，具体
    │  跨功能归纳 + 人工确认
    ▼
Pattern（模式） ← ≥2个功能复现，抽象化，可迁移
    │  规则化注入 + 人工签核
    ▼
Instinct（本能）← 写入 AGENTS.md/CLAUDE.md，系统自动执行
```

详见 `workflow/experience/pipeline.md`。

---

## 文件结构

```
codex-claude-complex-workflow/
├── README.md                        ← 本文件
├── AGENTS.md                        ← 共享契约 + 7硬门禁 + 学习型Checkpoint
├── CLAUDE.md / CODEX.md             ← Agent 启动指南
├── CHANGELOG.md
│
├── workflow/
│   ├── state-machine.md             ← S0-S9 状态机（含反馈回退弧）
│   ├── fallback-matrix.md           ← 12种降级场景
│   ├── learning-checkpoints.md      ← 学习型门禁框架（六段HTML格式）
│   ├── dispatcher.md                ← 调度器Agent指令
│   ├── feedback-loop.md             ← 反馈循环协议（844行）
│   ├── resume-protocol.md           ← 续跑/恢复协议（793行）
│   │
│   ├── feature-state.schema.json    ← 功能状态 JSON Schema
│   ├── templates/                   ← 7个制品模板（中文化 + HTML增强）
│   │   ├── 01-openspec-proposal.md
│   │   ├── 02-grill-me-report.md
│   │   ├── 03-task-skill-map.md
│   │   ├── 04-implementation-plan.md
│   │   ├── 05-verification-log.md
│   │   ├── 06-adr.md
│   │   └── 07-task-retro.md
│   │
│   ├── scripts/                     ← 确定性脚本（零LLM，可CI）
│   │   ├── dispatch.sh              ← 主会话退化执行器
│   │   ├── gate-check.sh            ← 门禁检查 + enforce模式
│   │   ├── ci-gate-guard.sh         ← CI/CD 门禁守护
│   │   └── validate-state.sh        ← Schema 校验 + 自修复
│   │
│   ├── eval/                        ← 评估层
│   │   ├── scoring-engine.md        ← 7维评分算法定义
│   │   ├── score.py                 ← 评分引擎实现
│   │   └── dashboard.html           ← 可视化仪表盘
│   │
│   ├── experience/                  ← 经验进化层
│   │   ├── pipeline.md              ← 三级进化管道定义
│   │   ├── extract-lessons.sh       ← Lesson 自动提取脚本
│   │   ├── lessons/                 ← Level 1: 教训
│   │   ├── patterns/                ← Level 2: 模式
│   │   └── instincts/               ← Level 3: 本能规则
│   │
│   ├── features/                    ← 功能实例
│   │   └── <feature-id>/
│   │       ├── feature-state.json   ← 唯一真相源
│   │       ├── 01–07 制品
│   │       └── reviews/
│   │
│   ├── reviews/                     ← 审查报告模板
│   ├── handoffs/                    ← Agent 交接文件
│   └── skills/                      ← 技能路由 + 子任务卡片
│
├── examples/
│   └── ai-werewolf/                 ← 完整工作流示例（狼人杀Web游戏）
│
└── .claude/
    └── settings.json                ← Claude Code Hook 配置
```

---

## 引导启动顺序

1. 读 `README.md`（本文件）— 项目工作流总览
2. 读 `AGENTS.md` — 共享契约和硬门禁
3. 按身份读对应指南：
   - **Claude 编排：** `CLAUDE.md` → 启动清单
   - **Codex 编排：** `CODEX.md` → 启动清单
   - **Claude 挑战：** `CLAUDE.md` + 提案 + Codex 交接
   - **Codex 挑战：** `CODEX.md` + 提案 + Claude 交接
4. 运行 `bash workflow/scripts/dispatch.sh <feature-id> --json` 获取路由指令
5. 检查 `workflow/fallback-matrix.md` 确认降级状态

就绪标准：

- 活跃功能 ID 已知
- 编排者已确认
- 当前状态已从 `feature-state.json` 读取
- 最后验证检查点已知
- 不可用工具/Agent 已记录
- 下一门禁已明确

---

## 安全规则

- 实现必须在 OpenSpec 有明确验收标准后开始
- 任何任务不得在实现中悄然修改需求
- 编码中发现规格缺口 → 回到 grill-me 或 OpenSpec
- 跨 Agent 审查关注：正确性、安全、迁移风险、测试缺口、范围漂移
- Agent 间分歧 → 规格优先。规格模糊 → 修正规格

## 长期项目规则

- 影响多个任务的架构决策写 ADR
- 每个任务完成后写 retro → 自动提取 Lesson
- 任务分支在审查前保持独立
- 仅通过验证日志合并分支
- 不让聊天记忆成为决策的唯一记录处

---

## 版本历史

| 版本 | 核心变化 |
|---|---|
| v1.0.0 | 双向编排 + 7门禁 + 降级矩阵 |
| v1.1.0 | 中文化 + 学习型Checkpoint + HTML增强 + 狼人杀示例 |
| v1.2.0 | 三层架构：反馈循环 + 确定性门禁 + 评估面板 + 经验管道 |
| v1.3.0 | 6个确定性脚本：dispatch/gate-check/ci-guard/validate/score/extract |
