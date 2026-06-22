#!/usr/bin/env bash
# Integration sanity: run `ob init <machine> -d` end-to-end in a temporary
# harness with a fake OpenBMC checkout, so no real workspace state is mutated.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACHINE="${OB_INTEGRATION_MACHINE:-romulus}"
TMPROOT="$(mktemp -d)"
OUT="$(mktemp)"

cleanup() {
    rm -rf "$TMPROOT" "$OUT"
}
trap cleanup EXIT

cp "$ROOT/ob" "$TMPROOT/ob"
cp -a "$ROOT/lib" "$TMPROOT/lib"   # ob 入口 source lib/*.sh,须成套复制
mkdir -p "$TMPROOT/workspace/configs" "$TMPROOT/workspace/openbmc"
git -C "$TMPROOT/workspace/openbmc" init -q
git -C "$TMPROOT/workspace/openbmc" remote add origin https://github.com/openbmc/openbmc.git

cat > "$TMPROOT/workspace/openbmc/setup" <<SETUP
#!/usr/bin/env bash
if [[ \$# -eq 0 ]]; then
    echo "Use one of:"
    echo "  $MACHINE"
    exit 0
fi
build_dir="\${2:-build/$MACHINE}"
mkdir -p "\$build_dir/conf"
touch "\$build_dir/conf/local.conf"
SETUP
chmod +x "$TMPROOT/workspace/openbmc/setup"

if ! "$TMPROOT/ob" init "$MACHINE" -d --url https://github.com/openbmc/openbmc.git >"$OUT" 2>&1; then
    cat "$OUT"
    exit 1
fi

grep -q "Step 1/8" "$OUT" || { echo "missing Step 1/8"; cat "$OUT"; exit 1; }
grep -q "Step 8/8" "$OUT" || { echo "missing Step 8/8"; cat "$OUT"; exit 1; }
grep -q "\[DRY-RUN\]" "$OUT" || { echo "missing dry-run output"; cat "$OUT"; exit 1; }

echo "ok   init dry-run sanity ($MACHINE)"