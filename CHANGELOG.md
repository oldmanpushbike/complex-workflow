# Changelog

## v1.1.0 (unreleased)

### 新增
- 学习型 Checkpoint 框架 (`workflow/learning-checkpoints.md`)
- OpenSpec 模板的 Design Decisions 部分采用 HTML 增强的六段格式
- 反馈分析文档 (`FEEDBACK-ANALYSIS.md`)

### 变更
- AGENTS.md 全面中文化，新增「人类交互门禁与学习型 Checkpoint」章节
- CLAUDE.md 中文化
- CODEX.md 中文化
- grill-me 模板明确区分：设计决策归 Gate 1（人类），风险审查归 Gate 2（Agent）

### 修复
- Gate 1 增加人类审批门禁——新功能的设计决策必须人类确认后才能进入 grill-me

## v1.0.0

### 初始版本
- 双向编排工作流（Codex ↔ Claude）
- 7 个硬门禁 + 5 个基本人类触发器
- 单 Agent 模式降级规则
- 7 个制品模板
- 状态机 + 降级矩阵
- CLAUDE.md / CODEX.md / AGENTS.md 启动指南
