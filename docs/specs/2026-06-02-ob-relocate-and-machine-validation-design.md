# ob 脚本迁移与 init machine 校验 设计文档

## 背景与目标

`ob` 是 OpenBMC 一键环境初始化脚本，当前位于 [tools/ob](../../tools/ob)。本次优化解决三类问题：

1. **位置不便手动执行**：脚本藏在 `tools/` 下，用户手动执行需要 `cd tools` 或写全路径。希望把 `ob` 放到仓库根目录，方便直接 `./ob init <machine>`。
2. **machine 校验过晚**：手动执行 `ob init iasi-ast2700`（一个不存在的 machine）时，前 2 步正常执行，直到 Step 3（`source setup`）才由 OpenBMC 官方脚本报 `No such machine!`。希望在进入昂贵步骤前就校验 machine，并主动打印当前仓库支持的 machine 列表。
3. **下载提示生硬**：现有下载提醒（主仓库克隆、20-30GB 子仓库下载）散落且语气偏生硬的 `[WARN]`，希望分层、更自然地提醒用户。

**成功标准**：
- 用户可在仓库根目录直接 `./ob init <machine>`，旧引用全部同步更新，无悬挂引用。
- `ob init <不存在的machine>` 在进入 20-30GB 大下载前被拦下，并清晰列出支持的 machine。
- 全新环境（无主仓库）下 `ob init`（带/不带参数）都先引导用户克隆主仓库。
- 下载提示分层清晰：主仓库轻量提示、大下载结构化醒目提示、校验后才下载。

## 范围

- 将 `tools/ob` 物理迁移到仓库根目录 `ob`（干净迁移，删除 `tools/ob`）。
- 调整 `detect_harness_root()` 的路径推断逻辑以适配新位置。
- 同步更新所有对 `tools/ob` 路径的引用（路由表、skill 文档、脚本内文案）。
- 在 init 流程中新增 machine 列表枚举、打印、校验关卡（含 TTY 交互 / 无 TTY 报错降级）。
- machine 列表来源以 OpenBMC 主仓库下 `source setup`（无参数）打印的可用列表为准。
- 将 `init` 的 `<machine>` 参数由必填改为可选（optional）。
- 源选择菜单保留序号选项，并为每个选项附等价的 `--obmc-url` 命令提示。
- 全新环境下主仓库缺失时，`ob init`（带/不带参数）统一先引导克隆主仓库。
- 重构下载提示语气，分层呈现。

## 非范围

- 不改变 machine 的识别口径——以 OpenBMC 官方 `setup` 的输出为唯一来源，不自行扫描或维护 machine 列表。
- 不支持把 OpenBMC URL 作为位置参数（`ob init <url>`），避免与 `<machine>` 位置参数语义冲突；统一用 `--obmc-url`。
- 不新增对外部 OpenBMC 源码树的支持。

## 方案比较

### 方案 A：干净迁移 + Step 2 后校验（推荐）

- **核心思路**：`ob` 移到根目录并删除 `tools/ob`；machine 校验插在主仓库就绪之后、子仓库大下载之前。
- **优点**：位置最直观；校验时机最早可行（machine 列表物理上依赖已克隆的主仓库）；无冗余转发文件。
- **缺点**：任何记着 `tools/ob` 的旧习惯会失效——通过同步更新所有引用消化。

### 方案 B：迁移 + 保留 tools/ob 转发 shim

- **核心思路**：`ob` 移到根目录，`tools/ob` 改成 `exec` 根目录 `ob` 的转发脚本。
- **优点**：向后兼容旧路径调用。
- **缺点**：多一个需维护的转发文件；"主脚本在哪"产生歧义。已在澄清阶段被否决。

## 推荐方案

采用**方案 A**。

理由：
- machine 列表来源（在 `$OPENBMC_DIR` 下 `source setup` 无参数打印的可用 machine）物理上依赖主仓库克隆完成，因此校验无法提前到参数解析阶段；放在 Step 2（主仓库就绪）之后、Step 4（20-30GB 大下载）之前，是"最早且有效"的拦截点。
- 采用 `source setup` 输出而非自扫 `*.conf`：这是 `setup` 自身的口径，与 Step 3 校验完全一致，杜绝"列出来了但 setup 不认"的偏差，且 `setup` 已做多列排版。

