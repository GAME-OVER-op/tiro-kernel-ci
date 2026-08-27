from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description='Backport selected Qualcomm 6.6 Pineapple scheduler/UFS improvements to Nubia SM8650 Linux 6.1.')
parser.add_argument('kernel_root', help='Path to the freshly cloned android_kernel_nubia_sm8650 tree (msm-kernel in CI)')
args = parser.parse_args()
root = Path(args.kernel_root).resolve()
if not (root / 'kernel/sched/walt/walt.c').is_file():
    raise SystemExit(f'ERROR: not a Nubia SM8650 kernel tree: {root}')

# Integration is intentionally anchor-based: if upstream lineage-23.2 changes around
# a backport site, CI fails loudly instead of silently applying a partial patch.
# Source reference: Qualcomm gki-clo Linux 6.6 WALT/UFS implementation, adapted
# to the Nubia android14-6.1 interfaces used by tiro/pineapple.

def rep(rel, old, new, count=1):
    p=root/rel
    s=p.read_text()
    if old not in s:
        raise SystemExit(f'anchor missing in {rel}: {old[:120]!r}')
    if s.count(old) < count:
        raise SystemExit(f'not enough anchors in {rel}')
    s=s.replace(old,new,count)
    p.write_text(s)

# Makefile: add storage LB object
rep('kernel/sched/walt/Makefile',
    'sched-walt-$(CONFIG_SCHED_WALT) := walt.o boost.o sched_avg.o walt_halt.o core_ctl.o trace.o input-boost.o sysctl.o cpufreq_walt.o fixup.o walt_lb.o walt_rt.o walt_cfs.o walt_tp.o mvp_locking.o',
    'sched-walt-$(CONFIG_SCHED_WALT) := walt.o boost.o sched_avg.o walt_halt.o core_ctl.o trace.o input-boost.o sysctl.o cpufreq_walt.o fixup.o walt_lb.o walt_rt.o walt_cfs.o walt_tp.o mvp_locking.o walt_storage_lb.o')

# walt.h declarations and high IRQ logic
rep('kernel/sched/walt/walt.h',
    'extern cpumask_t asym_cap_sibling_cpus;\n',
    'extern cpumask_t asym_cap_sibling_cpus;\nextern cpumask_t storage_boost_cpus;\nextern cpumask_t walt_enforce_high_irq_cpu_mask;\nextern bool kurumi_storage_lb;\nextern bool kurumi_boost_to_next_cluster;\nextern bool kurumi_silver_rt_spread;\n')
rep('kernel/sched/walt/walt.h',
    'static inline int sched_cpu_high_irqload(int cpu)\n{\n\tstruct walt_rq *wrq = &per_cpu(walt_rq, cpu);\n\n\treturn wrq->high_irqload;\n}\n',
    'static inline int sched_cpu_high_irqload(int cpu)\n{\n\tstruct walt_rq *wrq = &per_cpu(walt_rq, cpu);\n\n\treturn wrq->high_irqload ||\n\t\tcpumask_test_cpu(cpu, &walt_enforce_high_irq_cpu_mask);\n}\n')
# add LB helper prototypes near end before endif marker-ish existing helper section
rep('kernel/sched/walt/walt.h',
    'extern void walt_lb_init(void);\n',
    'extern void walt_lb_init(void);\nextern unsigned long walt_lb_cpu_util(int cpu);\nextern int stop_walt_lb_active_migration(void *data);\nextern void walt_detach_task(struct task_struct *p, struct rq *src_rq, struct rq *dst_rq);\nextern void walt_attach_task(struct task_struct *p, struct rq *rq);\nextern bool move_storage_load(struct rq *rq);\n')

