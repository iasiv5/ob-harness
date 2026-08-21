# SMOKE-08（Web 登录 + 登录后资源可达）实施计划

## 目标

- `probe_web.py` 增加轻量"登录"能力：数据驱动的 login 块（先 GET 拿 CSRF token + cookie，POST 凭据建立会话，再 GET 目标路径跑既有 asserts）。
- 凭据管道打通：`ar_probes.yaml` auth 新增 `web` interface → `ob test-qemu` 导出 `OB_TQ_WEB_USER/OB_TQ_WEB_PASSWORD` → runner 条件传参 → probe env fallback（密码不落 argv，沿用 redfish 惯例）。
- romulus（`tests/baseline/romulus`）与 b865g8（`contexts/baseline/b865g8-a2-bytedance`）两份 baseline 的 smoke suite 各新增 SMOKE-08；SMOKE-07 原样保留。
- plan.py schema 白名单放行 `login` 键（fail-closed 校验语义不变）。

## 架构快照

- login 是 **probe 的可选配置**（YAML `request.login`），不是新 probe type。未配置 login 的 web AR（SMOKE-07）行为零变化。
- probe_web 登录流程（针对 bmcweb 系 /login 端点）：
  1. 用带 CookieJar 的 opener GET `login.path`，捕获响应头 `X-CSRFTOKEN`（bmcweb 约定）+ cookies；
  2. POST `login.path`，body 为 `login.body` 模板（`{user}`/`{password}` 占位符替换），Content-Type 取 `login.content_type`，回带 X-CSRFTOKEN header；
  3. 响应 status ∈ `login.ok_statuses`（缺省 `[200, 201]`——b865g8 know-how 实测 WEB 登录返回 201）→ 登录成功；否则整 AR fail，reason 指名 `login failed with status N`；
  4. 用同一 opener（带会话 cookie）GET `request.path`，跑现有三类 asserts；
  5. best-effort 会话清理：若 `login.logout_path` 配置（Task 1 实测确认端点与 `logout_method`，缺省 POST；请求复用登录时拿到的 CSRF token 与 cookie），发之；失败只在 result 附加 note，不改变 verdict（对齐 probe_redfish mutating cleanup 先例，防 session 积累打满上限后假失败）。实测没有可靠登出端点就不配置 logout_path，不硬写。
- SMOKE-08 语义定位：**"登录成功（凭据有效 + 会话建立）+ 已登录会话资源可达"**。Web UI 是 SPA，`/` 与 `/login` 的静态 HTML 登录前后同构，服务端没有"首页渲染"可断——不声称"看到首页"。最终 GET 的 path 以 Task 1 实测定稿的"登录后判据资源"为准：优先选仅登录态可达的资源/接口（如需认证的 API），bmcweb 系兜底选 `/login`（已登录会话 GET 返 200、未登录 401），assert `status_in [200]` + `content_type_match text/html`。
- 自签证书照旧 `CERT_NONE`（复用 probe_web 现有 ssl 逻辑）。

## 全局约束

- 密码不落 argv（ps 全局可见）：runner 侧条件传参，probe 侧 `OB_TQ_WEB_USER/OB_TQ_WEB_PASSWORD` env 优先（与 redfish `_resolve_auth`、ipmi/console 同惯例）。
- runner 单副本共享（ADR-0027）：machine 差异只在数据 YAML——login 的 path/body/content_type 全部数据驱动，b865g8 若端点语义不同只改自己的 smoke.yaml，不动 runner 代码。
- smoke suite 是"服务可达性门"（ADR-0028）：SMOKE-08 语义 = 登录可达 + 凭据有效 + 会话资源可达，确定性 HTTP 断言，不引入浏览器/LLM。
- contexts/baseline/b865g8-a2-bytedance 是本地资产（gitignored 嵌套子仓），改动不同步进主仓 commit。
- `lib/qemu_commands.sh` 改动后必须跑 `tools/ob_check.sh` 配套自检。

## 输入工件

- 对话共识（2026-08-21）：SMOKE-07 保留 + 新增 SMOKE-08，轻量登录 API 方案，两份 baseline 都加。
- 凭据事实源：romulus auth 全 `root/0penBmc`；b865g8 WEB/Redfish/IPMI 凭据 `toutiao/toutiao!@#`（`contexts/knowhow/bestpractice_02-b865g8-bytedance-constraints.md:8,23-25`——`sysadmin` 仅 SSH/shell；且该文件实测 WEB 登录返回 **201**）。
- bmcweb /login 语义（GET 拿 X-CSRFTOKEN → POST form 凭据 → 200）需在 Task 1 对运行实例实测坐实，不凭记忆。