**主要 trade-offs**：machine 打错时仍需先付出主仓库克隆（小体积、几分钟）的成本才能枚举列表。这是不可回避的约束；通过"全新环境先引导确认再克隆主仓库"把这点成本也交回用户决定。

## 关键边界与组件职责

新增 / 调整的组件（均在单文件 `ob` 内）：

- **`parse_args()`（调整）**：`init` 的 `<machine>` 由必填改为可选。不再因缺少 machine 直接报错；未提供时 `$MACHINE` 留空，交由 `resolve_machine()` 在主仓库就绪后处理（交互选择 / 无 TTY 报错）。
- **`list_available_machines()`（新增）**：在 `$OPENBMC_DIR` 下运行 `source setup`（无参数），捕获其输出，解析出可用 machine 名列表。主仓库不存在时返回空。
- **`print_available_machines()`（新增）**：打印支持的 machine 列表（直接复用 `setup` 的多列排版输出），供 init 早期信息展示和校验失败时复用。
- **`require_openbmc_repo()`（新增）**：在需要 machine 列表前确保主仓库存在。若 `$OPENBMC_DIR/.git` 缺失：
  - 提示"当前没有 OpenBMC 主仓库，无法枚举/校验 machine，需要先克隆主仓库（小体积，约几分钟）"。
  - 复用现有 `select_openbmc_repo_url()` + `clone_openbmc()` 完成克隆。
  - 该引导对 `ob init`（带参数和不带参数）都生效。
- **`select_openbmc_repo_url()`（调整）**：源选择菜单保留序号选项，并在每个选项后附等价命令提示：
  - 若 `$MACHINE` 已提供且命中列表 → 通过。
  - 若 `$MACHINE` 未提供，或提供了但未命中：
- **`resolve_machine()`（新增）**：在主仓库就绪后调用。
    - **无 TTY** → 打印列表 + 报错退出（降级为"报错退出"，并提示传入有效 machine）。
- **`--obmc-url`（重命名）**：原 `--openbmc-url` 选项统一重命名为 `--obmc-url`；同步更新 usage、示例、错误提示与等价命令文案。
- **下载提示重构（调整）**：
  - 主仓库克隆前：`[INFO]` 语气，说明"小体积主仓库，用于获取 machine 列表，约几分钟"。
  - Step 4 子仓库大下载前：结构化醒目提示，含体积（~20-30GB）、预计时间、可中断后增量续传（脚本本身已幂等增量）。
  - 大下载提示中点明"machine=X 已确认，开始拉取其依赖子仓库"，让大下载"名正言顺"。

## 数据流 / 控制流

新的 init 主流程（`main()` 中 `init` 分支）：


## 数据流 / 控制流





新的 init 主流程（`main()` 中 `init` 分支）：
新的 init 主流程（`main()` 中 `init` 分支）：
```raw
parse_args            # 解析 command / machine(可选) / options（不在此校验 machine 是否存在）
detect_harness_root   # HARNESS_ROOT = 脚本所在目录（根目录）
  └─ init 分支:
     prerequisites_check          # Step 1（不变）
     require_openbmc_repo         # 新增：主仓库缺失 -> 引导克隆（菜单 1/2 + 等价 --obmc-url 命令），带/不带参数都生效
       └─ clone_openbmc           # Step 2：克隆主仓库（小体积，INFO 提示）
     resolve_machine              # 新增校验关卡（Step 2 后、Step 3 前）
       ├─ print_available_machines     # source setup 无参输出的支持列表
       ├─ 已提供且命中 -> 通过
       └─ 未提供 / 未命中:
            ├─ 有 TTY -> 交互菜单选 machine
            └─ 无 TTY -> 打印列表 + 报错退出
     [大下载结构化醒目提示]        # machine 确认后、进入大下载前
     init_bitbake_env             # Step 3（不变；machine 已保证有效）
     generate_dep_graph           # Step 4 起（不变）
     clone_sub_repos              # 20-30GB 大下载
     generate_lockfile
     inject_externalsrc
     print_report
```

- **关键输入**：命令行 `machine` 参数（可选）、终端是否为 TTY、`$OPENBMC_DIR/.git` 是否存在、`source setup` 输出的可用 machine 集合。
- **关键处理**：主仓库就绪保证 → `source setup` 枚举 machine → 校验/交互选择 → 才进入大下载。
- **关键输出**：有效的 `$MACHINE`，或在无效且无法交互时安全退出。

