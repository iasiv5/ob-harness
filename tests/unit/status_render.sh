#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

# ---- main_repo (含 rc=0 leaf-pure 契约——unit 显式断言 rc,防 renderer return 非 0 在 set -e 下炸) ----
out=$(status_render_main_repo 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "main_repo missing rc" "$rc" 0
assert_contains "main_repo missing shows missing" "$out" "Status       : missing"
assert_false "main_repo missing hides present" grep -Fq "present" <<< "$out"

out=$(status_render_main_repo 1 "git://x/y" "mirror" "main" "abc1234" "✅ up-to-date" "2026-06-23T01:02:03Z" "/srv/ob"); rc=$?
assert_eq "main_repo present rc" "$rc" 0
assert_contains "main_repo present" "$out" "Status       : present"
assert_contains "main_repo source + label" "$out" "Source       : git://x/y (mirror)"
assert_contains "main_repo branch" "$out" "Branch       : main"
assert_contains "main_repo upstream passthrough" "$out" "Upstream     : ✅ up-to-date"
assert_contains "main_repo local path" "$out" "Local path   : /srv/ob"
assert_false "main_repo no init dash when provided" grep -Fq "First init   : <unknown>" <<< "$out"

# ---- machines: summary + expansion + record round-trip ----
my_machine_recs=(
    "romulus|initialized|present|42|2026-06-23T01:02:03Z|1|/tmp/deploy/romulus.static.mtd|2026-06-23T02:00:00Z"
    "partial1|partial|missing|3||0||"
)
out=$(status_render_machines my_machine_recs)
assert_contains "machines header" "$out" "Firmware Image"
assert_contains "machines init disp" "$out" "✅ initialized"
assert_contains "machines fw ready disp" "$out" "📦 ready"
assert_contains "machines fw missing disp" "$out" "— missing"
assert_contains "machines expansion romulus" "$out" "── romulus"
assert_contains "machines repos round-trip" "$out" "Repos        : 42"
assert_contains "machines fw name round-trip" "$out" "Firmware name: romulus.static.mtd"
assert_false "machines init time formatted not dash" grep -Fq "Init time    : -" <<< "$out"
assert_false "machines partial1 not expanded (snapshot=missing)" grep -Fq "── partial1" <<< "$out"

# ---- nameref business name self-check (F2): caller 数组名不得含 _sr_ 前缀 ----
my_recs=( "x|initialized|present|1||0||" )
out=$(status_render_machines my_recs); rc=$?
assert_eq "machines nameref business name rc" "$rc" 0
assert_contains "machines nameref business name works" "$out" "✅ initialized"

# ---- machines empty -> (none), returns 0 (leaf-pure) ----
empty_recs=()
out=$(status_render_machines empty_recs); rc=$?
assert_eq "machines empty rc" "$rc" 0
assert_contains "machines empty shows none" "$out" "(none)"

# ---- diagnostics ----
orphan_recs=( "orphan1|/tmp/orphan.static.mtd" )
out=$(status_render_diagnostics orphan_recs)
assert_contains "diag title" "$out" "Orphan firmware image artifacts"
assert_contains "diag name" "$out" "orphan1"
assert_contains "diag next step" "$out" "Next step : ./ob init orphan1"

empty_orphan=()
out=$(status_render_diagnostics empty_orphan); rc=$?
assert_eq "diag empty rc" "$rc" 0
assert_false "diag empty no section" grep -Fq "Orphan firmware" <<< "$out"

# ---- tips (4 分支全断言 rc=0——bp07 set -e 陷阱点:tips 空 tip 时末句若返回非 0 会在 cmd_status set -e 下炸;unit 虽 set +e,显式 assert rc 把这个契约钉进单测) ----
out=$(status_render_tips 0 0 0); rc=$?
assert_eq "tips no repo rc" "$rc" 0
assert_contains "tips no repo" "$out" "Run './ob init' to get started."
out=$(status_render_tips 1 0 0); rc=$?
assert_eq "tips has_init rc" "$rc" 0
assert_contains "tips no init machine" "$out" "to initialize a machine."
out=$(status_render_tips 1 1 1); rc=$?
assert_eq "tips no_fw rc" "$rc" 0
assert_contains "tips init no fw" "$out" "to produce a firmware image."
out=$(status_render_tips 1 1 0); rc=$?
assert_eq "tips fw_ready rc" "$rc" 0
assert_false "tips no tip when fw ready" grep -Fq "Run 'ob" <<< "$out"

assert_summary