# walt.c globals/runtime params
rep('kernel/sched/walt/walt.c',
    'cpumask_t walt_cpus_taken_mask = { CPU_BITS_NONE };\nDEFINE_SPINLOCK(cpus_taken_lock);\nDEFINE_PER_CPU(int, cpus_taken_refcount);\n',
    'cpumask_t walt_cpus_taken_mask = { CPU_BITS_NONE };\nDEFINE_SPINLOCK(cpus_taken_lock);\nDEFINE_PER_CPU(int, cpus_taken_refcount);\n\ncpumask_t walt_enforce_high_irq_cpu_mask = { CPU_BITS_NONE };\nDEFINE_SPINLOCK(enforce_high_irq_cpu_lock);\nDEFINE_PER_CPU(int, enforce_high_irq_cpus_refcount);\ncpumask_t storage_boost_cpus = CPU_MASK_NONE;\n\nbool kurumi_storage_lb = true;\nbool kurumi_boost_to_next_cluster = true;\nbool kurumi_silver_rt_spread = true;\nmodule_param_named(kurumi_storage_lb, kurumi_storage_lb, bool, 0644);\nMODULE_PARM_DESC(kurumi_storage_lb, "Enable Pineapple WALT storage IRQ load balancing");\nmodule_param_named(kurumi_boost_to_next_cluster, kurumi_boost_to_next_cluster, bool, 0644);\nMODULE_PARM_DESC(kurumi_boost_to_next_cluster, "Enable Pineapple boost-to-next-cluster placement");\nmodule_param_named(kurumi_silver_rt_spread, kurumi_silver_rt_spread, bool, 0644);\nMODULE_PARM_DESC(kurumi_silver_rt_spread, "Enable Pineapple RT spreading across the efficiency cluster search range");\n')
# initialize storage mask after cpu arrays built
rep('kernel/sched/walt/walt.c',
    '\tinit_cpu_array();\n\tbuild_cpu_array();\n\tfind_cache_siblings();\n',
    '\tinit_cpu_array();\n\tbuild_cpu_array();\n\n\t/* Pineapple storage boost candidates: all CPUs except the minimum-capacity cluster. */\n\tcpumask_clear(&storage_boost_cpus);\n\tif (num_sched_clusters > 1)\n\t\tcpumask_andnot(&storage_boost_cpus, cpu_possible_mask,\n\t\t\t\t&sched_cluster[0]->cpus);\n\n\tfind_cache_siblings();\n')
# add high irq API after get_cpus_taken
rep('kernel/sched/walt/walt.c',
    'cpumask_t walt_get_cpus_taken(void)\n{\n\treturn walt_cpus_taken_mask;\n}\nEXPORT_SYMBOL_GPL(walt_get_cpus_taken);\n\nint walt_get_cpus_in_state1(struct cpumask *cpus)\n',
    'cpumask_t walt_get_cpus_taken(void)\n{\n\treturn walt_cpus_taken_mask;\n}\nEXPORT_SYMBOL_GPL(walt_get_cpus_taken);\n\nint walt_set_enforce_high_irq_cpus(struct cpumask *set)\n{\n\tunsigned long flags;\n\tint cpu;\n\n\tif (unlikely(walt_disabled))\n\t\treturn -EAGAIN;\n\n\tspin_lock_irqsave(&enforce_high_irq_cpu_lock, flags);\n\tfor_each_cpu(cpu, set)\n\t\tper_cpu(enforce_high_irq_cpus_refcount, cpu)++;\n\tcpumask_or(&walt_enforce_high_irq_cpu_mask,\n\t\t   &walt_enforce_high_irq_cpu_mask, set);\n\tspin_unlock_irqrestore(&enforce_high_irq_cpu_lock, flags);\n\n\treturn 0;\n}\nEXPORT_SYMBOL_GPL(walt_set_enforce_high_irq_cpus);\n\nint walt_unset_enforce_high_irq_cpus(struct cpumask *unset)\n{\n\tunsigned long flags;\n\tint cpu;\n\n\tif (unlikely(walt_disabled))\n\t\treturn -EAGAIN;\n\n\tspin_lock_irqsave(&enforce_high_irq_cpu_lock, flags);\n\tfor_each_cpu(cpu, unset) {\n\t\tif (per_cpu(enforce_high_irq_cpus_refcount, cpu) >= 1)\n\t\t\tper_cpu(enforce_high_irq_cpus_refcount, cpu)--;\n\t\tif (!per_cpu(enforce_high_irq_cpus_refcount, cpu))\n\t\t\tcpumask_clear_cpu(cpu, &walt_enforce_high_irq_cpu_mask);\n\t}\n\tspin_unlock_irqrestore(&enforce_high_irq_cpu_lock, flags);\n\n\treturn 0;\n}\nEXPORT_SYMBOL_GPL(walt_unset_enforce_high_irq_cpus);\n\ncpumask_t walt_get_enforce_high_irq_cpus(void)\n{\n\treturn walt_enforce_high_irq_cpu_mask;\n}\nEXPORT_SYMBOL_GPL(walt_get_enforce_high_irq_cpus);\n\nbool walt_storage_lb_enabled(void)\n{\n\treturn READ_ONCE(kurumi_storage_lb);\n}\nEXPORT_SYMBOL_GPL(walt_storage_lb_enabled);\n\nint walt_get_cpus_in_state1(struct cpumask *cpus)\n')