## 文件结构与职责

- Modify: `tests/baseline/runner/probe_web.py` — 新增 `--login/--user/--password` CLI、`_do_login()`、cookie jar opener；selftest 扩展。
- Modify: `tests/baseline/runner/plan.py` — `_ar_row()` web 分叉白名单加 `login`；login 块结构校验；plan dict 透传 `login`。
- Modify: `tests/baseline/runner/runner.py` — web 分派分支：`r.get("login")` 时追加 `--login` + 条件 `--user/--password`。
- Modify: `lib/qemu_commands.sh` — 前置 3 凭据解析 python 片段加 `pick("web")`（print 八行）、条件 export `OB_TQ_WEB_USER/OB_TQ_WEB_PASSWORD`、help Environment 段补 OB_TQ_WEB_* 两行说明。
- Modify: `tests/baseline/romulus/ar_probes.d/smoke.yaml` — 头注释加 SMOKE-08 行 + 新 AR 块。
- Modify: `tests/baseline/romulus/ar_probes.yaml` — auth 加 `web: root/0penBmc`。
- Modify: `contexts/baseline/b865g8-a2-bytedance/ar_probes.d/smoke.yaml` — 同 romulus 的 SMOKE-08（凭据走 auth.web）。
- Modify: `contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml` — auth 加 `web: toutiao/toutiao!@#`（WEB 凭据 = toutiao，与 redfish/ipmi 同）。
- Test: `tests/unit/test_qemu_runner.sh` — 现有 dry-run smoke 用例自动覆盖新 AR；按需补 login schema 负例。

## 任务清单

### Task 1: 实测坐实 /login 登录语义（romulus + b865g8）

- 目标：拿到两个 machine 真实 /login 请求/响应形态，锁定各自 smoke.yaml 的 login 块字面值**与"登录后判据资源"**；不凭 bmcweb 记忆硬编码。
- 涉及文件：无代码改动，产出写入本节计划文档附录（执行者回填）。
- 接口契约
  - Consumes: 运行中的 QEMU 实例（`./ob status` 确认；redfish 转发端口从 PID file 读）。
  - Produces: 两个 machine 的 login 块定稿（path/content_type/body/csrf/ok_statuses/logout_path）+ 登录后判据资源（SMOKE-08 的最终 GET path 与 asserts），供 Task 5/6 逐字使用。
- 验证范围：curl 三步法在两个实例上跑通（GET /login → POST → 带 cookie 复 GET）。
- [ ] Step 1: romulus 实测（真实密码经 shell 变量 + stdin 传给 curl，不落 argv）
  - Run: `./ob start-qemu romulus`（已运行则跳过）后：
    ```bash
    PORT=$(grep -o '"redfish_port":[0-9]*' <path-to-pidfile> | cut -d: -f2)
    WEB_USER=root WEB_PASSWORD='0penBmc'
    JAR=$(mktemp)
    curl -sk -c "$JAR" -D- -o /dev/null https://127.0.0.1:$PORT/login   # 记录状态码 + X-CSRFTOKEN
    TOKEN=$(curl -sk -c "$JAR" -D- https://127.0.0.1:$PORT/login | grep -i x-csrftoken | tr -d '\r' | awk '{print $2}')
    printf 'username=%s&password=%s' "$WEB_USER" "$WEB_PASSWORD" |
      curl -sk -b "$JAR" -c "$JAR" -D- -o /dev/null -X POST \
        -H "X-CSRFTOKEN: $TOKEN" -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-binary @- "https://127.0.0.1:$PORT/login"   # 期望 200/201
    curl -sk -b "$JAR" -D- -o /dev/null https://127.0.0.1:$PORT/login   # 期望 200（会话已建立）; 用后 rm -f "$JAR"
    ```
  - Expected: POST 返回 200（b865g8 实测有 201 先例——status 以实测为准，ok_statuses 按实测收录）；带 cookie 复 GET /login 返回 200。若形态不同（如 JSON body、不同 path），把实测结果记入附录并据此调整 Task 5 的 login 块字面值。**另测登出端点**（如 POST/DELETE `/logout` 或 Redfish session DELETE），确认可用的 `logout_path` 与 `logout_method`（POST 还是 DELETE）。
