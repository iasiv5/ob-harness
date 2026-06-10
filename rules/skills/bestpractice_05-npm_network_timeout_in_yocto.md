# Yocto 编译中 npm 网络超时的诊断与解决

## 元数据

- **类型**: BestPractice
- **适用场景**: OpenBMC/Yocto 编译 webui-vue 等 Node.js 组件时，`do_compile` 阶段 npm install 报网络超时（`ETIMEDOUT`）
- **创建日期**: 2026-06-10
- **来源**: 多位工程师在 romulus 等 machine 构建中的实际踩坑经验

---

## 目标

当 `bitbake webui-vue`（或任何含 `npm install` 的 recipe）因网络问题失败时，能快速定位根因并选择合适的修复策略，使构建成功完成。

## ob build 自动处理

如果使用 `ob build` 构建固件，npm 注册表和超时参数已内置自动处理：

- **注册表自动探测**：`ob build` 在调用 bitbake 前并行测试 `npmjs.org` 和 `npmmirror.com` 的下载速度。默认使用 `npmmirror.com`（国内镜像），仅当 mirror 慢（≥2s）且 npmjs.org 快（<1s）时才切换到 npmjs.org。
- **超时参数自动注入**：通过 BitBake 的 `BB_ENV_PASSTHROUGH_ADDITIONS` 机制向 npm task 注入 600 秒超时和重试参数（`fetch_timeout=600000`, `fetch_retry_maxtimeout=120000`, `fetch_retry_mintimeout=30000`, `fetch_retry_factor=2`）。
- **探测结果缓存 24 小时**到 `workspace/configs/<machine>.npm-registry`，避免每次构建重新探测。
- **环境变量覆盖**：`OB_NPM_REGISTRY` 可强制指定注册表（如 `OB_NPM_REGISTRY=https://registry.npmmirror.com/`），或设为空禁用自动检测。

### ob build 用户的常见操作

| 操作 | 命令 |
|------|------|
| 正常构建（自动处理） | `ob build` |
| 强制使用国内源 | `OB_NPM_REGISTRY=https://registry.npmmirror.com/ ob build` |
| 禁用自动检测 | `OB_NPM_REGISTRY= ob build` |
| 强制重新探测 | `rm workspace/configs/<machine>.npm-registry && ob build` |
| 验证使用了哪个源 | 查看构建日志中 `npm http fetch` 的 URL 域名 |

本节以下的手动策略适用于不使用 `ob build` 的场景（直接运行 bitbake、CI 环境等）。

## 错误特征

典型错误输出：

```
npm http fetch GET 200 https://registry.npmjs.org/<pkg>/-/<pkg>-<ver>.tgz 17XXXms (cache miss)
...
npm ERR! code ETIMEDOUT
npm ERR! syscall read
npm ERR! errno -110
npm ERR! network read ETIMEDOUT
ERROR: Task (meta-phosphor/recipes-phosphor/webui/webui-vue_git.bb:do_compile) failed with exit code '1'
```

**关键判别信号：**
- GET 请求返回 200（网络可达），但下载慢（>15s/package）
- 最终在某次读取时触发 `ETIMEDOUT`
- 只有含 `npm install` 的 task 失败，其余 task 正常
- 日志中大量 `(cache miss)` 表示无本地缓存

这说明不是"网络不通"，而是"网络不稳定/速度不够"。

**另一种模式** — 大部分包正常但个别包极慢（>30s），最终触发超时。这是 npmjs.org 在国内网络的典型表现：单次小请求可能很快（<1s），但持续下载几百个包时会出现尾部延迟。

## 修复策略（从易到难）

以下策略适用于不使用 `ob build` 的场景。**注意**：在 Yocto 构建中，全局 `npm config set` 对 bitbake 内的 npm 无效——npm 配置必须通过环境变量或 `.npmrc` 注入。

### 策略一：设置 npm 注册表环境变量

适合：构建机有稳定的国内网络访问。

在 recipe 或构建环境中设置环境变量：

```bash
export npm_config_registry="https://registry.npmmirror.com/"
```

或在 `.npmrc` 中配置：

```
registry=https://registry.npmmirror.com/
```

