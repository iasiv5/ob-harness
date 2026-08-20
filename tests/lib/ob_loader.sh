#!/usr/bin/env bash
# tests/lib/ob_loader.sh — 加载 ob 函数(不触发 main),处理 set -euo 泄漏。
# source 本文件后: $OB 指向仓库根 ob,ob 全部函数可用,errexit 已关。
# 原理: OB_NO_MAIN=1 让 ob 尾部 main 守卫跳过(line 4102);
#       ob 顶部 set -euo pipefail 经 source 泄漏,这里关 errexit 防首个非零
#       assert 整批中止(smoke_ob.sh 已验证此解法,保留 nounset/pipefail)。
OB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OB="$OB_DIR/ob"
# 必须 export 且在 source ob 之前: 二级 bash -c 'OB_NO_MAIN=1 source "$1"' child 不继承非 export 变量,
# 且 child 里 $0=_; 不设则 child 内 remedy 渲染错前缀。
export OB_CMD="${OB_CMD:-./ob}"
OB_NO_MAIN=1 source "$OB" || { echo "source ob failed" >&2; exit 1; }
set +e