- [ ] Step 2: b865g8 同法实测（凭据 `toutiao/toutiao!@#`——WEB 凭据是 toutiao 不是 sysadmin，见输入工件事实源；注意 b865g8 QEMU 网络已知不稳，console 正常；若网络断先按 memory 的 macs_mask workaround 核实）
  - Expected: 同上，且 know-how 记录 WEB 登录返回 201（ok_statuses 至少含实测值）。b865g8 是定制 UI，端点可能不同——不同则以实测为准写入 Task 6。**同时探测登录后判据资源**：找一个仅登录态可达、能代表"首页数据加载"的资源或 API（如需认证的 /api/... 或 Redfish 会话查询）；找不到则兜底 GET /login 判 200。

### Task 2: probe_web.py 登录能力（TDD）

- 目标：probe_web 支持数据驱动 login；未配置 login 时行为与现状逐字节一致。
- 涉及文件：`tests/baseline/runner/probe_web.py`
- 接口契约
  - Consumes: Task 1 定稿的 login 流程语义（X-CSRFTOKEN + form POST + cookie 会话）。
  - Produces:
  - CLI：`--login '<JSON>'`、`--user U`、`--password W`（均可选）。
  - login JSON 契约：`{"path": str必填, "method": "POST"固定, "content_type": str缺省 application/x-www-form-urlencoded, "body": str必填含 {user}/{password} 占位符, "csrf": bool缺省 true, "ok_statuses": [int]缺省 [200, 201], "logout_path": str可选, "logout_method": str可选缺省 POST}`。logout best-effort：登录成功后按 logout_method 请求 logout_path（复用 cookie；若 cookie jar 存在 `XSRF-TOKEN` cookie 自动附 `X-XSRF-TOKEN` header——Task 1 b865g8 实测需要，无此 cookie 时无害省略），失败只附加 note 不改 verdict（对齐 probe_redfish mutating cleanup 先例，防 session 积累）；实测无可靠登出端点则不配置。
  - env fallback：`OB_TQ_WEB_USER` / `OB_TQ_WEB_PASSWORD`，再 fallback `OB_TQ_USER` / `OB_TQ_PASSWORD`；配置了 login 但凭据全缺 → `{"pass": false, "error": true, ...}` rc 3，reason 指名缺哪个。
  - 输出契约不变：stdout 恰一行 JSON dict，rc ∈ {0,1,3}。
- 验证范围：selftest 单测（登录成功/失败/无凭据/占位符替换/无 login 块零回归）。
- [ ] Step 1: 写失败测试
  - Change: `run_selftest()` 的 TestWebProbe 增 7 个用例：`test_login_success`（mock opener：GET 返 token、POST 返 200、终 GET 200）、`test_login_created_status_default_pass`（POST 返 **201**、login config **不写** ok_statuses → 默认 `[200, 201]` 收录、期望 pass——锁死 b865g8 201 事实，防实现退回只认 200 的假绿）、`test_login_bad_status`（POST 返 401 → fail，reason 含 `login failed with status 401`）、`test_login_missing_creds`（rc 3 error）、`test_login_placeholder_substitution`（body 模板替换断言）、`test_login_logout_best_effort`（logout 失败不改 pass verdict、附加 note）、`test_no_login_unchanged`（现有无 login 调用路径）。
- [ ] Step 2: 确认失败
  - Run: `python3 tests/baseline/runner/probe_web.py --selftest`
  - Expected: 新用例 ERROR/FAIL（`--login` 等参数与 `_do_login` 尚不存在）。
- [ ] Step 3: 最小实现
  - Change: `probe_web.py` 增加 `http.cookiejar.CookieJar` + `ssl` handler 的模块级 opener 构造 `_build_opener(ctx)`；`_do_login(opener, host, port, scheme, login_cfg, user, password, timeout)` 返回 `(ok, status, reason)`；`probe()` 改为接受 opener 与可选登录前置步骤；`main()` 加三个 CLI 参数与凭据解析优先级 argv > OB_TQ_WEB_* > OB_TQ_*。
- [ ] Step 4: 确认通过
  - Run: `python3 tests/baseline/runner/probe_web.py --selftest`
  - Expected: 全部用例 ok，exit 0。