# include/linux public APIs and fallback stubs
rep('include/linux/sched/walt.h',
    'extern cpumask_t walt_get_cpus_taken(void);\nextern int walt_get_cpus_in_state1(struct cpumask *cpus);\n',
    'extern cpumask_t walt_get_cpus_taken(void);\nextern int walt_get_cpus_in_state1(struct cpumask *cpus);\nextern int walt_set_enforce_high_irq_cpus(struct cpumask *set);\nextern int walt_unset_enforce_high_irq_cpus(struct cpumask *unset);\nextern cpumask_t walt_get_enforce_high_irq_cpus(void);\nextern bool walt_storage_lb_enabled(void);\n')
rep('include/linux/sched/walt.h',
    'static inline cpumask_t walt_get_cpus_taken(void)\n{\n\tcpumask_t t = { CPU_BITS_NONE };\n\treturn t;\n}\n\nstatic inline int sched_set_boost(int type)\n',
    'static inline cpumask_t walt_get_cpus_taken(void)\n{\n\tcpumask_t t = { CPU_BITS_NONE };\n\treturn t;\n}\n\nstatic inline int walt_set_enforce_high_irq_cpus(struct cpumask *set)\n{\n\treturn -EINVAL;\n}\n\nstatic inline int walt_unset_enforce_high_irq_cpus(struct cpumask *unset)\n{\n\treturn -EINVAL;\n}\n\nstatic inline cpumask_t walt_get_enforce_high_irq_cpus(void)\n{\n\tcpumask_t t = { CPU_BITS_NONE };\n\treturn t;\n}\n\nstatic inline bool walt_storage_lb_enabled(void)\n{\n\treturn false;\n}\n\nstatic inline int sched_set_boost(int type)\n')

# walt_lb: make helpers visible within module and add storage balance path
rep('kernel/sched/walt/walt_lb.c', 'static inline unsigned long walt_lb_cpu_util(int cpu)\n', 'unsigned long walt_lb_cpu_util(int cpu)\n')
rep('kernel/sched/walt/walt_lb.c', 'static void walt_detach_task(struct task_struct *p, struct rq *src_rq,\n', 'void walt_detach_task(struct task_struct *p, struct rq *src_rq,\n')
rep('kernel/sched/walt/walt_lb.c', 'static void walt_attach_task(struct task_struct *p, struct rq *rq)\n', 'void walt_attach_task(struct task_struct *p, struct rq *rq)\n')
rep('kernel/sched/walt/walt_lb.c', 'static int stop_walt_lb_active_migration(void *data)\n', 'int stop_walt_lb_active_migration(void *data)\n')
rep('kernel/sched/walt/walt_lb.c',
    'void walt_lb_tick(struct rq *rq)\n{\n\tint prev_cpu = rq->cpu, new_cpu, ret;\n',
    'void walt_lb_tick(struct rq *rq)\n{\n\tint prev_cpu = rq->cpu, new_cpu, ret;\n\tbool storage_balance = false;\n')
