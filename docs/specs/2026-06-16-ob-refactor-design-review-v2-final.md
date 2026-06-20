# ob 脚本重构设计文档 v2 复审意见（第二轮·已核验落盘状态）

> 状态：复审通过（待 5 项收尾）· 创建于 2026-06-16
> 审查对象：2026-06-16-ob-refactor-design.md（v2，288 行）
> 审查方法：对 ob 实时 grep/git 复核（git status 确认 ob clean、稳定 4252 行），逐条核验 v2 对初评建议的处置，并重新通审 v2 全文找新问题。
> 取代说明：本文件是针对 v2 的最终复审，取代上一轮的 2026-06-16-ob-refactor-design-review-v2.md（那版写于核验落盘前）。对方据本文件更新设计文档即可。
> 行号可靠性：本环境多次出现 terminal 输出串扰，导致同一函数 exit 行号在不同命令间显示不一致（而 ob 文件 git clean、未变）。下文及设计文档中的 ob#Lxxx 仅作定位参考，一律以函数名/文案 grep 重锚为准（见 F3）。

---

## 总体结论

v2 吸收质量高：初评建议 10 条采纳到位、R5 经复核确认是评审方读取错误、已撤回（详见第 1 节）。本轮通审 v2 全文，发现 5 项收尾（1 条中 + 4 条低，见第 2 节）。其中只有 F1 会在阶段 2-C 实施时引发归类错误、建议进 writing-plans 前先改；F2–F5 是闭环/卫生项，不阻塞。

---

## 1. 初评建议的最终核验（已闭环，无需再改）

| 编号 | v2 处置 | 复核结论 |
|---|---|---|
| R1 退出码传播模型 | "传播模型（修正后）"节：CLI 退出码完全由 cmd_* 的 exit 决定，main return 仅语义清理无行为变化 | 到位 |
| R2 可见行为变化 | "可见行为变化（精确版）"节重写，纠正"从未被屏蔽" | 到位 |
| R3 漏修取消误报 | 对齐清单 A 列全 5 处 exit 0（含 ensure_qemu_binary_community、select_openbmc_repo_url），点明 init 链两处必须同改 | 到位 |
| R4 case 1 死分支 | 通过 C（L2 exit 1→3）让 cmd_init 链产生 exit 3，==3 静默成立、矛盾自解 | 到位 |
| R5 头部协议冲突 | 驳回（头部是全局变量、全文无协议声明）| 驳回正确，评审方撤回 |
| Y1 协议在 L2 未落地 | 选 B：阶段 2-C，L2 前提失败 exit 1→3 + 判定准则 | 到位（判定准则待补清，见 F1）|
| Y2 download_core | 接口契约"只 return 不 exit"、flock/备份/回滚留调用方、标最高风险 | 到位 |
| Y3 prompt_for_absolute_path | 只做格式校验，存在性/内容校验留调用方 | 到位 |
| Y4 read_kv_field | 剔除 resolve_qb_vars（字符串非文件）、统一 head -1 + cut -f2- | 到位（head/tail 仍挂未决3，见 F2）|
| Y5 select/confirm 接口 | 全局变量传值 + 返回码传状态 + 绝不 exit；continue 2→continue、QEMU_FORCE 留调用方 | 到位、自洽 |
| G1 行号/死代码（优点）| write_pid_file 死代码、抽取点行号 | 认可（但行号读取本环境不稳定，见 F3）|
| G2 smoke test set -e | 补 source 带入 errexit/nounset 的隔离要求 + 列为阶段 0 验证项 | 到位 |
| G3 cmd_status read | 改用 read_kv_field 局部读、不污染全局 | 到位 |
| G4 require_path 连带 L2 exit 1→3 | 抽取点 6 已注明、被 C 吸收 | 到位 |
| G5 行数目标 | 改"消除模式数 + 各点实测行数" | 到位（"实测"措辞见 F5）|

R5 撤回说明（诚实记录）：初评 R5 称 ob 头部已声明 0/1/2/130 退出码协议。经评审方实时复核——grep 全文无任何协议声明块；头部对应位置是全局变量（SRC_DIR/CONFIGS_DIR/SOURCE_LOCK_FILE/DEFAULT_OPENBMC_REPO_URL/OPENBMC_REPO_URL）。初评引用的英文 Exit codes 块系一次异常读取的伪影，不存在于磁盘。R5 系评审方错误，已撤回，v2 驳回正确。