### 策略二：设置超时环境变量

适合：网络能通但偶尔波动。

```bash
export npm_config_fetch_timeout=600000
export npm_config_fetch_retry_maxtimeout=120000
export npm_config_fetch_retry_mintimeout=30000
export npm_config_fetch_retry_factor=2
```

建议与策略一组合使用。

### 策略三：离线 npm 缓存

适合：构建机网络受限或不稳定（企业内网常见场景）。

**思路：** 在有外网权限的机器上预拉取 npm 依赖到本地缓存目录，再将缓存拷贝到构建机，通过 `npm_config_offline=true` + `npm_config_prefer_offline=true` 让 npm 完全离线工作。具体操作取决于你的构建环境和 npm 缓存布局，请根据实际情况实施。

## 策略选择指南

| 场景 | 推荐策略 | 理由 |
|------|---------|------|
| 使用 ob build | 自动处理（无需手动） | 内置探测 + 超时注入 |
| 直接 bitbake，构建机在国内 | 策略一 + 策略二 | 环境变量换源 + 延长超时 |
| 直接 bitbake，网络偶尔波动 | 策略二 | 延长超时即可 |
| 企业内网，网络受限 | 策略三（离线缓存） | 最可靠，不依赖网络 |
| CI/CD 自动化构建 | 策略三（离线缓存） | 可复现，不受网络影响 |
| 海外用户，npmjs.org 够快 | `OB_NPM_REGISTRY= ob build` | 禁用自动检测，用默认源 |

## 验收标准

- `bitbake webui-vue`（或对应的 npm recipe）`do_compile` task 成功完成
- 构建日志中不再出现 `ETIMEDOUT` 或 `network` 相关错误
- 如果使用离线缓存方案，确认 `npm_config_offline=true` 已生效（日志中应无外部网络请求）
- 使用 `ob build` 时，`workspace/configs/<machine>.npm-registry` 文件内容与实际构建日志中的 registry URL 一致

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 全局 `npm config set` 不影响 Yocto 构建 | 在构建机外执行 `npm config set` 有效，但 bitbake 内的 npm 不受影响 | Yocto 中 npm 配置必须通过环境变量（`npm_config_*`）或 `.npmrc` 控制 |
| 只换了源但依然超时 | npmmirror.com 同样可能不稳定，或个别包在 mirror 上不存在 | 组合使用策略一+策略二；如果频繁失败用策略三 |
| npmjs.org 单次快但持续慢 | 探测下载一个小文件很快（<1s），但 npm install 下载几百个包时出现极端尾部延迟（>30s） | 这是 `ob build` 探测默认选择 npmmirror.com 的原因——单次探测无法预测持续可靠性 |
| `--proxy=""` 导致 npm WARN | webui-vue recipe 传 `--proxy=${http_proxy}`，http_proxy 为空时 npm 报 invalid config | 通常只是警告不影响功能；如需消除可在 local.conf 设置 `http_proxy` |
| 直接 bitbake 拿不到 registry 注入 | `ob build` 在 bitbake 调用前通过 `BB_ENV_PASSTHROUGH_ADDITIONS` 注入 registry，直接 `bitbake` 不会触发探测 | 直接 bitbake 时需手动 export 环境变量，或使用 `ob build` |
| 缓存过期后网络状况已变 | 24h 缓存可能滞后：上午探测结果已不适用下午的网络状况 | 删除 `workspace/configs/<machine>.npm-registry` 强制重新探测 |
| 非中国用户使用 npmmirror.com 反而慢 | npmmirror.com 对海外用户可能比 npmjs.org 更慢 | 设置 `OB_NPM_REGISTRY= ob build` 禁用自动检测，或设为其他镜像 |

## 与其他 Skill 的关系

- 配合 `workflow_01-obmc_env_init.md` 中的构建流程使用
- 配合 `bestpractice_03-ai_debugging_diagnosis.md` 进行系统化诊断

## 变更日志

| 日期 | 变更 |
|------|------|
| 2026-06-10 | 初始版本，综合多位工程师的实战经验 |
| 2026-06-10 | 根据代码实战验证，修正策略误导、同步超时参数、补充 corner case |
