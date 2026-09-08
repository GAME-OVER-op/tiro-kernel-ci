#!/usr/bin/env python3
"""Integrate Kurumi kernel-native performance guards for Tiro/SM8650.

Usage:
  kurumi_integrate_performance_guard.py <kernel_tree> [device_tree_root]

The guard intentionally keeps the thermal framework, sensors, critical trips,
battery/BCL/PMIC/UFS/DDR/modem protections and hardware LMH intact. Only
CPU/GPU/display performance cooling requests are clamped to state 0.

It also keeps the *base sysfs* scaling_min_freq request at the real hardware OPP
minimum. Internal freq_qos clients (WALT input boost, scheduler boost, etc.) use
separate requests and are therefore unaffected.

Finally, it fixes the Tiro ramoops layout. Full DT builds get explicit regions,
and the kernel has a fallback for stock/existing vendor_boot DTBs whose 2 MiB
ramoops area is entirely assigned to pmsg.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MARK_THERMAL = "KURUMI_PERFORMANCE_THERMAL_GUARD"
MARK_CPUFREQ = "KURUMI_CPU_BASE_MIN_GUARD"
MARK_RAMOOPS = "KURUMI_RAMOOPS_LAYOUT_GUARD"


def fail(msg: str) -> None:
    raise SystemExit(f"ERROR: {msg}")


def patch_thermal(kernel: Path) -> None:
    helpers = kernel / "drivers/thermal/thermal_helpers.c"
    sysfs = kernel / "drivers/thermal/thermal_sysfs.c"
    core_h = kernel / "drivers/thermal/thermal_core.h"
    for p in (helpers, sysfs, core_h):
        if not p.is_file():
            fail(f"missing thermal source: {p}")

    # Shared declaration for thermal_helpers.c -> thermal_sysfs.c.
    h = core_h.read_text()
    decl = "bool kurumi_thermal_performance_cdev(const struct thermal_cooling_device *cdev);\n"
    if decl not in h:
        anchor = "void __thermal_cdev_update(struct thermal_cooling_device *cdev);\n"
        if anchor not in h:
            fail(f"{core_h}: thermal cdev declaration anchor missing")
        h = h.replace(
            anchor,
            anchor
            + "\n/* KURUMI_PERFORMANCE_THERMAL_GUARD: device-type policy helper. */\n"
            + decl,
            1,
        )
        core_h.write_text(h)

    hs = helpers.read_text()
    if MARK_THERMAL not in hs:
        # Android 14 6.1 uses a static thermal_cdev_set_cur_state() helper.
        # Match it independent of whitespace/minor stable branch edits.
        fn = re.search(
            r"(?m)^static\s+(?:void|int)\s+thermal_cdev_set_cur_state\s*\("
            r"struct thermal_cooling_device \*cdev,\s*(?:int|unsigned long)\s+\w+\)\s*\{",
            hs,
        )
        if not fn:
            fail(f"{helpers}: thermal_cdev_set_cur_state function anchor missing")

        block = '''/*
 * KURUMI_PERFORMANCE_THERMAL_GUARD
 *
 * Keep thermal sensing and emergency/critical protection alive, but refuse
 * software cooling states that reduce interactive CPU/GPU/display performance.
 * Do not key this policy to cooling_device IDs: IDs are registration-order ABI
 * and change across vendor revisions. Match stable cooling-device type names.
 */
bool kurumi_thermal_performance_cdev(const struct thermal_cooling_device *cdev)
{
\tconst char *type = cdev->type;

\tif (!type)
\t\treturn false;

\tif (!strncmp(type, "cpufreq-", sizeof("cpufreq-") - 1) ||
\t    !strncmp(type, "thermal-cpufreq-", sizeof("thermal-cpufreq-") - 1) ||
\t    !strncmp(type, "cpu-hotplug", sizeof("cpu-hotplug") - 1) ||
\t    !strncmp(type, "cpu-isolate", sizeof("cpu-isolate") - 1) ||
\t    !strncmp(type, "pause-cpu", sizeof("pause-cpu") - 1) ||
\t    !strncmp(type, "thermal-pause-", sizeof("thermal-pause-") - 1) ||
\t    !strncmp(type, "cpu-cluster", sizeof("cpu-cluster") - 1) ||
\t    !strncmp(type, "thermal-cluster-", sizeof("thermal-cluster-") - 1))
\t\treturn true;

\tif (!strcmp(type, "gpu") || !strcmp(type, "display-fps"))
\t\treturn true;

\t/* Do not block unrelated devfreq users such as DDR/UFS. */
\tif ((!strncmp(type, "devfreq-", sizeof("devfreq-") - 1) ||
\t     !strncmp(type, "thermal-devfreq-", sizeof("thermal-devfreq-") - 1)) &&
\t    strstr(type, "kgsl"))
\t\treturn true;

\treturn false;
}

'''
        hs = hs[: fn.start()] + block + hs[fn.start() :]

        # Clamp inside the helper before its driver's set_cur_state() call. We
        # intentionally do this in the common thermal path so governors cannot
        # bypass it. The sysfs path is patched separately below.
        fn_start = hs.find("thermal_cdev_set_cur_state", fn.start() + len(block))
        brace = hs.find("{", fn_start)
        next_fn = hs.find("\n}\n", brace)
        if fn_start < 0 or brace < 0 or next_fn < 0:
            fail(f"{helpers}: could not delimit thermal_cdev_set_cur_state")
        body = hs[brace + 1 : next_fn]
        call = re.search(
            r"(?m)^(?P<indent>[ \t]*)(?P<prefix>(?:ret\s*=\s*)?(?:if\s*\()?)(?:cdev->ops->set_cur_state)"
            r"\(cdev,\s*(?P<arg>[A-Za-z_][A-Za-z0-9_]*)\)",
            body,
        )
        if not call:
            fail(f"{helpers}: thermal governor set_cur_state call missing")
        arg = call.group("arg")
        insert_at = brace + 1 + call.start()
        indent = call.group("indent")
        guard = (
            f"{indent}if (kurumi_thermal_performance_cdev(cdev))\n"
            f"{indent}\t{arg} = 0;\n\n"
        )
        hs = hs[:insert_at] + guard + hs[insert_at:]
        helpers.write_text(hs)

    ss = sysfs.read_text()
    if MARK_THERMAL not in ss:
        # Insert after max-state validation and before lock/driver write. The
        # exact number of blank lines changes between Android 14 stable tags.
        pat = re.compile(
            r"(?P<check>^[ \t]*/\* Requested state should be less than max_state \+ 1 \*/\n"
            r"^[ \t]*if \(state > cdev->max_state\)\n^[ \t]*return -EINVAL;\n)",
            re.M,
        )
        m = pat.search(ss)
        if not m:
            fail(f"{sysfs}: cur_state_store max-state anchor missing")
        replacement = (
            m.group("check")
            + "\n\t/* KURUMI_PERFORMANCE_THERMAL_GUARD: accept HAL writes, apply state 0. */\n"
            + "\tif (kurumi_thermal_performance_cdev(cdev))\n"
            + "\t\tstate = 0;\n"
        )
        ss = ss[:m.start()] + replacement + ss[m.end():]
        sysfs.write_text(ss)


def patch_cpufreq(kernel: Path) -> None:
    p = kernel / "drivers/cpufreq/cpufreq.c"
    if not p.is_file():
        fail(f"missing cpufreq source: {p}")
    s = p.read_text()
    if MARK_CPUFREQ in s:
        return

    old = "store_one(scaling_min_freq, min);\nstore_one(scaling_max_freq, max);\n"
    if old not in s:
        fail(f"{p}: scaling_min/max store anchor missing")

    # Android 14 6.1 exists in two QoS layouts across stable history/vendor
    # trees: older trees allocate min_freq_req/max_freq_req and store pointers;
    # newer trees embed struct freq_qos_request in cpufreq_policy and pass its
    # address. Mirror the tree's own store_one() macro instead of guessing.
    if re.search(r"freq_qos_update_request\(\s*&policy->object##_freq_req", s):
        req_expr = "&policy->min_freq_req"
    elif re.search(r"freq_qos_update_request\(\s*policy->object##_freq_req", s):
        req_expr = "policy->min_freq_req"
    else:
        fail(f"{p}: unsupported scaling_min_freq QoS layout (store_one is not freq_qos based)")

    new = f'''/*
 * KURUMI_CPU_BASE_MIN_GUARD
 *
 * Qualcomm post-boot userspace raises scaling_min_freq above the first OPP and
 * leaves that base sysfs QoS request elevated. Keep this particular request at
 * the hardware minimum. Scheduler/WALT/input/perf clients use independent
 * freq_qos_request objects, so their short boosts still raise the effective
 * policy minimum normally.
 */
static ssize_t store_scaling_min_freq(struct cpufreq_policy *policy,
\t\t\t\t      const char *buf, size_t count)
{{
\tunsigned long requested;
\tint ret;

\t/* Keep the exact sysfs parsing semantics used by the stock cpufreq path. */
\tret = sscanf(buf, "%lu", &requested);
\tif (ret != 1)
\t\treturn -EINVAL;
\t(void)requested;

\tret = freq_qos_update_request({req_expr},
\t\t\t\t      policy->cpuinfo.min_freq);
\treturn ret >= 0 ? count : ret;
}}
store_one(scaling_max_freq, max);
'''
    p.write_text(s.replace(old, new, 1))


def patch_ramoops_kernel(kernel: Path) -> None:
    p = kernel / "fs/pstore/ram.c"
    if not p.is_file():
        fail(f"missing ramoops source: {p}")
    s = p.read_text()
    if MARK_RAMOOPS in s:
        return

    # Place the fallback immediately after the NULL pdata check. Monthly AOSP
    # stable revisions differ on whether they redundantly assign err=-EINVAL.
    pat = re.compile(
        r"(?P<block>^[ \t]*/\* Make sure we didn't get bogus platform data pointer\. \*/\n"
        r"^[ \t]*if \(!pdata\) \{\n"
        r"^[ \t]*pr_err\(\"NULL platform data\\n\"\);\n"
        r"(?:^[ \t]*err = -EINVAL;\n)?"
        r"^[ \t]*goto fail_out;\n"
        r"^[ \t]*\}\n)",
        re.M,
    )
    m = pat.search(s)
    if not m:
        fail(f"{p}: ramoops platform-data anchor missing")

    block = '''

\t/*
\t * KURUMI_RAMOOPS_LAYOUT_GUARD
\t * Tiro stock DT reserves 2 MiB for ramoops but assigns all 2 MiB to
\t * pmsg, leaving no dmesg/console region for kernel panic evidence.
\t * Repartition only that exact legacy layout. A corrected DT bypasses
\t * this fallback naturally.
\t */
\tif (pdata->mem_size == 0x200000 &&
\t    pdata->pmsg_size == pdata->mem_size &&
\t    !pdata->record_size && !pdata->console_size &&
\t    !pdata->ftrace_size) {
\t\tpdata->record_size = 0x100000; /* 1 MiB panic/oops dmesg */
\t\tpdata->console_size = 0x080000; /* 512 KiB persistent console */
\t\tpdata->pmsg_size = 0x080000; /* 512 KiB userspace breadcrumbs */
\t\tpr_info("Kurumi: repartitioned Tiro ramoops 2MiB: dmesg=1MiB console=512KiB pmsg=512KiB\\n");
\t}
'''
    s = s[:m.end()] + block + s[m.end():]
    p.write_text(s)


def find_matching_brace(text: str, start: int) -> int:
    depth = 0
    in_string = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def patch_ramoops_dt(dts_root: Path) -> tuple[int, bool]:
    if not dts_root.is_dir():
        fail(f"device-tree root not found: {dts_root}")

    # Rewrite only the exact Tiro/Pineapple legacy layout observed both in the
    # public lineage-23.2 source and on-device: a 2 MiB ramoops allocation
    # whose entire region is assigned to pmsg. Never touch unrelated nodes.
    size_2m = re.compile(
        r"(?m)^\s*size\s*=\s*<\s*(?:0x0|0)\s+0x200000\s*>\s*;\s*$"
    )
    pmsg_2m = re.compile(
        r"(?m)^\s*pmsg-size\s*=\s*<\s*0x200000\s*>\s*;\s*$"
    )
    record_prop = re.compile(r"(?m)^\s*record-size\s*=")
    console_prop = re.compile(r"(?m)^\s*console-size\s*=")

    def is_legacy_tiro(node: str) -> bool:
        return bool(
            size_2m.search(node)
            and pmsg_2m.search(node)
            and not record_prop.search(node)
            and not console_prop.search(node)
        )

    def is_corrected_tiro(node: str) -> bool:
        return bool(
            size_2m.search(node)
            and re.search(r"(?m)^\s*record-size\s*=\s*<\s*0x100000\s*>\s*;\s*$", node)
            and re.search(r"(?m)^\s*console-size\s*=\s*<\s*0x80000\s*>\s*;\s*$", node)
            and re.search(r"(?m)^\s*pmsg-size\s*=\s*<\s*0x80000\s*>\s*;\s*$", node)
        )

    patched = 0
    found_target = False
    all_dts = sorted(list(dts_root.rglob("*.dts")) + list(dts_root.rglob("*.dtsi")))
    for p in all_dts:
        try:
            s = p.read_text()
        except UnicodeDecodeError:
            continue
        if 'compatible = "ramoops"' not in s:
            continue

        pos = 0
        out = s
        changed_file = False
        while True:
            comp = out.find('compatible = "ramoops"', pos)
            if comp < 0:
                break
            start = out.rfind("{", 0, comp)
            if start < 0:
                fail(f"{p}: could not locate ramoops node opening brace")
            end = find_matching_brace(out, start)
            if end < 0:
                fail(f"{p}: could not locate ramoops node closing brace")
            node = out[start + 1:end]

            if is_corrected_tiro(node):
                found_target = True
                pos = end + 1
                continue
            if not is_legacy_tiro(node):
                pos = end + 1
                continue

            found_target = True
            indent_match = re.search(r"\n([ \t]*)pmsg-size\s*=", node)
            if indent_match:
                indent = indent_match.group(1)
            else:
                prop_indent = re.search(r"\n([ \t]+)[A-Za-z0-9,_-]+\s*=", node)
                indent = prop_indent.group(1) if prop_indent else "\t\t"

            def set_prop(b: str, name: str, value: str) -> str:
                prop = re.compile(rf"(?m)^([ \t]*){re.escape(name)}\s*=\s*<[^;]+>;[ \t]*$")
                repl = rf"\1{name} = <{value}>;"
                if prop.search(b):
                    return prop.sub(repl, b, count=1)
                pmsg = re.search(r"(?m)^[ \t]*pmsg-size\s*=", b)
                line = f"{indent}{name} = <{value}>;\n"
                if pmsg:
                    return b[:pmsg.start()] + line + b[pmsg.start():]
                return b.rstrip() + "\n" + line

            new_node = node
            new_node = set_prop(new_node, "record-size", "0x100000")
            new_node = set_prop(new_node, "console-size", "0x80000")
            new_node = set_prop(new_node, "pmsg-size", "0x80000")
            out = out[:start + 1] + new_node + out[end:]
            changed_file = True
            pos = start + 1 + len(new_node)

        if changed_file:
            p.write_text(out)
            patched += 1

    if not found_target:
        print(
            f"WARN: {dts_root}: exact Tiro 2MiB ramoops source node not present; "
            "leaving DT untouched and keeping the kernel fallback for stock/vendor_boot DT"
        )
    return patched, found_target


def verify(kernel: Path, dts_root: Path | None, expect_ramoops_dt: bool = False) -> None:
    checks = {
        kernel / "drivers/thermal/thermal_helpers.c": [
            MARK_THERMAL, '"display-fps"', 'strstr(type, "kgsl")',
            "kurumi_thermal_performance_cdev(cdev)",
        ],
        kernel / "drivers/thermal/thermal_sysfs.c": [
            MARK_THERMAL, "kurumi_thermal_performance_cdev(cdev)",
        ],
        kernel / "drivers/thermal/thermal_core.h": ["kurumi_thermal_performance_cdev"],
        kernel / "drivers/cpufreq/cpufreq.c": [MARK_CPUFREQ, "policy->cpuinfo.min_freq"],
        kernel / "fs/pstore/ram.c": [MARK_RAMOOPS, "pdata->record_size = 0x100000"],
    }
    for p, needles in checks.items():
        text = p.read_text()
        for needle in needles:
            if needle not in text:
                fail(f"verification failed: {needle!r} missing from {p}")

    if dts_root is not None and expect_ramoops_dt:
        hits = 0
        for p in list(dts_root.rglob("*.dts")) + list(dts_root.rglob("*.dtsi")):
            try:
                text = p.read_text()
            except UnicodeDecodeError:
                continue
            if 'compatible = "ramoops"' not in text:
                continue
            if (re.search(r"size\s*=\s*<\s*(?:0x0|0)\s+0x200000\s*>", text) and
                "record-size = <0x100000>;" in text and
                "console-size = <0x80000>;" in text and
                "pmsg-size = <0x80000>;" in text):
                hits += 1
        if not hits:
            fail("verification failed: corrected Tiro 2MiB ramoops DT properties not found")


def main() -> None:
    if len(sys.argv) not in (2, 3):
        fail("usage: kurumi_integrate_performance_guard.py <kernel_tree> [device_tree_root]")
    kernel = Path(sys.argv[1]).resolve()
    dts_root = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else None
    if not kernel.is_dir():
        fail(f"kernel tree not found: {kernel}")

    patch_thermal(kernel)
    patch_cpufreq(kernel)
    patch_ramoops_kernel(kernel)
    if dts_root is not None:
        dt_count, dt_found = patch_ramoops_dt(dts_root)
    else:
        dt_count, dt_found = 0, False
    verify(kernel, dts_root, expect_ramoops_dt=dt_found)

    print(f"OK: Kurumi kernel performance guard integrated into {kernel}")
    print("  thermal: CPU/GPU/display-fps cooling requests -> effective state 0")
    print("  cpufreq: scaling_min_freq sysfs base request -> hardware minimum")
    print("  ramoops: 1MiB dmesg + 512KiB console + 512KiB pmsg fallback")
    if dts_root is not None:
        if dt_found:
            print(f"  device tree: corrected/verified Tiro ramoops layout ({dt_count} source file(s) changed this run)")
        else:
            print("  device tree: exact legacy ramoops source node absent; kernel fallback remains active")


if __name__ == "__main__":
    main()
