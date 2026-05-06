#!/usr/bin/env bash
set -euo pipefail

run_with_progress() {
  local label="$1"
  shift
  local log_dir="/tmp/zed-yolo-build-logs"
  mkdir -p "$log_dir"
  local log_file="$log_dir/${label}.log"
  local heartbeat_seconds="${BUILD_HEARTBEAT_SECONDS:-60}"
  printf '\n===== BEGIN %s =====\n' "$label"
  printf 'command:'
  printf ' %s' "$@"
  printf '\nlog: %s\n' "$log_file"
  local start_epoch
  start_epoch=$(date +%s)
  "$@" >"$log_file" 2>&1 &
  local cmd_pid=$!
  tail -n +1 -f "$log_file" &
  local tail_pid=$!
  local next_heartbeat=$((start_epoch + heartbeat_seconds))

  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep 10
    local now
    now=$(date +%s)
    if [ "$now" -ge "$next_heartbeat" ]; then
      local elapsed=$((now - start_epoch))
      printf '\n[heartbeat] %s running for %ss pid=%s target=%s\n' \
        "$label" "$elapsed" "$cmd_pid" "${TARGET:-unknown}"
      ps -o pid,ppid,pcpu,pmem,rss,vsz,etime,comm -p "$cmd_pid" || true
      ps -eo pid,ppid,pcpu,pmem,rss,vsz,etime,comm,args \
        | grep -E 'cargo|rustc|zig|ld64|clang|cc1|sccache|mold|ld' \
        | grep -v grep \
        | sort -k3 -nr \
        | head -25 || true
      df -h /workspace /var/cache/sccache /tmp 2>/dev/null || true
      du -sh "target/${TARGET:-}" 2>/dev/null || true
      sccache --show-stats 2>/dev/null | sed -n '1,18p' || true
      next_heartbeat=$((now + heartbeat_seconds))
    fi
  done

  set +e
  wait "$cmd_pid"
  local status=$?
  set -e
  sleep 1
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  local end_epoch
  end_epoch=$(date +%s)
  printf '===== END %s status=%s elapsed=%ss log=%s =====\n' \
    "$label" "$status" "$((end_epoch - start_epoch))" "$log_file"
  return "$status"
}

metadata() {
  rm -rf dist
  mkdir -p dist
  local version
  version=$(cargo metadata --locked --no-deps --format-version 1 \
    | jq -r '.packages[] | select(.name == "zed") | .version' \
    | head -n 1)
  test -n "$version"
  {
    printf 'VERSION=%q\n' "$version"
    printf 'BUILD_DATE=%q\n' "$(date -u +%Y%m%d)"
    printf 'GIT_SHORT=%q\n' "$(git rev-parse --short=8 HEAD)"
    if [ -z "$(git status --porcelain --untracked-files=no)" ]; then
      printf 'DIRTY=%q\n' ""
    else
      printf 'DIRTY=%q\n' "-dirty"
    fi
  } > dist/build.env
  cat dist/build.env
}

build() {
  TARGET="$1"
  local label="$2"
  shift 2
  mkdir -p dist
  if [ ! -e "dist/${TARGET}.start" ]; then
    date +%s > "dist/${TARGET}.start"
  fi
  rustup target add "$TARGET"
  run_with_progress "${TARGET}-${label}" \
    /usr/bin/time -v cargo zigbuild --locked --release \
      --target "$TARGET" \
      --features gpui_platform/runtime_shaders \
      "$@"
}

package_target() {
  TARGET="$1"
  source dist/build.env
  local start
  start=$(cat "dist/${TARGET}.start")
  local end
  end=$(date +%s)
  local out_dir="dist/zed-yolo-v${VERSION}-${TARGET}-${BUILD_DATE}-g${GIT_SHORT}${DIRTY}"
  mkdir -p "$out_dir"
  cp "target/${TARGET}/release/zed" "$out_dir/zed"
  cp "target/${TARGET}/release/cli" "$out_dir/cli"
  cp "target/${TARGET}/release/remote_server" "$out_dir/remote_server"
  local tarball="${out_dir}.tar.zst"
  tar -C dist -I 'zstd -19 -T0' -cf "$tarball" "$(basename "$out_dir")"
  local sha
  sha=$(sha256sum "$tarball" | tee "$tarball.sha256" | awk '{print $1}')
  printf '{"package":"zed-yolo","version":"%s","target":"%s","filename":"%s","sha256":"%s","seconds":%s,"commit":"%s","build":"%s","date":"%s","runtime_shaders":true}\n' \
    "$VERSION" "$TARGET" "$(basename "$tarball")" "$sha" "$((end - start))" "$CNB_COMMIT" "$CNB_BUILD_ID" "$BUILD_DATE" \
    | tee "$tarball.build.json"
  ls -lh "$tarball" "$tarball.sha256" "$tarball.build.json"
}

case "${1:-}" in
  metadata)
    metadata
    ;;
  build)
    shift
    build "$@"
    ;;
  package)
    shift
    package_target "$@"
    ;;
  stats)
    sccache --show-stats || true
    ;;
  *)
    echo "usage: $0 {metadata|build <target> <label> <cargo package args...>|package <target>|stats}" >&2
    exit 2
    ;;
esac