rep('kernel/sched/walt/walt_lb.c',
    '\traw_spin_unlock(&rq->__lock);\n\n\tif (!walt_fair_task(p))\n',
    '\traw_spin_unlock(&rq->__lock);\n\n\tif (is_storage_boost() && READ_ONCE(kurumi_storage_lb)) {\n\t\tif (rq->cpu == 0) {\n\t\t\traw_spin_lock_irqsave(&walt_lb_migration_lock, flags);\n\t\t\tstorage_balance = move_storage_load(rq);\n\t\t\traw_spin_unlock_irqrestore(&walt_lb_migration_lock, flags);\n\t\t} else if (cpumask_test_cpu(rq->cpu,\n\t\t\t\t\t&walt_enforce_high_irq_cpu_mask)) {\n\t\t\treturn;\n\t\t}\n\t}\n\n\tif (!walt_fair_task(p))\n')
rep('kernel/sched/walt/walt_lb.c',
    '\tif (!rq->misfit_task_load)\n\t\treturn;\n',
    '\tif (!rq->misfit_task_load || storage_balance)\n\t\treturn;\n', 1)

# CFS runtime feature (preserves current 4-cluster default behavior)
rep('kernel/sched/walt/walt_cfs.c',
    '\t\t*energy_eval_needed = false;\n\t\t*order_index = 1;\n\t\t*end_index = max(0, num_sched_clusters - 3);\n\n\t\tif (sysctl_sched_asymcap_boost) {\n',
    '\t\t*energy_eval_needed = false;\n\t\t*order_index = 1;\n\t\t*end_index = 0;\n\t\tif (READ_ONCE(kurumi_boost_to_next_cluster))\n\t\t\t*end_index = min(1, num_sched_clusters - 1);\n\n\t\tif (sysctl_sched_asymcap_boost) {\n')

# RT runtime feature (preserves current Tiro behavior when enabled)
rep('kernel/sched/walt/walt_rt.c',
    '\tif (num_sched_clusters > 3 && order_index == 0)\n\t\tend_index = 1;\n',
    '\tif (READ_ONCE(kurumi_silver_rt_spread) &&\n\t\tnum_sched_clusters > 3 && order_index == 0)\n\t\tend_index = 1;\n')

