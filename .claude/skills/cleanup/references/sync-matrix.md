# Cleanup 变更影响矩阵

遇到不确定“这次稳定结论该补到哪些长期知识载体，哪些旧信息又该删”时，先查这张表。

`cleanup` 的两个方向都要看：
- 补漏：哪些长期知识需要补到位
- 防膨胀：哪些旧信息应该删、合并或迁出

## 反向清理：哪些信息应该从长期知识里删除

### AGENTS / 项目规则文档中的反模式

| 反模式 | 处理 |
|---|---|
| “X 时刻起 Y 上线，详见 docs/Z.md” 这类历史叙事 | 删除；规则文档不是变更日志 |
| 在 `AGENTS.md` 里重复抄 docs 已有的机制说明 | 删除；只保留边界、红线和协作规则 |
| 已被新方案取代的中间态叙事 | 只保留最终态规则；中间历史删除 |
| 已完成阶段的任务清单、临时计划、一次性操作记录 | 删除；长期知识不保留阶段性流水账 |
| 只对当前一次会话有效的“提醒下次继续做什么” | 删除；这类内容属于 `handoff`，不属于 `cleanup` |

判断标准：下次 agent 如果没看到这条，会不会因此稳定做错？
不会，就删或迁走。

### 仓库记忆中的反模式

| 情况 | 处理 |
|---|---|
| 过期事实 | 改写或删除 |
| 相对时间（今天、最近、刚刚） | 改成绝对日期或直接删除 |
| 多条重复记录同一规则 | 合并为一条 |
| 已完成待办 | 删除 |
| 已推翻决策 | 删除旧决策，只留最终态 |

默认优先整理仓库记忆。
用户记忆只有在用户明确要求时才纳入 cleanup。

## 规范违规 → 处置

规范执行审计发现的违规，按下面原则处理。细则见 [governance.md](governance.md)。

| 发现 | 处置 |
|---|---|
| `AGENTS.md`、`CLAUDE.md`、`.github/copilot-instructions.md` 多个入口承载实质规则且没有明确同源关系 | 待用户拍板；需要确认权威入口和合并方向 |
| 入口文件只是软链、include、`@AGENTS.md` 或一行转发 | 不算违规；只编辑现场规则声明的权威文件 |
| README、CHANGELOG、plugin manifest 或 marketplace metadata 的资产清单与实际 skill / agent / prompt / instruction / hook 不一致 | 直接修，属于安全可逆的发布面同步 |
| 规则文件引用的路径、命令、skill、agent、prompt 或 hook 已确认不存在 | 清掉或改成现行路径；拿不准是否在其他机器 / 分支存在时列为待拍板 |
| 目录或文件命名违反工作区约定 | 待用户拍板；重命名可能影响脚本、同步工具、外部引用和历史路径 |
| `.gitignore` 缺少规则明确要求的敏感文件红线 | 直接补齐 |
| 上下级规则、README 与 customization metadata 互相矛盾 | 能从现实文件和发布面判断现行事实的直接改；否则待用户拍板 |

## 通用代码 / 文档变更 → 长期知识同步面

| 本次变化 | 需要同步的长期知识载体 |
|---|---|
| 新增 API / 路由 | 项目规则文档中的接口边界、README / docs 的 API 或集成说明 |
| 新增 / 改名 环境变量 | 项目规则文档的环境变量约束、runbook、README 配置说明 |
| 新增数据库表 / 列 | 架构说明、数据模型文档、必要的项目规则约束 |
| 新增 / 改动 用户流程 | README、集成说明、必要的项目规则边界 |
| 新增术语 / 改命名 | 术语表、README、长期规则文档中的命名约束 |
| 部署参数 / 基础设施变化 | runbook、README、项目根规则文档的部署边界 |

## skill / agent / prompt / hook 资产变更 → 长期知识同步面

| 本次变化 | 需要同步的文件 |
|---|---|
| 新增 skill | skill 本体、插件 README、marketplace README、plugin manifest、marketplace metadata、CHANGELOG |
| 重命名 skill / agent / prompt | 本体文件、README 清单、结构树、manifest、marketplace metadata、CHANGELOG、验证说明 |
| 修改 skill / agent 的定位或触发边界 | 本体 frontmatter 与正文、README 使用说明；若 published surface 描述也受影响，再同步 metadata |
| 新增 instruction / hook | instruction / hook 本体、README 结构树、验证说明；若对 published surface 有影响，再同步 metadata |
| 删除 asset | 清理本体引用、README 清单、结构树、metadata、CHANGELOG 中的陈旧描述 |
| 发布面计数变化 | README、marketplace README、plugin manifest、marketplace metadata、CHANGELOG 一起改 |

## 插件 / marketplace 仓库的额外检查

如果当前仓库是插件 / marketplace 打包仓库（如 Copilot 插件或其它 runtime 的等价形式），还要额外检查：

- README 的资产清单和结构树是否仍然准确
- plugin manifest 和 marketplace metadata 的 description / version 是否一致
- CHANGELOG 是否记录了这次长期保留的 published surface 变化
- 使用说明里的 `/skill`、agent mode、prompt 清单是否仍然能对应现有资产

## 推荐执行优先级

当 `cleanup` 需要真正动文件时，优先顺序如下：

1. 先删旧、去重、纠正长期知识里的明显错误
2. 再同步公开文档（README、docs、CHANGELOG）
3. 再同步项目级规则或仓库记忆
4. 最后同步 metadata 和发布面版本信息

这样即使中途被打断，外部可见的长期知识也优先保持正确。