## 错误处理与回退

| 失败模式 | 处理策略 |
|---|---|
| 全新环境无主仓库，`ob init`（带/不带参数） | `require_openbmc_repo` 提示并引导克隆主仓库（选 1 社区 / 2 自定义）后再继续 |
| 用户拒绝/无法克隆主仓库（如 stdin 不可读） | 复用现有 `select_openbmc_repo_url` 的报错路径，提示用 `--obmc-url` / `OB_OPENBMC_URL`，退出 |
| 未提供 machine 或 machine 不在列表 + 有 TTY | 打印列表 + 交互菜单选一个有效 machine 继续 |
| 未提供 machine 或 machine 不在列表 + 无 TTY | 打印列表 + 报错退出，提示传入有效 machine |
| 主仓库已存在但 `source setup` 无可用 machine（异常） | `list_available_machines` 返回空时提示主仓库可能不完整，建议更新主仓库 |

回退原则：宁可在主仓库克隆（几分钟）后拦下错误 machine，也不让用户进入 20-30GB 大下载。

## 测试策略

核心行为验证（以脚本级 / 手动验证为主，bash 单文件无单测框架）：

- **迁移正确性**：根目录 `./ob init --help`、`./ob status` 正常；`detect_harness_root` 推断的 `HARNESS_ROOT` 指向仓库根；全仓 grep 无残留 `tools/ob` 悬挂引用。
- **machine 校验（有 TTY）**：`./ob init iasi-ast2700`（无效）→ 打印列表 + 进入交互选择；选有效 machine 后继续。
- **不带 machine（有 TTY）**：`./ob init` → 不报 `Missing <machine>`；主仓库就绪后打印列表 + 进入交互选择。
- **machine 校验（无 TTY）**：`./ob init iasi-ast2700 < /dev/null` → 打印列表 + 报错退出，且**未**进入 Step 4 大下载。
- **有效 machine**：`./ob init romulus` → 跳过交互，直达后续步骤。
- **machine 列表来源**：`list_available_machines` 输出与在 `$OPENBMC_DIR` 下手动 `source setup`（无参）的可用 machine 一致。
- **源选择菜单提示**：人工核对菜单选项后附的等价 `--obmc-url` 命令文案正确。
- **选项重命名**：`--obmc-url` 生效；全仓 grep 无残留 `--openbmc-url`。
- **全新环境引导**：临时移走 `workspace/openbmc/.git` 模拟，`ob init`（带/不带参数）均先引导克隆主仓库。
- **dry-run 兼容**：`./ob init romulus --dry-run` 不实际下载，新增校验/提示逻辑在 dry-run 下正确短路。
- **提示分层**：人工核对主仓库 INFO 提示、大下载结构化提示、"machine=X 已确认"措辞。

- `ob` 脚本内 usage / 注释 / 报错文案中涉及路径、`--openbmc-url`→`--obmc-url`、`<machine>` 可选与"re-run"的描述。
- 其它仓内对 `tools/ob` 或 `--openbmc-url` 的文档引用（实现阶段以 grep 全量核对为准）。
- [rules/WORKSPACE.md](../../rules/WORKSPACE.md)：路由表中 `tools/ob` → 根目录 `ob`。
- [rules/skills/workflow_obmc_env_init.md](../../rules/skills/workflow_obmc_env_init.md)：`tools/ob init <machine>` 路径表述。
- `ob` 脚本内 usage / 注释 / 报错文案中涉及路径与"re-run"的描述。
- 其它仓内对 `tools/ob` 的文档引用（实现阶段以 grep 全量核对为准）。
- `source setup` 输出的解析方式（直接透传多列排版用于展示 vs 抽取扁平 machine 名集合用于命中判断）实现时细化；两者可共存（展示用原文、判断用集合）。
- 主仓库克隆体积的"约几分钟/约 X MB"具体措辞，实现时按实际值微调。




- 交互菜单的呈现形态（编号选单 vs 直接输入 machine 名）留待 writing-plans / 实现阶段细化，不影响本设计边界。- 主仓库克隆体积的"约几分钟/约 X MB"具体措辞，实现时按实际值微调。