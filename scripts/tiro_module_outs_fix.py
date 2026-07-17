#!/usr/bin/env python3
"""tiro_module_outs_fix.py

The nubia pineapple defconfig builds drivers/leds/aw22xxx/zte_led.ko (the
ZTE/nubia RGB LED driver) as an in-tree module, but pineapple.bzl's
`_pineapple_in_tree_modules` list -- which becomes the `module_outs` attribute of
//msm-kernel:pineapple_gki -- does not declare it. Kleaf then aborts the build
with:

    ERROR: The following kernel modules are built but not copied.
    Add these lines to the module_outs attribute of @//msm-kernel:pineapple_gki:
        "drivers/leds/aw22xxx/zte_led.ko",

This script inserts the missing .ko(s) into `_pineapple_in_tree_modules`
(idempotent, keeps the list alphabetically sorted). Extend MODULES if a later
build reports more undeclared modules.

Usage: tiro_module_outs_fix.py [msm-kernel-root]   (default: msm-kernel)
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "msm-kernel"
BZL = os.path.join(ROOT, "pineapple.bzl")

# In-tree .ko files that the config builds but pineapple.bzl fails to declare.
MODULES = [
    "drivers/leds/aw22xxx/zte_led.ko",
]

with open(BZL) as f:
    lines = f.read().split("\n")

# Locate the opening of the `_pineapple_in_tree_modules = [` list.
start = None
for i, l in enumerate(lines):
    if l.strip().startswith("_pineapple_in_tree_modules") and l.rstrip().endswith("["):
        start = i
        break
if start is None:
    sys.exit("ERROR: '_pineapple_in_tree_modules = [' not found in " + BZL)

# Locate the closing bracket of that list.
end = None
for i in range(start + 1, len(lines)):
    if lines[i].strip() == "]":
        end = i
        break
if end is None:
    sys.exit("ERROR: end of _pineapple_in_tree_modules list not found in " + BZL)

# Infer indentation from the first real entry.
indent = "        "
for i in range(start + 1, end):
    if lines[i].strip().startswith('"'):
        indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
        break

added = 0
for mod in MODULES:
    quoted = '"%s"' % mod
    if any(quoted in lines[j] for j in range(start + 1, end)):
        continue  # already declared
    entry = "%s%s," % (indent, quoted)
    # Sorted insertion: before the first existing entry that sorts after `mod`.
    ins = end
    for j in range(start + 1, end):
        s = lines[j].strip()
        if s.startswith('"') and s.rstrip(",") > quoted:
            ins = j
            break
    lines.insert(ins, entry)
    end += 1
    added += 1

if added == 0:
    print("[tiro_module_outs] nothing to add (already declared)")
else:
    with open(BZL, "w") as f:
        f.write("\n".join(lines))
    print("[tiro_module_outs] added %d module(s) to _pineapple_in_tree_modules" % added)
