#!/usr/bin/env bash
set -euo pipefail

# Capture symbol/config/source identity needed to decode a future Tiro panic.
# Usage:
#   kurumi_capture_crash_debug.sh <variant> <build_root> <dist_dir> <kernel_tree> [dts_tree]
#
# The helper is intentionally best-effort for optional files: a build must not
# fail merely because Kleaf put vmlinux/System.map in a different output path.

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 <variant> <build_root> <dist_dir> <kernel_tree> [dts_tree]" >&2
  exit 2
fi

VARIANT=$1
BUILD_ROOT=$(realpath "$2")
DIST_DIR=$(realpath "$3")
KERNEL_TREE=$(realpath "$4")
DTS_TREE=${5:-}
if [[ -n "$DTS_TREE" ]]; then
  DTS_TREE=$(realpath "$DTS_TREE")
fi

WORKSPACE=${GITHUB_WORKSPACE:-$(pwd)}
OUT="$WORKSPACE/crash-debug/$VARIANT"
mkdir -p "$OUT"

copy_if_present() {
  local src=$1
  local dst=${2:-$(basename "$src")}
  if [[ -f "$src" ]]; then
    cp -f "$src" "$OUT/$dst"
  fi
}

# Dist artifacts are exact outputs from the variant that was just built.
for f in Image Image.gz Image.lz4 boot.img vendor_boot.img dtbo.img init_boot.img \
         System.map Module.symvers kernel.release; do
  copy_if_present "$DIST_DIR/$f"
done

# Kleaf normally keeps an unstripped vmlinux below out/. Compress it ourselves
# to keep GitHub artifact transfer reasonable while preserving exact symbols.
VMLINUX=$(find "$BUILD_ROOT" -type f -name vmlinux -not -path '*/host/*' -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr | head -n1 | cut -d' ' -f2- || true)
if [[ -n "$VMLINUX" && -f "$VMLINUX" ]]; then
  gzip -1 -c "$VMLINUX" > "$OUT/vmlinux.gz"
  printf '%s\n' "$VMLINUX" > "$OUT/vmlinux.source-path.txt"
else
  echo "WARN: vmlinux not found below $BUILD_ROOT" > "$OUT/vmlinux.source-path.txt"
fi

# Prefer the config embedded in the exact Image. This avoids confusing source
# defconfig with the final resolved Kconfig after Kleaf fragments.
IMG=""
for candidate in "$DIST_DIR/Image" "$DIST_DIR/Image.gz" "$DIST_DIR/Image.lz4"; do
  [[ -f "$candidate" ]] && { IMG=$candidate; break; }
done
if [[ -n "$IMG" && -x "$KERNEL_TREE/scripts/extract-ikconfig" ]]; then
  "$KERNEL_TREE/scripts/extract-ikconfig" "$IMG" > "$OUT/final.config" 2>/dev/null || true
  [[ -s "$OUT/final.config" ]] || rm -f "$OUT/final.config"
fi

# Fallback for builds without IKCONFIG: retain the newest resolved .config.
# This is less authoritative than extract-ikconfig, so record its source path.
if [[ ! -f "$OUT/final.config" ]]; then
  CONFIG_SRC=$(find "$BUILD_ROOT" -type f -name .config -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2- || true)
  if [[ -n "$CONFIG_SRC" && -f "$CONFIG_SRC" ]]; then
    cp -f "$CONFIG_SRC" "$OUT/final.config"
    printf '%s\n' "$CONFIG_SRC" > "$OUT/final.config.source-path.txt"
  fi
fi

# Preserve CI-applied tracked source deltas as well. The kernel-only workflows
# create a temporary "kurumi base ..." commit so KSU/SuSFS variants can reset
# to the exact customized stock tree. In that case diff from HEAD^, not HEAD,
# so the bundle contains BOTH the base Kurumi changes and root-variant changes.
capture_git_delta() {
  local tree=$1
  local prefix=$2
  [[ -d "$tree/.git" || -f "$tree/.git" ]] || return 0

  local base=HEAD
  local subject
  subject=$(git -C "$tree" log -1 --format=%s 2>/dev/null || true)
  if [[ "$subject" == kurumi\ base\ before* ]] && git -C "$tree" rev-parse HEAD^ >/dev/null 2>&1; then
    base=HEAD^
  fi

  {
    echo "tree=$tree"
    echo "head=$(git -C "$tree" rev-parse HEAD 2>/dev/null || true)"
    echo "delta_base=$(git -C "$tree" rev-parse "$base" 2>/dev/null || true)"
    echo "head_subject=$subject"
  } > "$OUT/$prefix-source-base.txt"

  if ! git -C "$tree" diff --quiet "$base" -- 2>/dev/null; then
    git -C "$tree" diff --binary "$base" -- 2>/dev/null | gzip -1 > "$OUT/$prefix-source.diff.gz" || true
  fi

  # Record untracked paths. Their content is either in this CI repository
  # (Kurumi integration sources) or in a separately identified nested repo
  # (e.g. KernelSU), so avoid ballooning the debug artifact with whole clones.
  git -C "$tree" ls-files --others --exclude-standard 2>/dev/null \
    > "$OUT/$prefix-untracked-files.txt" || true
  [[ -s "$OUT/$prefix-untracked-files.txt" ]] || rm -f "$OUT/$prefix-untracked-files.txt"
}

