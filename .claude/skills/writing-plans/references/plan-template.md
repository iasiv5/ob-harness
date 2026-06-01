# Plan Template

使用下面的骨架写实施计划；按任务复杂度增删细节，但不要删掉核心执行信息。

正文从标题开始。不要在标题前写“计划已写好”“请先审阅”或背景铺垫；审阅提示统一放到文末 checkpoint。

## 文档标题

`# [功能名称] 实施计划`

## 目标

- 这份计划要完成什么

## 架构快照

- 本次采用什么思路
- 和现有结构如何衔接
- 只写本次方案必需的信息，不写仓库现状、历史沿革或工具宣传

## 输入工件

- 设计文档路径
- 相关需求或补充说明

## 文件结构与职责

- Create: `path/to/new-file`
- Modify: `path/to/existing-file`（可附符号或章节锚点）
- Test: `path/to/test-file`

## 任务清单

- 每个 Task 只覆盖一个可独立验证的工作块；如果标题里出现并列动作，继续拆分
- 任务正文直接写正式计划，不写“计划预览”“任务示例”“后续操作”这类过渡段落

### Task 1: [任务名称]

- 目标
- 涉及文件
- 验证范围

- [ ] Step 1: 写失败测试或失败检查
- Run: `exact command`
- Expected: [明确失败信号]
- [ ] Step 2: 运行并确认失败
- Run: `exact command`
- Expected: [明确失败信号]
- [ ] Step 3: 写最小实现
- Change: [真实实现、配置修改或文档改动]
- [ ] Step 4: 运行并确认通过
- Run: `exact command`
- Expected: [明确通过信号]
- [ ] Step 5: 可选 checkpoint commit

## 执行纪律

- 开始实现前先复查计划
- 每任务都要验证
- 遇阻立即停下说明

## 最终验证

- 需要运行的最终测试或检查
- 预期结果
- 如果当前环境已知，最终验证命令沿用同一 shell 和仓库惯例
- 如果当前环境是 Windows + PowerShell，最终验证不要回退到 `grep`、`cat`、`ls` 这类 Unix 命令

## 审阅 Checkpoint

- 计划正文结束后，再请求用户审阅
- 审阅通过前，不进入实现

默认路径优先级：用户指定路径 > 仓库已有约定 > `docs/plans/<YYYY-MM-DD>-<feature>-implementation-plan.md`。