# New storage LB source adapted from Qualcomm 6.6
(root/'kernel/sched/walt/walt_storage_lb.c').write_text(r'''// SPDX-License-Identifier: GPL-2.0-only
/*
 * Qualcomm Pineapple storage IRQ load balancing backport for Linux 6.1.
 * Based on the newer Qualcomm WALT implementation, adapted for the
 * android14-6.1 Nubia scheduler interfaces.
 */

#include "walt.h"
#include "trace.h"

static bool lb_ignore_cpus(int cpu, cpumask_t *dst_cpu_mask_to_avoid)
{
	if (!cpu_active(cpu))
		return true;

	if (cpu_halted(cpu))
		return true;

	if (sched_cpu_high_irqload(cpu))
		return true;

	if (is_reserved(cpu) || cpu_rq(cpu)->active_balance)
		return true;

	if (cpumask_test_cpu(cpu, dst_cpu_mask_to_avoid))
		return true;

	return false;
}

static int find_least_util_any_cpu(int src_cpu,
				   cpumask_t *dst_cpu_mask_to_avoid)
{
	int cpu, best_cpu = -1;
	unsigned long util, min_util = ULONG_MAX;

	for_each_cpu(cpu, &storage_boost_cpus) {
		if (cpu == src_cpu)
			continue;
		if (lb_ignore_cpus(cpu, dst_cpu_mask_to_avoid))
			continue;

		util = walt_lb_cpu_util(cpu);
		if (util < min_util) {
			best_cpu = cpu;
			min_util = util;
		}
	}

	return best_cpu;
}

static bool move_task(int src_cpu, int dst_cpu,
			      cpumask_t *dst_cpu_mask_to_avoid)
{
	struct rq *dst_rq = cpu_rq(dst_cpu);
	struct rq *src_rq = cpu_rq(src_cpu);
	struct walt_rq *src_wrq = &per_cpu(walt_rq, src_cpu);
	struct task_struct *p, *target_task = NULL;
	int ret, task_visited = 0;
	bool moved = false;
	unsigned long flags;
	unsigned long util, max_task_util = 0;

	raw_spin_lock_irqsave(&src_rq->__lock, flags);

	if (src_rq->active_balance) {
		raw_spin_unlock_irqrestore(&src_rq->__lock, flags);
		goto out;
	}

	list_for_each_entry_reverse(p, &src_rq->cfs_tasks, se.group_node) {
		if (!walt_fair_task(p))
			continue;
		if (!cpumask_test_cpu(dst_cpu, p->cpus_ptr))
			continue;

		task_visited++;
		util = task_util(p);
		if (util > max_task_util) {
			max_task_util = util;
			target_task = p;
		}
		if (task_visited > 10)
			break;
	}

	if (!target_task) {
		raw_spin_unlock_irqrestore(&src_rq->__lock, flags);
		goto out;
	}

	if (task_on_cpu(src_rq, target_task)) {
		get_task_struct(target_task);
		src_rq->active_balance = 1;
		src_rq->push_cpu = dst_cpu;
		src_wrq->push_task = target_task;
		mark_reserved(dst_cpu);
		raw_spin_unlock_irqrestore(&src_rq->__lock, flags);
		ret = stop_one_cpu_nowait(src_cpu,
				stop_walt_lb_active_migration,
				src_rq, &src_rq->active_balance_work);
		if (!ret) {
			clear_reserved(dst_cpu);
			goto out;
		}
		cpumask_set_cpu(dst_cpu, dst_cpu_mask_to_avoid);
		moved = true;
		wake_up_if_idle(dst_cpu);
	} else {
		cpumask_set_cpu(dst_cpu, dst_cpu_mask_to_avoid);
		walt_detach_task(target_task, src_rq, dst_rq);
		raw_spin_unlock_irqrestore(&src_rq->__lock, flags);
		raw_spin_lock_irqsave(&dst_rq->__lock, flags);
		walt_attach_task(target_task, dst_rq);
		raw_spin_unlock_irqrestore(&dst_rq->__lock, flags);
		moved = true;
	}

out:
	return moved;
}

static bool migrate_high_irq_cpus(cpumask_t *dst_cpu_mask_to_avoid)
{
	bool done = false;
	int cpu, dst_cpu;

	for_each_possible_cpu(cpu) {
		if (!cpumask_test_cpu(cpu, &walt_enforce_high_irq_cpu_mask))
			continue;
		if (is_reserved(cpu) || cpu_rq(cpu)->active_balance)
			continue;

		dst_cpu = find_least_util_any_cpu(cpu, dst_cpu_mask_to_avoid);
		if (dst_cpu >= 0)
			done |= move_task(cpu, dst_cpu, dst_cpu_mask_to_avoid);
	}

	return done;
}

#define STORAGE_BALANCE_INTERVAL_NSEC 3000000ULL
bool move_storage_load(struct rq *rq)
{
	bool ret = false;
	cpumask_t dst_cpu_mask_to_avoid = CPU_MASK_NONE;
	static u64 next_balance_time_nsec;

	if (!READ_ONCE(kurumi_storage_lb))
		return false;

	if (rq->clock < next_balance_time_nsec)
		return false;

	next_balance_time_nsec = rq->clock + STORAGE_BALANCE_INTERVAL_NSEC;
	ret = migrate_high_irq_cpus(&dst_cpu_mask_to_avoid);

	return ret;
}
''')

# UFS host fields
rep('drivers/ufs/host/ufs-qcom.h',
    '\tcpumask_t perf_mask;\n\tcpumask_t def_mask;\n\tcpumask_t cluster_mask[MAX_NUM_CLUSTERS];\n',
    '\tcpumask_t perf_mask;\n\tcpumask_t def_mask;\n\tcpumask_t esi_mask;\n\tcpumask_t cluster_mask[MAX_NUM_CLUSTERS];\n')