- [ ] Step 5: checkpoint（默认输出 `git diff --stat` + `git status` 供确认；仅在用户明确要求本地 commit 时才提交，见执行纪律）

### Task 3: plan.py schema 放行 + runner 分派传参

- 目标：`request.login` 通过 fail-closed 校验并透传到 runner 分派；runner web 分支条件传 `--login/--user/--password`。
- 涉及文件：`tests/baseline/runner/plan.py`、`tests/baseline/runner/runner.py`、`tests/unit/test_qemu_runner.sh`
- 接口契约
  - Consumes: Task 2 的 login JSON 契约（同一套字段校验）。
  - Produces: plan 行 dict 新增 `login` 键（dict 或 None）；runner 分派 `probe_type == "web"` 时 `if r.get("login"): probe_args += ["--login", json.dumps(r["login"])]`，`if o["user"]: ... --user`、`if o["password"]: ... --password`（与 redfish 分支 195-198 行同构——argv 传参仅服务于人工调试直跑 runner 的场景，**ob test-qemu 路径从不传真实密码 argv**，凭据经 env 注入 probe 侧 fallback）。
- 验证范围：schema 负例（login 非法键/缺 path/method 非 POST）exit 3；dry-run 混合 suite exit 0；**非 dry-run stub probe 验证分派真实透传**。
- [ ] Step 1: 写失败检查
  - Change: `tests/unit/test_qemu_runner.sh` 增三段：① 临时 baseline 的 web AR 带 `login: {bad_key: 1}` → dry-run exit 3 且 stderr 指名非法键；② 合法 login 块 → dry-run exit 0 且输出含 SMOKE-08（只验 plan schema，不验分派）；③ **stub 分派测试**：临时目录整目录复制 `tests/baseline/runner/`，把其中 `probe_web.py` 换成 argv/env 记录 stub（把 argv 写文件后输出一行 pass JSON），起本地 HTTPS 不可达没关系——stub 不发请求；对 `--suite smoke` 非 dry-run 跑 runner。**注意 runner 非 dry-run 前置只认 `--user/--password` argv 或 `OB_TQ_USER/OB_TQ_PASSWORD` env**（runner.py:83-93），stub 测试 env 必须两组都设——`OB_TQ_USER/OB_TQ_PASSWORD` 满足前置，`OB_TQ_WEB_USER/OB_TQ_WEB_PASSWORD` 验证 probe 侧优先级：
    ```bash
    OB_TQ_USER=dummy OB_TQ_PASSWORD=dummy \
    OB_TQ_WEB_USER=dummyweb OB_TQ_WEB_PASSWORD=dummyweb \
    bash "$_tmp_runner/run.sh" --host 127.0.0.1 --port 1 --suite smoke
    ```
    断言 stub 记录的 argv 含 `--login`、不含任何密码（dummy 密码也只经 env，不进 argv），且 stub 读到的凭据是 `OB_TQ_WEB_*` 的值（dummyweb，优先于 OB_TQ_USER 的 dummy）。
  - Run: `bash tests/unit/test_qemu_runner.sh`
  - Expected: 新断言失败（plan 白名单未放行 / runner 未传 --login）。
- [ ] Step 2: 实现
  - Change: `plan.py` web 分叉白名单 `{"path", "scheme"}` → `{"path", "scheme", "login"}`；新增 login 结构校验（dict；allowed keys = `path/method/content_type/body/csrf/ok_statuses/logout_path/logout_method`，未知键 exit 3 指名；path 必填无控制字符、method 若给必须 `"POST"`、body 必填 str、csrf bool、ok_statuses list[int]、content_type str、**logout_path 若给必须是无控制字符 str、logout_method 若给只能是 `"POST"`/`"DELETE"`**（缺省 POST））；返回 dict 加 `"login": req.get("login")`。`runner.py` web 分支按 Produces 加条件传参。schema 负例/正例覆盖 `logout_method`（非法值如 `"GET"` → exit 3）。
- [ ] Step 3: 确认通过
  - Run: `bash tests/unit/test_qemu_runner.sh && python3 tests/baseline/runner/probe_web.py --selftest`
  - Expected: 两者 exit 0。
- [ ] Step 4: checkpoint（默认输出 `git diff --stat` + `git status` 供确认；仅在用户明确要求本地 commit 时才提交，见执行纪律）

### Task 4: qemu_commands.sh 凭据管道（auth.web → OB_TQ_WEB_*）

