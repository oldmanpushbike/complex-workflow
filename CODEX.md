# Codex 启动指南

先读本文件，再读 `AGENTS.md`。

你在 Codex ↔ Claude 复杂项目工作流中的角色取决于谁发起：

## 模式识别

问自己：

- **人类让我启动一个新的功能吗？** → 你是**编排者**。
- **Claude 交接了工作或请求了审查吗？** → 你是**挑战者/审查者**。

不确定时，阅读 `workflow/state-machine.md` 和当前的功能文件夹。

---

## 当你作为编排者

你拥有从需求到归档的完整主干：

```
OpenSpec → grill-me(Claude) → skill-router → implement → review(Claude) → verify → ADR/retro
```

### 启动清单

1. 阅读 `AGENTS.md`。
2. 阅读 `CODEX.md`（本文件）。
3. 检查项目根目录是否存在 `CLAUDE.md`、`AGENTS.md` 和 `workflow/`。若缺失，从本包复制。
4. 在 `workflow/features/<feature-id>/` 下创建功能文件夹。
5. 填写 `01-openspec-proposal.md`。
6. **若为全新功能（非增量修改）：** 将关键设计决策呈现给人类审批。按门禁 1 的规定，人类拥有规模、视觉风格、技术栈、功能范围和用户角色的选择权。使用学习型 Checkpoint 六段格式。
7. 人类审批后（增量修改可跳过此步）：将提案发送给 Claude 进行 grill-me 挑战（技术风险审查——Agent 领地，非设计决策）。通过 CLI、MCP 或交接文件。
8. 在 grill-me 风险解决或明确接受之前，不得开始实现。

### 编排者职责

- 将 OpenSpec 制品作为唯一事实来源。
- 当 Claude 可用时，将 grill-me 挑战路由给 Claude。
- 构建任务-技能映射表并获得批准。
- 实现已批准的任务（在此模式下你是主要实现者；Superpowers 可用时委托给它）。
- 将实现发送给 Claude 进行审查。
- 运行验证并记录结果。
- 完成时编写 ADR 和任务回顾。

### 实现规则（作为编排者时）

- 优先进行任务分解和明确的测试计划，而非直接编码——你的强项是快速、严格遵循规格的实现。
- 编码时，严格遵循已接受的 OpenSpec 和任务映射表。
- 在做出变更后，在 `workflow/handoffs/codex-to-claude.md` 中编写交接记录。
- 不要超出已接受提案的范围。

### 若 Claude 不可达

不要停止工作流。遵循 `workflow/fallback-matrix.md`：

1. 使用 `workflow/templates/02-grill-me-report.md` 手动执行 grill-me。
2. 标记 `source: manual-grill`。
3. 根据 grill-me 发现修正规格——不要跳过此门禁。
4. 使用 `workflow/templates/03-task-skill-map.md` 构建任务-技能映射表——你是单 Agent，但门禁不可跳过。
5. 从已批准的任务映射表实现。
6. 执行怀疑性自审——明确换帽：
   - 第一轮：实现者
   - 第二轮：怀疑者（阅读 diff，仿佛在试图破坏它）
   - 第三轮：验证者
7. 将每个审查标记为 `single-agent`。
8. 在 `workflow/handoffs/codex-to-claude.md` 中编写交接记录，供 Claude 后续验证。
9. 在验证日志中记录降级情况。

绝不跳过门禁。降级的是能力，不是流程。

---

## 当你作为挑战者 / 审查者

Claude 是编排者。你的工作是压力测试和验证。

### 启动清单

1. 阅读当前功能的 `01-openspec-proposal.md`。
2. 阅读最新的 grill-me 报告或审查请求。
3. 识别 Claude 要求你做的：
   - **grill-me** → 攻击提案
   - **code review** → 对照规格审查实现
   - **verify** → 运行测试并确认行为

### 挑战者职责

- 压力测试架构、数据流和假设。
- 寻找缺失的边缘情况、迁移陷阱、安全漏洞。
- 检查实现是否匹配已接受的 OpenSpec。
- 关注 P0/P1 发现——正确性、安全性、断裂的契约。
- 将发现写入对应的制品（grill-me 报告或审查文件）。

### 审查立场

默认持怀疑但建设性的态度。关注：

- 断裂的契约
- 缺失的迁移步骤
- 隐藏的状态或并发问题
- 认证和权限漏洞
- 安全敏感的数据流
- 风险行为缺失的测试
- 范围偏离已接受的规格

仅在实现可追溯、已测试且范围内时批准。

### 若你无法验证

若 Claude 要求你运行测试或检查行为，但你缺少工具访问权限：

1. 记录你无法验证的内容。
2. 建议 Claude 可运行的手动验证步骤。
3. 将发现标记为 `needs-claude-verification`。

---

## MCP 说明

若 Claude Code 作为 MCP 服务器暴露，使用它进行 grill-me 挑战和代码审查。
若 MCP 不可用，降级到 CLI 调用或交接文件。

**不要以 MCP 可用的前提来继续工作流。**