rep('drivers/ufs/host/ufs-qcom.h',
    '\tbool irq_affinity_support;\n\tbool esi_enabled;\n\n\tbool bypass_pbl_rst_wa;\n',
    '\tbool irq_affinity_support;\n\tbool esi_enabled;\n\n\tunsigned int boost_monitor_timer;\n\tu32 min_boost_thres;\n\tu32 max_boost_thres;\n\n\tbool bypass_pbl_rst_wa;\n')

# UFS ESI mask tracking
rep('drivers/ufs/host/ufs-qcom.c',
    '\tufs_qcom_msi_lock_descs(hba);\n\tmsi_for_each_desc(desc, hba->dev, MSI_DESC_ALL) {\n',
    '\tcpumask_clear(&host->esi_mask);\n\tufs_qcom_msi_lock_descs(hba);\n\tmsi_for_each_desc(desc, hba->dev, MSI_DESC_ALL) {\n')
rep('drivers/ufs/host/ufs-qcom.c',
    '\t\tmask = &affinity_mask;\n\t\tirq_modify_status(desc->irq, clear, set);\n',
    '\t\tmask = &affinity_mask;\n\t\tcpumask_or(&host->esi_mask, &host->esi_mask, mask);\n\t\tirq_modify_status(desc->irq, clear, set);\n')
# UFS storage high IRQ integration
rep('drivers/ufs/host/ufs-qcom.c',
    '#if IS_ENABLED(CONFIG_SCHED_WALT)\n\tif (on)\n\t\tsched_set_boost(STORAGE_BOOST);\n\telse\n\t\tsched_set_boost(STORAGE_BOOST_DISABLE);\n#endif\n',
    '#if IS_ENABLED(CONFIG_SCHED_WALT)\n\tif (on) {\n\t\tif (walt_storage_lb_enabled() && !cpumask_empty(&host->esi_mask))\n\t\t\twalt_set_enforce_high_irq_cpus(&host->esi_mask);\n\t\tsched_set_boost(STORAGE_BOOST);\n\t} else {\n\t\t/* Always drop a previously enforced mask, even if the runtime knob changed. */\n\t\tif (!cpumask_empty(&host->esi_mask))\n\t\t\twalt_unset_enforce_high_irq_cpus(&host->esi_mask);\n\t\tsched_set_boost(STORAGE_BOOST_DISABLE);\n\t}\n#endif\n')
# Runtime threshold use
rep('drivers/ufs/host/ufs-qcom.c', 'if (cur_thres > NUM_REQS_HIGH_THRESH && !host->cur_freq_vote) {', 'if (cur_thres > host->max_boost_thres && !host->cur_freq_vote) {')
rep('drivers/ufs/host/ufs-qcom.c', '} else if (cur_thres < NUM_REQS_LOW_THRESH && host->cur_freq_vote) {', '} else if (cur_thres < host->min_boost_thres && host->cur_freq_vote) {')
rep('drivers/ufs/host/ufs-qcom.c', 'msecs_to_jiffies(UFS_QCOM_LOAD_MON_DLY_MS));', 'msecs_to_jiffies(host->boost_monitor_timer));', 1)
# There is a second queue in clk_scale_notify
rep('drivers/ufs/host/ufs-qcom.c',
    'msecs_to_jiffies(\n\t\t\t\t\t\tUFS_QCOM_LOAD_MON_DLY_MS));',
    'msecs_to_jiffies(\n\t\t\t\t\t\thost->boost_monitor_timer));')
# init function before thermal get max, using old location after parse irq affinity
rep('drivers/ufs/host/ufs-qcom.c',
    '/* Returns the max mitigation level supported */\nstatic int ufs_qcom_get_max_therm_state',
    'static void ufs_qcom_storage_boost_param_init(struct ufs_hba *hba)\n{\n\tstruct ufs_qcom_host *host = ufshcd_get_variant(hba);\n\n\thost->boost_monitor_timer = UFS_QCOM_LOAD_MON_DLY_MS;\n\thost->min_boost_thres = NUM_REQS_LOW_THRESH;\n\thost->max_boost_thres = NUM_REQS_HIGH_THRESH;\n}\n\n/* Returns the max mitigation level supported */\nstatic int ufs_qcom_get_max_therm_state')
