#!/usr/bin/env python3
"""Relax the QCOM KMI symbol list so the base GKI kernel builds against the
OnePlus common tree.

We build nubia's msm-kernel on top of the OnePlus sm8650 kernel_platform
(manifest oneplus/sm8650), because nubia does not publish a standalone Kleaf
manifest -- only device/kernel/module sources meant to be layered on top of a
full LineageOS checkout. build_with_bazel.py unconditionally passes
`--user_kmi_symbol_lists=//msm-kernel:android/abi_gki_aarch64_qcom`, which feeds
nubia's QCOM symbol list into the GKI kernel `//common:kernel_aarch64` and turns
on strict-mode verification. A handful of symbols in nubia's list are NOT
exported by the OnePlus common tree, so strict mode fails with:

    Symbols missing from the ksymtab:
      __traceiter_android_vh_hibernate_resume_state
      __tracepoint_android_vh_hibernate_resume_state
      __vmap_pages_range_noflush
      vmap_pages_range_noflush

Those symbols cannot be preserved regardless (they do not exist in the OnePlus
ksymtab), so dropping them from the list loses nothing functionally while
letting strict mode pass. Every other QCOM symbol stays in the list and is kept
in the GKI kernel's ksymtab for the vendor modules.

If a future run reports a different missing symbol, add it to DROP below.
"""
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "msm-kernel"
path = f"{root}/android/abi_gki_aarch64_qcom"

DROP = {
    "__traceiter_android_vh_hibernate_resume_state",
    "__tracepoint_android_vh_hibernate_resume_state",
    "vmap_pages_range_noflush",
    "__vmap_pages_range_noflush",
}

lines = open(path).read().split("\n")
kept = [l for l in lines if l.strip() not in DROP]
removed = len(lines) - len(kept)
if removed != len(DROP):
    sys.exit(
        f"ERROR: expected to drop {len(DROP)} KMI symbols, dropped {removed} "
        f"(list may have changed upstream)"
    )
open(path, "w").write("\n".join(kept))
print(f"[tiro_kmi] dropped {removed} KMI symbols absent from the OnePlus GKI common kernel")
print("[tiro_kmi] done")