- 目标：`ob test-qemu` 从 ar_probes.yaml `auth.web`（fallback auth 顶层）解析并 export `OB_TQ_WEB_USER/OB_TQ_WEB_PASSWORD`；help 文档同步。
- 涉及文件：`lib/qemu_commands.sh`（前置 3 段约 768-840 行 + help Environment 段约 591-609 行）
- 接口契约
  - Consumes: ar_probes.yaml auth 块（Task 5/6 会补 `web` 子键）。
  - Produces: env `OB_TQ_WEB_USER/OB_TQ_WEB_PASSWORD`（env 已设者胜，YAML 只补缺；全缺不 export，web login AR 由 probe error 3 指名——与 ipmi 惯例一致，纯 redfish suite 不受影响）。
- 验证范围：定向回归锁（auth.web 解析与 env 优先级）+ ob_check.sh 全量自检。
- [ ] Step 1: 定向回归锁（先写）
  - Change: `tests/protocol/test_qemu_surface.sh`（或同文件内合适位置）新增用例：临时 baseline 构造 `auth.redfish = redfish_user/redfish_pass` + `auth.web = web_user/web_pass`，通过 stub runner/probe（或可观测 env 落盘）断言注入的 `OB_TQ_WEB_USER=web_user`、`OB_TQ_WEB_PASSWORD=web_pass` 且 `OB_TQ_USER=redfish_user`（八行 mapfile 下标正确）；第二段设外部 `OB_TQ_WEB_USER=env_wins` 已存在时，断言 env 值胜出（YAML 不覆盖 env）。
  - Run: `bash tests/protocol/test_qemu_surface.sh`
  - Expected: 新用例失败（pick("web") 未实现）。
- [ ] Step 2: 实现
  - Change: 前置 3 的 python 片段加 `u, p = pick("web")` 与两行 print（六行变八行）；mapfile 下标顺延补 `_web_user/_web_pass`；沿用 console 的 `if [[ -n ... ]]` 形式条件 export；help Environment 段在 OB_TQ_CONSOLE_* 之后补 OB_TQ_WEB_* 两行说明（文案风格对齐既有条目）。
- [ ] Step 3: 确认定向用例通过
  - Run: `bash tests/protocol/test_qemu_surface.sh`
  - Expected: exit 0（含新用例）。
- [ ] Step 4: 聚合门禁
  - Run: `bash tools/ob_check.sh`
  - Expected: exit 0（结构/函数登记/shellcheck baseline/测试全过，含上面新增用例）。
- [ ] Step 5: checkpoint（默认输出 `git diff --stat` + `git status` 供确认；仅在用户明确要求本地 commit 时才提交，见执行纪律）

### Task 5: romulus baseline 新增 SMOKE-08

- 目标：romulus smoke suite 7→8 AR，auth 补 web。
- 涉及文件：`tests/baseline/romulus/ar_probes.d/smoke.yaml`、`tests/baseline/romulus/ar_probes.yaml`
- 接口契约
  - Consumes: Task 1 实测定稿的 login 块字面值；Task 2/3 的 login 契约。
  - Produces: SMOKE-08 AR 定义（供 test_qemu_runner.sh dry-run 与 live 验证消费）。
- 验证范围：dry-run 列出 SMOKE-08 且 exit 0。
- [ ] Step 1: 改 YAML
  - Change: `ar_probes.d/smoke.yaml` 头注释加 `SMOKE-08 Web 登录(POST /login 建会话) + 登录后 GET /login 200`；SMOKE-07 块后新增：
    ```yaml
    - ar: SMOKE-08       (BMC Web UI login + post-login session reachability)
      name: Web UI login + post-login session resource reachable
      probe: web
      suite: smoke
      request:
        path: /login   # ← Task 1 定稿的"登录后判据资源"; 实测找到更好的仅登录态资源则替换
        scheme: https
        login:
          path: /login
          content_type: application/x-www-form-urlencoded
          body: "username={user}&password={password}"
          csrf: true
          ok_statuses: [200, 201]
          logout_path: /logout   # ← Task 1 实测定稿; 无可靠登出端点则整行删掉, 不硬写
      assert:
        - type: status_in
          value: [200]
        - type: content_type_match
          value: text/html
      depends_on: [SMOKE-07]
      rationale: >
        <按 Task 1 实测语义写两三句: GET /login 拿 X-CSRFTOKEN → POST 凭据建会话 →
        带 cookie GET 登录后判据资源 200, 证明凭据有效且已登录会话资源可达;
        SPA 无服务端"首页"可断, 不声称"看到首页">
    ```
    （login 块字面值若 Task 1 实测与上不同，以实测为准。）`ar_probes.yaml` auth 加 `web: {user: root, password: "0penBmc"}`。
