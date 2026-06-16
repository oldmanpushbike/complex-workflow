# 示例：AI 狼人杀 Web 游戏

本目录是 `codex-claude-complex-workflow` 的完整使用示例。

## 项目背景

用户请求："我要做一个 ai 狼人杀 web，有漂亮 ui，清晰流程"。

## 工作流执行过程

### 编排模式
- **编排者：** Claude Code
- **挑战者：** 不可达（Codex 无法连接）
- **执行模式：** 单 Agent 模式，手动 grill-me，换帽自审

### 制品列表

| 文件 | 对应门禁 | 说明 |
|---|---|---|
| `01-openspec-proposal.md` | Gate 1 | OpenSpec 提案（7人局、暗黑风、纯前端） |
| `02-grill-me-report.md` | Gate 2 | 风险审查（11个发现，含LLM降级、状态丢失等） |
| `03-task-skill-map.md` | Gate 3 | 任务拆解（11个任务，依赖图） |
| `05-verification-log.md` | Gate 6 | 验证记录（静态检查通过，待E2E） |
| `06-adr.md` | Gate 7 | 4个架构决策记录 |
| `07-task-retro.md` | Gate 7 | 任务回顾 |
| `08-claude-review.md` | Gate 5 | 单Agent换帽自审（8个发现，3个P0） |

### 关键发现

#### 工作流改进
在本次执行中发现了 Gate 1 的缺失——原工作流没有人类审批设计决策的门禁，
导致 Agent 在未确认方案的情况下写了大量代码。这一发现直接促成了：
- AGENTS.md Gate 1 增加人类签核条款
- 学习型 Checkpoint 框架的诞生
- grill-me 拆分为「设计决策→人类」+「风险审查→Agent」

#### 技术发现
- Hunter 角色在初版中完全不可用（无 UI、状态变更绕过 reducer）
- fallback AI 在边界情况下崩溃（空数组 .id 访问）
- 单 Agent 换帽自审确实能发现真实 bug

## 技术栈

- Next.js 16 + React 19 + Tailwind CSS 4 + TypeScript
- DeepSeek API（OpenAI 兼容协议）
- 纯前端游戏引擎（reducer 模式）
- localStorage 持久化 + 规则备选 AI

## 使用

```bash
cd frontend
cp .env.local.example .env.local
# 编辑 .env.local 填入 DeepSeek API Key
npm run dev
# 访问 http://localhost:3000/werewolf
```
