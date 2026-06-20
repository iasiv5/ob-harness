# ob 优先：ob 作为 OpenBMC 环境动作的统一前门

`ob` 的功能在持续增长（当前 init/build/status/start-qemu/stop-qemu，规划中还有 `ob dev` 等），且 `ob` CLI 模式的默认调用方是 agent。为避免 agent 各自手搓 OpenBMC 环境动作（手动 clone、裸 `bitbake`、手起 QEMU）导致行为发散、难维护，我们确立"ob 优先"约定：agent 做 OpenBMC 环境生命周期动作前，先查 `ob --help` 是否提供对应能力，提供就走 `ob <cmd>`，仅当 `exit 1` 真实失败且 `ob` 确无此能力时才手动兜底。判定锚定 `ob --help`（`usage()`）作为唯一权威能力清单，由 `tests/protocol/usage_dispatch_sync.sh` 断言它与 dispatch 子命令集合一致来防漂移，使约定随 `ob` 增长自动跟上而不靠手写命令表。回退按退出码区分：`exit 1` 才是真失败、才考虑手动；`exit 2`（用户取消）与 `exit 3`（前置缺失，应用 `ob` 补前置）都不是失败，不得据此绕过 `ob`。手动兜底复用 `rules/01_SOUL.md` 的确认框架，并强制记录绕过的能力 + 列为 `ob` 待补项，让缺失能力回流进 `ob`（对齐公理 A12 AI 原生开发范式）。约定分两层落地：常驻层在 `AGENTS.md`「Working Mode」放最小守卫 + 指针（每会话加载），完整协议在 `rules/skills/bestpractice_06-ob_first.md`（按需检索）。`ob build` 当前纯交互（非 TTY → `exit 3`）是已知缺口，登记于该 skill，本次不改 `ob` 代码。

Status: accepted

## Considered Options

1. **放任 agent 直连最短路径** — 不立约定，agent 想手动就手动。最简单，但能力发散、不可维护，且违背"ob CLI 默认由 agent 调用"的设计初衷。
2. **只做软偏好** — 写一句"建议优先 ob"但不定退出码回退语义。agent 会在 `exit 3`（前置缺失）时误判为失败并转手动绕过 `ob`，约定形同虚设。
3. **能力清单另建结构化接口（`ob help --json` / `ob commands`）** — 更贴 A12，但与 `usage()` 形成双源、需同步，`--help` 已被发现漂移过一次（`--skip-deps` 缺失），双源只会加剧漂移。除非将来实测 agent 解析不了散文，否则维持单源。
4. **用 hook 强制（SessionStart 提醒 / PreToolUse 命令拦截）** — SessionStart 与常驻 `AGENTS.md` 守卫重复，且现有 hook 在 Linux 下是 no-op；PreToolUse 拦截可行性未证实且误报率高，会挡正当的裸 `bitbake` 调试。正确落点是约定层 + CI 闸，不是 hook。
5. **完整协议常驻每会话加载（写进 AGENTS.md 或新 `rules/07_*.md`）** — 可靠性最高，但真正需要常驻的只有几行守卫，全表常驻让每会话付额外上下文成本。退而取两层：守卫常驻、细节按需。

## 消费侧契约：诊断行 + remedy line

「ob 优先」要求 agent 按退出码回退，但 `exit 3` 是多义码（缺 machine / 未 init / 未 build），光看码不知补哪条。故约定 `exit 3` 输出固定两段式：先**诊断行**说明哪条前置没满足，再**恰好一行 remedy line**，内含字面的下一条 `ob` 命令（如 `Run 'ob init romulus' first.`），agent 无需推断即可补救——exit-3 协议恒定为“按码分支 → 读诊断行定位前置 → 扫 remedy line 照它执行”。这是上面 Considered Option 3（不另建 JSON 结构化接口）的正向落点：不靠结构化输出，而靠“退出码骨架 + remedy line”把“成败 + 下一步”喂给 agent。术语见 `CONTEXT.md` 的 `remedy line`，并受 protocol 测试约束（关键 `exit 3` 路径须打印含字面 `ob` 命令的 remedy line）。remedy line **恰好含一条 `ob` 命令、不串接第二条**——多步前置由单命令循环逐轮接力（补一步 → 重试 → 下一轮 remedy 指向下一步），而非在一行里列链（列链需调用方判断哪条才是这一步，恰好违背无需推断原则）。本轮收敛：`ob` start-qemu 的 no-built-machines 分支原 remedy 含两命令（`ob init ... then ob build`）且在已 init 未 build 时语义不准，已拆为两条单命令子分支（无 init-done → `Run 'ob init <machine>' first.`；init-done 未 built → `Run 'ob build' first.`），消除全 `ob` 唯一的多命令 remedy 离群点。