---

## 2. 本轮 action items（请据此更新设计文档）

### F1（中）— 判定准则 C 与对齐清单 A 对 ensure_qemu_binary_community 的 URL 分支归类需显式区分

问题：ensure_qemu_binary_community 有两个相邻的"没有 URL"分支，v2 把它们分别归到不同码，但两处文字未点明是不同分支，实施者读判定准则时会困惑该归 2 还是 3：

- 分支 (i)「非 TTY + URL 未配置」：error "QEMU binary URL not configured for ..." → exit 1（约 ob:822-825）。判定准则 C 的"→exit 3"典型例子把"ensure_qemu_binary_* 的 URL 未配置 分支"归 exit 3（前提）。
- 分支 (ii)「交互 + 输入空 URL」：info "No URL provided — aborting" → exit 0（约 ob:831-832）。对齐清单 A 把它归 exit 2（取消）。

同一函数同时出现在"→3"判定准则和"→2"对齐清单里、且都和 URL 相关——实施 2-C 时极易一刀切（把 (ii) 也改成 3，或把 (i) 改成 2）。

建议：在判定准则 C（或 A 清单该行备注）显式写明分治规则：ensure_qemu_binary_community「非 TTY 缺配置」→ exit 3（前提不满足）、「交互主动留空」→ exit 2（用户取消）。这正是"被动缺配置 vs 主动放弃"的边界。

### F2（低）— 未决事项 3（head/tail）可当场闭环

证据：write_qemu_url_config 写入前对同 key 先 grep -v "^${key_re}=" 删除所有旧行、再 append（约 ob:541-547）→ 同一 key 文件内永远单条。故 read 端 tail -1 等价 head -1，不存在"多 URL 取最后一条"场景。

建议：
- 未决事项 3 标注"已确认闭环（写入端去重保证单 key 单条，tail/head 等价）"。
- read_kv_field 接口契约里"read_qemu_url_config 现用 tail -1 需评估是否有多值场景"改为"已确认无多值场景（写入端去重），统一 head -1 行为等价"。

### F3（低）— 新增"实施约束"：行号以符号名 grep 重锚

现象：本轮复审在同一环境多次读取同一函数的 exit 行号出现不一致（terminal 输出串扰），而 git status 证明 ob 本身 clean、稳定 4252 行。即设计文档里的 ob#Lxxx 不可单独采信。

建议：新增"实施约束"一节（或并入测试策略）：writing-plans 与实施开工前，一律用 grep -n 按函数名/文案重锚所有引用行号，不按设计文档死行号下刀。这是行为正确性的前置条件，不是可选项。

### F4（低）— 文档卫生：精简"关于评审 R5"辩驳段

现状：协议表后保留了一段"关于评审 R5：…R5 不采纳"的辩驳。R5 已由评审方复核撤回，争议闭环。

建议：设计文档面向实施者，不必保留对已撤回评审的辩驳。删除或压成一句脚注即可（如"退出码协议为本设计新立，脚本原无协议声明"），减少过程噪音。

### F5（低）— "实测收益" → "预估收益"

现状：各抽取点写"实测收益 净减 ~N 行"。函数尚未抽取，无法"实测"。

建议：改为"预估收益（接口收敛后估算）"，名实相符。

---

## 3. 给作者的修订清单（按优先级）

1. F1（中）：判定准则补清 ensure_qemu_binary_community 两分支分治（非 TTY 缺配置→3 / 交互留空→2）。
2. F2（低）：未决事项 3 标已闭环 + 修 read_kv_field 接口契约措辞。
3. F3（低）：新增"实施约束"——行号用 grep -n 按符号名重锚。
4. F4（低）：精简/移除"关于评审 R5"辩驳段。
5. F5（低）："实测收益"改"预估收益"。

---

## 4. 放行判断

- v2 主体已就绪：传播模型、退出码协议（含 L2 迁移）、抽取点接口契约、测试策略均站得住。
- F1 建议进 writing-plans 前先改——否则阶段 2-C 逐点归类时会把 ensure_qemu_binary_community 的取消分支误改成 exit 3，引入与 A 清单冲突的行为。
- F2–F5 不阻塞 writing-plans 的正确性，可与 F1 一并收尾。
- 5 项处理完毕后，支持进入 writing-plans。