- [ ] Step 2: dry-run 验证
  - Run: `cd tests/baseline/romulus && OB_TQ_AR_PROBES=$PWD/ar_probes.yaml OB_TQ_APPL=$PWD/applicability.yaml python3 ../runner/runner.py --host 127.0.0.1 --port 1 --user dummy --password dummy --suite smoke --dry-run; cd -`
  - 说明: dry-run 不 probe，用 dummy 凭据即可（凭据前置只需"至少一源"）；真实密码只在 live 验证（Task 7）经 env 注入，不落 argv。
  - Expected: 输出列出 SMOKE-01..08，exit 0（dry-run 不 probe，不需要实例）。
- [ ] Step 3: checkpoint（默认输出 `git diff --stat` + `git status` 供确认；仅在用户明确要求本地 commit 时才提交，见执行纪律）

### Task 6: b865g8 baseline 新增 SMOKE-08（本地资产，不进主仓 commit）

- 目标：b865g8 smoke suite 同步 7→8 AR，auth.web 用 toutiao 凭据（WEB 凭据与 redfish/ipmi 同为 toutiao）。
- 涉及文件：`contexts/baseline/b865g8-a2-bytedance/ar_probes.d/smoke.yaml`、`contexts/baseline/b865g8-a2-bytedance/ar_probes.yaml`
- 接口契约
  - Consumes: Task 1 Step 2 实测的 b865g8 端点形态与登录后判据资源（定制 UI 可能与 romulus 不同；登录 status 实测为 201）。
  - Produces: b865g8 SMOKE-08 定义。
- 验证范围：dry-run 列出 SMOKE-08 且 exit 0。
- [ ] Step 1: 改 YAML
  - Change: 与 Task 5 同构；login 块按 b865g8 实测调整（ok_statuses 含 201；最终 GET path 用 Task 1 定稿的登录后判据资源）；`ar_probes.yaml` auth 加 `web: {user: toutiao, password: "toutiao!@#"}`（WEB 凭据 = toutiao，与 redfish/ipmi 同——`sysadmin` 仅 SSH/shell）。
- [ ] Step 2: dry-run 验证
  - Run: `cd contexts/baseline/b865g8-a2-bytedance && OB_TQ_AR_PROBES=$PWD/ar_probes.yaml OB_TQ_APPL=$PWD/applicability.yaml python3 /bmc/iasi/ob-harness/tests/baseline/runner/runner.py --host 127.0.0.1 --port 1 --user dummy --password dummy --suite smoke --dry-run; cd -`
  - Expected: 列出 SMOKE-01..08，exit 0。

### Task 7: live 验证 + 文案对齐

- 目标：两个 machine 真跑 SMOKE-08 确认 PASS；"7 个 AR 门"文案对齐为 8。
- 涉及文件：`tests/baseline/romulus/ar_probes.d/smoke.yaml`（头注释已在 Task 5 改）、`docs/adr/0028-smoke-merged-into-test-qemu-suite.md`（如提及门数量）、`tests/baseline/README.md`（如有）。
- 接口契约
  - Consumes: Task 1-6 全部产出 + 运行中的 QEMU 实例。
  - Produces: live PASS 证据。
- 验证范围：`ob test-qemu --suite smoke` 两实例 PASS；grep 无残留 "7 个 AR"。
- [ ] Step 1: romulus live（真实凭据经 env 注入，不落 argv）
  - Run: `OB_TQ_USER=root OB_TQ_PASSWORD='0penBmc' ./ob test-qemu romulus --suite smoke`
  - Expected: SMOKE-01..08 全 PASS，exit 0。SMOKE-08 fail 则读 report 行定位（凭据错 → login failed with status 401/403）。
- [ ] Step 2: b865g8 live（真实凭据经 env 注入；注意 memory 已知网络坑：启动前 grep macs_mask 核实 workaround 在位；若断网重启 QEMU 单次 boot）
  - Run: `OB_TQ_USER=toutiao OB_TQ_PASSWORD='toutiao!@#' ./ob test-qemu b865g8-a2-bytedance --suite smoke`
  - Expected: smoke PASS（含 SMOKE-08）。
