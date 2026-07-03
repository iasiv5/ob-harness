# Cleanup 规范执行审计细则（GitHub Copilot 版）

这份 reference 只定义审计方法，不复制任何具体仓库规则。具体规则永远以现场读到的 `AGENTS.md`、`CLAUDE.md`、`.github/copilot-instructions.md`、范围化 instruction、README、manifest 或用户明确指定文件为准。

## 提取：什么算可机械核验的约定

读规则文件时，找谈论文件、目录、命名、必备内容、发布面和引用关系的约定。判断标准：能不能用读取文件、列目录、grep、解析 manifest 或对照实际资产来核验。能核验就提取；只描述沟通风格、思考方式或代码品味的规则不进入规范审计。

| 类别 | 常见信号 | 核验手段 |
|---|---|---|
| 主指令入口 | `AGENTS.md`、`CLAUDE.md`、`.github/copilot-instructions.md` 哪个是权威 | 读文件头、检查软链 / include / 转发关系 |
| 命名约定 | 文件夹、skill、agent、prompt、hook 命名规则 | `ls` + 逐个名字比对 |
| 必备文件 | README、CHANGELOG、plugin manifest、AGENTS 或 docs 索引必须存在 | 存在性检查 + 读取文件头 |
| 发布面一致性 | README、manifest、metadata 里的资产清单 | 对照实际 `skills/`、`agents/`、`commands/`、`instructions/`、`hooks/` |
| 死引用 | 规则或文档引用路径、命令、asset 名称 | targeted grep + 路径 / 文件存在性检查 |
| 红线 | `.env`、密钥、生成物、缓存目录等不能进入仓库 | `.gitignore` / 文件列表核验 |

提取时保留依据来源，至少记下文件和小节名。摘要里报告违规时，要让用户看得出依据来自哪里。

## 核验范围

- 默认：当前仓库 + 当前任务触及的长期资产。
- 插件仓库：额外核验 README、CHANGELOG、plugin manifest、实际资产目录之间是否一致。
- 用户明确要求“审全部”或“整个 workspace”：再扩大到用户指定范围，但仍按目录路由分批核验，不做全盘扫描。
- 用户级 assets 或全局配置：只有用户明确要求同步用户级长期知识，或者本次任务本身就在修改这些资产时才纳入。

## 处置分级

判断一个修复是否能直接做，问两个问题：改错后能不能一步撤销，是否会影响仓库路径以外的脚本、同步工具、外部引用或用户级配置。

### 直接修

- README、CHANGELOG、manifest、metadata 的资产清单与实际目录不一致。
- 规则文件里的明显笔误、相对时间、已经确认不存在的路径或 asset 引用。
- `.gitignore` 缺少规则明文要求的敏感文件红线。
- 缺少安全、可逆、纯补齐的说明或索引项。

### 待用户拍板

- 目录或文件重命名。
- 删除文件、目录、skill、agent、prompt、hook。
- 合并内容不一致的 `AGENTS.md`、`CLAUDE.md`、`.github/copilot-instructions.md`。
- 修改用户级全局配置或跨仓库长期偏好。
- 规则漂移：规则写 X，但当前项目实际都在做 Y 且运转良好。
- 上下级规则矛盾，且无法从现实文件判断哪边是现行权威。

## 摘要格式

规范审计的摘要只列有行动价值的结果。

```markdown
### 规范审计
- 自动修复：README 的 skill 清单补上 cleanup governance reference（依据：插件 README 资产清单需要对应实际目录）
- 待你拍板：`AGENTS.md` 与 `.github/copilot-instructions.md` 都有实质规则但没有同源声明；需要确认权威入口后再合并
```

每条“待你拍板”都要说明为什么不能直接改，以及建议的处理方向。