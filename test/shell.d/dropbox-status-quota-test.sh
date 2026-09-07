#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# status.py's PLAN_QUOTAS are base floors. When local usage exceeds the floor
# (referral/bonus space), quota must be reported unknown (issue #10356).

require_command python3
require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

home="$test_tmp/home"
dropbox_dir="$home/Dropbox"
mkdir -p "$dropbox_dir" "$home/.dropbox" "$test_tmp/bin"

# Basic plan floor is 2 GB. Write a single file larger than that so used > floor.
python3 - <<'PY' "$dropbox_dir/big.bin"
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(b"\0" * (3 * 1024 * 1024 * 1024 // 100))  # ~30MB is enough if we mock size...
PY

# os.walk uses real size; create a sparse-looking large file via truncate.
rm -f "$dropbox_dir/big.bin"
python3 - <<'PY' "$dropbox_dir/big.bin"
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.ftruncate(fd, 3_110_000_000)  # 3.11 GB sparse
os.close(fd)
PY

cat >"$home/.dropbox/info.json" <<'JSON'
{
  "personal": {
    "path": "REPLACE_PATH",
    "subscription_type": "Basic"
  }
}
JSON
# path must match the real folder
python3 - <<'PY' "$home/.dropbox/info.json" "$dropbox_dir"
import json, pathlib, sys
info = pathlib.Path(sys.argv[1])
data = json.loads(info.read_text())
data["personal"]["path"] = sys.argv[2]
info.write_text(json.dumps(data))
PY

# No dropbox-cli needed for quota path.
cat >"$test_tmp/bin/dropbox-cli" <<'SH'
#!/bin/bash
exit 127
SH
chmod +x "$test_tmp/bin/dropbox-cli"

# Prove the bug path first: old logic would set quotaKnown with used > quota.
# We only run the current helper and assert the fixed behaviour.
out=$(
  HOME="$home" PATH="$test_tmp/bin:/usr/bin:/bin" \
    python3 "$ROOT/shell/plugins/panels/dropbox/status.py" 5
)

echo "$out" | jq -e '.ok == true' >/dev/null || fail "status.py returns ok JSON" "$out"
echo "$out" | jq -e '.plan == "Basic"' >/dev/null || fail "status.py reads Basic plan" "$out"
echo "$out" | jq -e '.usedBytes > 2000000000' >/dev/null || fail "status.py sees used above 2GB floor" "$out"
echo "$out" | jq -e '.quotaKnown == false' >/dev/null ||
  fail "status.py marks quota unknown when used exceeds plan floor" "$out"
echo "$out" | jq -e '.quotaBytes == 0' >/dev/null ||
  fail "status.py clears quotaBytes when floor is not trustworthy" "$out"
echo "$out" | jq -e '.usagePercent == 0' >/dev/null ||
  fail "status.py does not report over-quota percent against a false floor" "$out"
pass "status.py marks quota unknown when used exceeds Basic plan floor"

# Under-floor usage still trusts the plan floor.
rm -rf "$dropbox_dir"
mkdir -p "$dropbox_dir"
printf 'small\n' >"$dropbox_dir/note.txt"
python3 - <<'PY' "$home/.dropbox/info.json" "$dropbox_dir"
import json, pathlib, sys
info = pathlib.Path(sys.argv[1])
data = json.loads(info.read_text())
data["personal"]["path"] = sys.argv[2]
info.write_text(json.dumps(data))
PY

out=$(
  HOME="$home" PATH="$test_tmp/bin:/usr/bin:/bin" \
    python3 "$ROOT/shell/plugins/panels/dropbox/status.py" 5
)

echo "$out" | jq -e '.quotaKnown == true' >/dev/null ||
  fail "status.py still trusts plan floor when used is under it" "$out"
echo "$out" | jq -e '.quotaBytes == 2000000000' >/dev/null ||
  fail "status.py reports Basic floor as 2GB when under floor" "$out"
pass "status.py still trusts plan floor when used is under it"
