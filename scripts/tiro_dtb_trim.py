#!/usr/bin/env python3
"""Adapt the nubia device-trees so the tiro (NX769J) standalone Kleaf build
succeeds end-to-end inside the hermetic Bazel sandbox.

Three independent problems are handled here:

1. Generic techpack DTBOs (qcom/audio, qcom/bt, qcom/camera, ...) are built via
   `subdir-y` and their .dtsi pull headers such as <bindings/qcom,audio-ext-clk.h>
   that live ONLY in the separate sm8650-modules repo. Those headers are not part
   of the kernel_dtstree Bazel package, so they are missing in the sandbox and the
   DTB build fails. These techpack DTBOs are not consumed by the dist step, so we
   simply stop building them (drop the generic techpack `subdir-y += audio ...`
   line).

2. The kernel build definitions (msm-kernel/pineapple.bzl) generate per-board
   image genrules (pineapple_gki_dpm_image, ..._atp_image, ..._cdp_image, ...)
   for the FULL generic pineapple board set, and each unconditionally needs its
   board overlay .dtbo. But nubia's device-trees Makefile hides those overlays
   behind `ifeq ($(CONFIG_ZTE_BOARD_NAME),)`, so with CONFIG_ZTE_BOARD_NAME=tiro
   only pineapple-mtp-overlay.dtbo is produced and e.g. pineapple_gki_dpm_image
   fails with a missing input. These generic board overlays are tiny and use only
   standard <dt-bindings/*> headers (no sm8650-modules), so we un-guard them: the
   full pineapple board overlay set is built again, satisfying the image genrules,
   while the tiro overlay keeps building via its own subdir.

3. platform_map.bzl drives the *_dtc_dist dtbo image. We append the tiro overlay
   to the pineapple dtbo_list so zte-tiro-overlay.dtbo is included in the produced
   dtbo image (the stock 12 generic entries are kept, since they are all built
   again after step 2).

4. CONFIG_ZTE_BOARD_NAME is NOT set in the OnePlus-based kernel_platform config,
   so the stock `ifneq (,$(CONFIG_ZTE_BOARD_NAME))` guard never adds the tiro
   subdir and zte-tiro-overlay.dtbo is never built (the dtbo collection then
   fails with "Unable to find zte-tiro-overlay.dtbo"). We replace that
   conditional block with an unconditional `subdir-y += tiro`. We deliberately
   do NOT set CONFIG_ZTE_BOARD_NAME, so tiro-specific camera/display techpack
   configs (which need sm8650-modules headers absent from the sandbox) stay
   disabled; the tiro overlay closure itself only pulls local dtsi and standard
   <dt-bindings/*> headers.
"""
import re
import sys

dts_root = sys.argv[1] if len(sys.argv) > 1 else "sm8650-devicetrees"

# --- 1) qcom/Makefile: drop generic techpack subdir-y line ------------------
mk = f"{dts_root}/qcom/Makefile"
lines = open(mk).read().split("\n")
kept = [l for l in lines if not re.match(r"^subdir-y\s*\+=\s*audio\b", l)]
if len(lines) - len(kept) != 1:
    sys.exit(f"ERROR: expected to drop exactly 1 techpack subdir-y line, dropped {len(lines) - len(kept)}")
lines = kept
print("[tiro_dtb] dropped generic techpack subdir-y line in qcom/Makefile")

# --- 2) qcom/Makefile: un-guard the pineapple board overlay set -------------
# Remove the `ifeq ($(CONFIG_ZTE_BOARD_NAME),)` that immediately precedes the
# second `PINEAPPLE_BOARDS +=` block, together with its matching `endif`.
guard_idx = None
for i, l in enumerate(lines):
    if l.strip() == "ifeq ($(CONFIG_ZTE_BOARD_NAME),)" and i + 1 < len(lines) \
            and lines[i + 1].lstrip().startswith("PINEAPPLE_BOARDS"):
        guard_idx = i
        break
if guard_idx is None:
    sys.exit("ERROR: could not find the pineapple PINEAPPLE_BOARDS ZTE guard")
endif_idx = None
for j in range(guard_idx + 1, len(lines)):
    if lines[j].strip() == "endif":
        endif_idx = j
        break
if endif_idx is None:
    sys.exit("ERROR: could not find matching endif for the pineapple board guard")
del lines[endif_idx]
del lines[guard_idx]
print("[tiro_dtb] un-guarded the full pineapple board overlay set in qcom/Makefile")

# --- 4) qcom/Makefile: build the tiro overlay unconditionally ---------------
# CONFIG_ZTE_BOARD_NAME is empty in the OnePlus-based config, so the stock
# `ifneq (,$(CONFIG_ZTE_BOARD_NAME))` guard never adds the tiro subdir. Replace
# that 3-line block with an unconditional `subdir-y += tiro` so the overlay is
# actually built (without enabling ZTE-conditional techpack code paths).
zte_idx = None
for i, l in enumerate(lines):
    if l.lstrip().startswith("subdir-y") and "+=" in l and "$(CONFIG_ZTE_BOARD_NAME)" in l:
        zte_idx = i
        break
if zte_idx is None:
    sys.exit("ERROR: could not find 'subdir-y += $(CONFIG_ZTE_BOARD_NAME)' line")
if lines[zte_idx - 1].strip() != "ifneq (,$(CONFIG_ZTE_BOARD_NAME))":
    sys.exit(f"ERROR: unexpected line before ZTE subdir line: {lines[zte_idx - 1]!r}")
if lines[zte_idx + 1].strip() != "endif":
    sys.exit(f"ERROR: unexpected line after ZTE subdir line: {lines[zte_idx + 1]!r}")
tiro_line = lines[zte_idx].replace("$(CONFIG_ZTE_BOARD_NAME)", "tiro")
lines[zte_idx - 1:zte_idx + 2] = [tiro_line]
open(mk, "w").write("\n".join(lines))
print("[tiro_dtb] forced unconditional 'subdir-y += tiro' in qcom/Makefile")

# --- 3) qcom/platform_map.bzl: add tiro overlay to pineapple dtbo_list ------
pm = f"{dts_root}/qcom/platform_map.bzl"
pl = open(pm).read().split("\n")
try:
    start = next(i for i, l in enumerate(pl) if l.strip() == '"pineapple": {')
except StopIteration:
    sys.exit("ERROR: 'pineapple' platform block not found in platform_map.bzl")
end = next((i for i in range(start + 1, len(pl)) if re.match(r'^    "[^"]+": \{', pl[i])), len(pl))
block = "\n".join(pl[start:end])
head, sep, tail = block.partition('        "dtbo_list": [')
if not sep:
    sys.exit("ERROR: pineapple dtbo_list not found")
if "zte-tiro-overlay.dtbo" not in tail:
    tail = tail.replace(
        "\n        ],",
        '\n            {"name": "zte-tiro-overlay.dtbo"},\n        ],',
        1,
    )
block2 = head + sep + tail
pl[start:end] = block2.split("\n")
open(pm, "w").write("\n".join(pl))
print("[tiro_dtb] added zte-tiro-overlay.dtbo to pineapple dtbo_list")
print("[tiro_dtb] done")