capture_git_delta "$KERNEL_TREE" kernel
if [[ -n "$DTS_TREE" ]]; then
  capture_git_delta "$DTS_TREE" device-tree
fi

# Kernel-only builds also modify the Nubia msm-kernel sibling; full ROM builds
# have the separate sm8650-modules sibling. Preserve those tracked deltas too.
SIBLING_ROOT=$(dirname "$KERNEL_TREE")
[[ -d "$SIBLING_ROOT/msm-kernel" ]] && capture_git_delta "$SIBLING_ROOT/msm-kernel" msm-kernel
[[ -d "$SIBLING_ROOT/sm8650-modules" ]] && capture_git_delta "$SIBLING_ROOT/sm8650-modules" sm8650-modules

# If System.map/Module.symvers were not exported to dist, retain the newest
# exact build copies when discoverable.
for wanted in System.map Module.symvers; do
  if [[ ! -f "$OUT/$wanted" ]]; then
    found=$(find "$BUILD_ROOT" -type f -name "$wanted" -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | head -n1 | cut -d' ' -f2- || true)
    [[ -n "$found" && -f "$found" ]] && cp -f "$found" "$OUT/$wanted"
  fi
done

{
  echo "variant=$VARIANT"
  echo "captured_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "github_run_id=${GITHUB_RUN_ID:-unknown}"
  echo "github_run_number=${GITHUB_RUN_NUMBER:-unknown}"
  echo "github_sha=${GITHUB_SHA:-unknown}"
  echo
  echo "[kernel]"
  git -C "$KERNEL_TREE" rev-parse HEAD 2>/dev/null || true
  git -C "$KERNEL_TREE" status --short 2>/dev/null || true
  echo
  if [[ -n "$DTS_TREE" && -d "$DTS_TREE/.git" ]]; then
    echo "[device-tree]"
    git -C "$DTS_TREE" rev-parse HEAD 2>/dev/null || true
    git -C "$DTS_TREE" status --short 2>/dev/null || true
    echo
  fi
  # Capture sibling vendor/module repositories used by the two build layouts.
  for sibling in "$(dirname "$KERNEL_TREE")/msm-kernel" \
                 "$(dirname "$KERNEL_TREE")/sm8650-modules"; do
    if [[ -d "$sibling/.git" ]]; then
      echo "[$(basename "$sibling")]"
      git -C "$sibling" rev-parse HEAD 2>/dev/null || true
      git -C "$sibling" status --short 2>/dev/null || true
      echo
    fi
  done

  # KSU/SuSFS locations vary between workflows; capture any repository we can
  # identify without making symbol collection depend on a particular layout.
  for tree in \
      "$KERNEL_TREE/KernelSU-Next" "$KERNEL_TREE/KernelSU" \
      "$BUILD_ROOT/KernelSU-Next" "$BUILD_ROOT/KernelSU" "$BUILD_ROOT/susfs4ksu" \
      "$WORKSPACE/KernelSU-Next" "$WORKSPACE/KernelSU" "$WORKSPACE/susfs4ksu" \
      "$(dirname "$KERNEL_TREE")/KernelSU-Next" "$(dirname "$KERNEL_TREE")/KernelSU" \
      "$(dirname "$KERNEL_TREE")/susfs4ksu"; do
    if [[ -d "$tree/.git" ]]; then
      echo "[$(basename "$tree")]"
      git -C "$tree" rev-parse HEAD 2>/dev/null || true
      git -C "$tree" describe --always --tags --dirty 2>/dev/null || true
      echo
    fi
  done

  # CI integration scripts already persist useful resolved refs in kimg/.
  if [[ -d "$WORKSPACE/kimg" ]]; then
    echo "[kimg-resolved-refs]"
    for f in "$WORKSPACE"/kimg/*ref* "$WORKSPACE"/kimg/*version* "$WORKSPACE"/kimg/*commit*; do
      [[ -f "$f" ]] || continue
      printf '%s=' "$(basename "$f")"
      tr '\n' ' ' < "$f"
      echo
    done
    echo
  fi
} > "$OUT/source-identity.txt"

(
  cd "$OUT"
  # Never hash SHA256SUMS itself: the redirection creates it before find runs.
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum
) > "$OUT/SHA256SUMS"

echo "Kurumi crash-debug bundle captured: $OUT"
ls -lh "$OUT" || true