# call init before sysfs
rep('drivers/ufs/host/ufs-qcom.c',
    '\tufs_qcom_init_sysfs(hba);\n',
    '\tufs_qcom_storage_boost_param_init(hba);\n\tufs_qcom_init_sysfs(hba);\n', 1)
# Sysfs attributes: insert before ufs_pm_mode_show
ufs_attrs = r'''static ssize_t boost_min_threshold_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t count)
{
	struct ufs_hba *hba = dev_get_drvdata(dev);
	struct ufs_qcom_host *host = ufshcd_get_variant(hba);
	u32 val;

	if (!capable(CAP_SYS_ADMIN))
		return -EACCES;
	if (kstrtouint(buf, 0, &val))
		return -EINVAL;
	if (val >= host->max_boost_thres)
		return -EINVAL;

	host->min_boost_thres = val;
	return count;
}

static ssize_t boost_min_threshold_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct ufs_hba *hba = dev_get_drvdata(dev);
	struct ufs_qcom_host *host = ufshcd_get_variant(hba);

	return scnprintf(buf, PAGE_SIZE, "%u\n", host->min_boost_thres);
}
static DEVICE_ATTR_RW(boost_min_threshold);

static ssize_t boost_max_threshold_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t count)
{
	struct ufs_hba *hba = dev_get_drvdata(dev);
	struct ufs_qcom_host *host = ufshcd_get_variant(hba);
	u32 val;

	if (!capable(CAP_SYS_ADMIN))
		return -EACCES;
	if (kstrtouint(buf, 0, &val))
		return -EINVAL;
	if (val <= host->min_boost_thres)
		return -EINVAL;

	host->max_boost_thres = val;
	return count;
}

static ssize_t boost_max_threshold_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct ufs_hba *hba = dev_get_drvdata(dev);
	struct ufs_qcom_host *host = ufshcd_get_variant(hba);

	return scnprintf(buf, PAGE_SIZE, "%u\n", host->max_boost_thres);
}
static DEVICE_ATTR_RW(boost_max_threshold);

static ssize_t boost_monitor_timer_ms_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t count)
{
	struct ufs_hba *hba = dev_get_drvdata(dev);
	struct ufs_qcom_host *host = ufshcd_get_variant(hba);
	u32 val;

	if (!capable(CAP_SYS_ADMIN))
		return -EACCES;
	if (kstrtouint(buf, 0, &val))
		return -EINVAL;
	/* Avoid a zero-delay workqueue loop and unreasonable test values. */
	if (val < 5 || val > 1000)
		return -ERANGE;

	host->boost_monitor_timer = val;
	return count;
}

static ssize_t boost_monitor_timer_ms_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct ufs_hba *hba = dev_get_drvdata(dev);
	struct ufs_qcom_host *host = ufshcd_get_variant(hba);

	return scnprintf(buf, PAGE_SIZE, "%u\n", host->boost_monitor_timer);
}
static DEVICE_ATTR_RW(boost_monitor_timer_ms);

'''
rep('drivers/ufs/host/ufs-qcom.c',
    'static ssize_t ufs_pm_mode_show(struct device *dev,\n',
    ufs_attrs + 'static ssize_t ufs_pm_mode_show(struct device *dev,\n')
# add attrs to group
rep('drivers/ufs/host/ufs-qcom.c',
    '\t&dev_attr_irq_affinity_support.attr,\n\t&dev_attr_ufs_pm_mode.attr,\n',
    '\t&dev_attr_irq_affinity_support.attr,\n\t&dev_attr_boost_min_threshold.attr,\n\t&dev_attr_boost_max_threshold.attr,\n\t&dev_attr_boost_monitor_timer_ms.attr,\n\t&dev_attr_ufs_pm_mode.attr,\n')

print('patched')
