# Starts the packaged bb-app (either package: the flake runs this for bb-app-bin and for the bb-app that is
# built from the npm lock) for real and talks to it: no KVM, no systemd, no network beyond loopback.
#
#   1. `bb-app` boots the server and its co-located host daemon with HOME and the data dir in $TMPDIR,
#      which also proves the read-only store path works (BB writes only under its data dir).
#   2. GET /health on the loopback port returns {"ok":true,...} within the time limit.
#   3. `bb --version` prints the packaged version.
#   4. `bb machine list` (the CLI talking to the running server) shows the co-located daemon, so the
#      daemon's WebSocket to the server worked over loopback.
#   5. It stops bb-app and checks for a clean exit.
{
  lib,
  runCommand,
  curl,
  jq,
  bb-app,
}:
runCommand "smoke-${bb-app.pname}-${bb-app.version}"
  {
    nativeBuildInputs = [
      bb-app
      curl
      jq
    ];
    # Ports are picked per run: under libkrun TSI a loopback port that was just closed can keep
    # accepting for about a minute (forgejo-ci skill, section 3), so a fixed port would flake.
    expectedVersion = bb-app.version;
  }
  ''
    set -eu
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    data="$TMPDIR/data"
    port=$((41000 + RANDOM % 4000))
    hport=$((45100 + RANDOM % 4000))
    export BB_TELEMETRY=false NO_COLOR=1

    bb-app --no-in-app-updates --data-dir "$data" --server-bind-host 127.0.0.1 \
      --server-port "$port" --host-daemon-port "$hport" > "$TMPDIR/bb-app.log" 2>&1 &
    pid=$!
    fail() {
      echo "FAIL: $1" >&2
      echo "--- bb-app.log" >&2
      tail -60 "$TMPDIR/bb-app.log" >&2 || true
      for f in "$data"/logs/*; do
        [ -f "$f" ] || continue
        echo "--- $f" >&2
        tail -25 "$f" >&2 || true
      done
      kill "$pid" 2>/dev/null || true
      exit 1
    }

    ok=0
    for _ in $(seq 1 90); do
      if body=$(curl -fsS --max-time 3 "http://127.0.0.1:$port/health" 2>/dev/null); then
        ok=1
        break
      fi
      kill -0 "$pid" 2>/dev/null || fail "bb-app exited before /health answered"
      sleep 1
    done
    [ "$ok" = 1 ] || fail "/health did not answer in 90 s"
    echo "health: $body"
    echo "$body" | jq -e '.ok == true' > /dev/null || fail "/health is not ok"

    version=$(bb --version)
    echo "bb --version: $version"
    [ "$version" = "$expectedVersion" ] || fail "bb --version is '$version', expected '$expectedVersion'"

    export BB_DATA_DIR="$data" BB_SERVER_URL="http://127.0.0.1:$port"
    seen=0
    for _ in $(seq 1 60); do
      if machines=$(bb machine list --all --json 2> "$TMPDIR/machine-list.err") \
        && [ "$(echo "$machines" | jq 'length')" -ge 1 ]; then
        seen=1
        break
      fi
      sleep 1
    done
    if [ "$seen" != 1 ]; then
      cat "$TMPDIR/machine-list.err" >&2 || true
      fail "the co-located host daemon never showed up in 'bb machine list'"
    fi
    echo "machines: $(echo "$machines" | jq -c 'map({name, status})' 2>/dev/null || echo "$machines")"

    kill -TERM "$pid"
    rc=0
    wait "$pid" || rc=$?
    echo "bb-app exit status after SIGTERM: $rc"
    [ "$rc" = 0 ] || [ "$rc" = 143 ] || fail "bb-app did not stop cleanly (status $rc)"
    mkdir -p "$out"
    echo "$body" > "$out/health.json"
    echo "$version" > "$out/version"
  ''
