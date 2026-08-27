#!/usr/bin/env python3
from pathlib import Path
import argparse

p = argparse.ArgumentParser(description='Verify Kurumi Tiro 1-7 source backports in a Nubia SM8650 kernel tree.')
p.add_argument('kernel_root')
args = p.parse_args()
root = Path(args.kernel_root).resolve()

checks = {
    'kernel/sched/walt/Makefile': [
        'walt_storage_lb.o',
    ],
    'kernel/sched/walt/walt_storage_lb.c': [
        'move_storage_load',
        'walt_enforce_high_irq_cpu_mask',
        'storage_boost_cpus',
    ],
    'kernel/sched/walt/walt.c': [
        'kurumi_storage_lb',
        'kurumi_boost_to_next_cluster',
        'kurumi_silver_rt_spread',
        'walt_set_enforce_high_irq_cpus',
        'walt_storage_lb_enabled',
    ],
    'kernel/sched/walt/walt_cfs.c': [
        'READ_ONCE(kurumi_boost_to_next_cluster)',
    ],
    'kernel/sched/walt/walt_rt.c': [
        'READ_ONCE(kurumi_silver_rt_spread)',
    ],
    'drivers/ufs/host/ufs-qcom.h': [
        'cpumask_t esi_mask;',
        'boost_monitor_timer',
        'min_boost_thres',
        'max_boost_thres',
    ],
    'drivers/ufs/host/ufs-qcom.c': [
        'walt_set_enforce_high_irq_cpus',
        'walt_unset_enforce_high_irq_cpus',
        'boost_min_threshold',
        'boost_max_threshold',
        'boost_monitor_timer_ms',
    ],
    'include/linux/sched/walt.h': [
        'walt_set_enforce_high_irq_cpus',
        'walt_unset_enforce_high_irq_cpus',
        'walt_storage_lb_enabled',
    ],
}

errors = []
for rel, needles in checks.items():
    f = root / rel
    if not f.is_file():
        errors.append(f'missing {rel}')
        continue
    text = f.read_text(errors='replace')
    for n in needles:
        if n not in text:
            errors.append(f'{rel}: missing marker {n!r}')

if errors:
    print('ERROR: Tiro optimization backport verification failed:')
    for e in errors:
        print(' -', e)
    raise SystemExit(1)

print('OK: Tiro optimization source backports verified:')
print('  4. WALT storage IRQ load balancing')
print('  5. Runtime UFS boost thresholds/timer')
print('  6. Pineapple boost-to-next-cluster runtime switch')
print('  7. Pineapple Silver RT spread runtime switch')