- [ ] Step 3: 文案对齐
  - Run: `grep -rn "7 个 AR\|7-AR\|7 AR 服务\|5-AR\|5 条可达性\|5 条" tests/ docs/adr/ rules/ --include="*.md" --include="*.py" --include="*.yaml" | grep -v docs/plans`
  - Expected: 当前态文案（如 runner help `5-AR reachability gate`）全部对齐为 8 并一句话说明 SMOKE-08 语义；ADR 中的历史记述（"当时 5 条"）保留原文但补一行"现 8 条（+SMOKE-06/07/08）"的历史注记，不篡改决策时点语义。
- [ ] Step 4: 最终验证（见下）+ 收尾 checkpoint（`git diff --stat` + `git status` 汇总；不 commit，见执行纪律）

## 附录: Task 1 实测结果（2026-08-21, b865g8-a2-bytedance live, Redfish 443→2443）

**b865g8（AMI OneTree bmcweb）— 全流程坐实：**

1. **login**: `POST /login`，`Content-Type: application/json`，body `{"username":"<user>","password":"<pwd>"}`（小写键；大写 `Username/Password` 返 400）→ **200**；无需预 GET 拿 CSRF（匿名 POST 即成）；响应 Set-Cookie `SESSION` + `XSRF-TOKEN`。form-urlencoded 返 400。
2. **判据资源**: `GET /redfish/v1/SessionService/Sessions` 带 SESSION cookie → **200**（匿名 401）——web 会话与 Redfish 共享 session store，这是本机最可靠的"仅登录态可达"判据；Content-Type 是 `application/json` 不是 text/html。`GET /login` 匿名 401 / 带会话 **405**（只许 POST）；`GET /` 匿名也 200——两者都不能当判据。
3. **logout**: `POST /logout` 带 `X-XSRF-TOKEN: <XSRF-TOKEN cookie 值>` header（不带则 401）→ **200**，SESSION cookie 置空过期，会话确认销毁（登出后判据资源 401）。

**login 块字面值定稿（b865g8，供 Task 6 逐字使用）**：`csrf: false`，`content_type: application/json`，`body: '{"username":"{user}","password":"{password}"}'`，`ok_statuses: [200]`（本机实测 200；缺省 [200,201] 兼容）；`logout_path: /logout`，`logout_method: POST`。logout 的 CSRF header 约定：probe 发 logout 时若 cookie jar 有 `XSRF-TOKEN` cookie，自动附 `X-XSRF-TOKEN` header（b865g8 实测需要；无此 cookie 的实现无害）。

**romulus — 无法本机实测**：本 harness 只有 b865g8 machine（custom 谱系），romulus 无 firmware/实例。Task 5 的 romulus login 块按 b865g8 同款 JSON 形态写（同代 bmcweb 血统），rationale 显式标注"login 形态在 b865g8 实测定稿，romulus 侧待社区实例 live 校准"；Task 7 的 romulus live 验证降级为 dry-run + 标注。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改变任务目标。
- 每完成一个任务，运行该任务定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符（尤其 Task 1 实测 /login 语义与预设不符），立即停下说明，不猜。
- 提交边界：checkpoint/收尾**默认只输出 diff/status，不 commit**；仅当用户明确要求本地提交时才在当前 feature 分支（feature/smoke-merge-into-test-qemu）创建 checkpoint commit，且**不 push、不 merge**——push/PR 需用户另行授权；b865g8 contexts 改动在嵌套子仓，不进主仓 commit。
- 真实密码（0penBmc / toutiao!@#）只经 env 注入，任何验证命令的 argv 不出现真实密码。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `python3 tests/baseline/runner/probe_web.py --selftest && bash tests/unit/test_qemu_runner.sh && bash tools/ob_check.sh`
- Expected: 三者全部 exit 0。
- Run: `./ob test-qemu romulus --suite smoke` 与 `./ob test-qemu b865g8-a2-bytedance --suite smoke`
- Expected: 两个 machine smoke suite（8 AR）全 PASS，exit 0。
- Run: `grep -rn "login failed" tests/baseline/runner/probe_web.py | head -1`
- Expected: 命中 reason 文案（确认失败路径可诊断）。

## 审阅 Checkpoint

计划正文结束。请审阅。
