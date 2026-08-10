// SPDX-License-Identifier: GPL-2.0
/*
 * Kurumi screen state helper.
 *
 * A tiny read-only sysfs bridge for the userspace Kurumi daemon.  It keeps
 * Android/framework polling out of the daemon hot path: userspace reads one
 * cheap kernel sysfs state instead of calling dumpsys/cmd/service-call.
 *
 * Exposes:
 *   /sys/kernel/kurumi_screen/state    -> on/off/unknown
 *   /sys/kernel/kurumi_screen/seq      -> increments on every state change
 *   /sys/kernel/kurumi_screen/since_ms -> milliseconds since last change
 *   /sys/kernel/kurumi_screen/poll_ms  -> recommended daemon poll interval
 */

#include <linux/atomic.h>
#include <linux/backlight.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>

#include <linux/kurumi_screen_state.h>

#define KURUMI_SCREEN_ON_POLL_MS  60000ULL
#define KURUMI_SCREEN_OFF_POLL_MS 30000ULL

enum kurumi_screen_state {
	KURUMI_SCREEN_UNKNOWN = 0,
	KURUMI_SCREEN_OFF,
	KURUMI_SCREEN_ON,
};

static struct kobject *kurumi_screen_kobj;
static DEFINE_SPINLOCK(kurumi_screen_lock);
static enum kurumi_screen_state kurumi_state = KURUMI_SCREEN_UNKNOWN;
static u64 kurumi_last_change_ms;
static atomic64_t kurumi_seq = ATOMIC64_INIT(0);

static u64 kurumi_now_ms(void)
{
	return ktime_to_ms(ktime_get_boottime());
}

static const char *kurumi_state_name(enum kurumi_screen_state state)
{
	switch (state) {
	case KURUMI_SCREEN_ON:
		return "on";
	case KURUMI_SCREEN_OFF:
		return "off";
	case KURUMI_SCREEN_UNKNOWN:
	default:
		return "unknown";
	}
}

static u64 kurumi_poll_ms_for_state(enum kurumi_screen_state state)
{
	return state == KURUMI_SCREEN_OFF ?
		KURUMI_SCREEN_OFF_POLL_MS : KURUMI_SCREEN_ON_POLL_MS;
}

static void kurumi_screen_set_state(enum kurumi_screen_state new_state)
{
	unsigned long flags;
	bool changed = false;

	spin_lock_irqsave(&kurumi_screen_lock, flags);
	if (kurumi_state != new_state) {
		kurumi_state = new_state;
		kurumi_last_change_ms = kurumi_now_ms();
		atomic64_inc(&kurumi_seq);
		changed = true;
	}
	spin_unlock_irqrestore(&kurumi_screen_lock, flags);

	if (changed && kurumi_screen_kobj) {
		sysfs_notify(kurumi_screen_kobj, NULL, "state");
		sysfs_notify(kurumi_screen_kobj, NULL, "seq");
		sysfs_notify(kurumi_screen_kobj, NULL, "since_ms");
		sysfs_notify(kurumi_screen_kobj, NULL, "poll_ms");
	}
}

void kurumi_screen_state_from_backlight(const struct backlight_device *bd)
{
	enum kurumi_screen_state next = KURUMI_SCREEN_UNKNOWN;
	int brightness;

	if (!bd)
		return;

	brightness = backlight_get_brightness(bd);
	if (brightness > 0 && !backlight_is_blank(bd))
		next = KURUMI_SCREEN_ON;
	else
		next = KURUMI_SCREEN_OFF;

	kurumi_screen_set_state(next);
}

static enum kurumi_screen_state kurumi_get_state_snapshot(u64 *last_change_ms)
{
	unsigned long flags;
	enum kurumi_screen_state state;

	spin_lock_irqsave(&kurumi_screen_lock, flags);
	state = kurumi_state;
	if (last_change_ms)
		*last_change_ms = kurumi_last_change_ms;
	spin_unlock_irqrestore(&kurumi_screen_lock, flags);

	return state;
}

static ssize_t state_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s\n", kurumi_state_name(kurumi_get_state_snapshot(NULL)));
}

static ssize_t seq_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%lld\n", atomic64_read(&kurumi_seq));
}

static ssize_t since_ms_show(struct kobject *kobj,
			      struct kobj_attribute *attr, char *buf)
{
	u64 last_change_ms = 0;
	u64 now_ms = kurumi_now_ms();

	kurumi_get_state_snapshot(&last_change_ms);
	return sysfs_emit(buf, "%llu\n", now_ms >= last_change_ms ?
			  now_ms - last_change_ms : 0ULL);
}

static ssize_t poll_ms_show(struct kobject *kobj,
			     struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%llu\n",
			  kurumi_poll_ms_for_state(kurumi_get_state_snapshot(NULL)));
}

static struct kobj_attribute state_attr = __ATTR_RO(state);
static struct kobj_attribute seq_attr = __ATTR_RO(seq);
static struct kobj_attribute since_ms_attr = __ATTR_RO(since_ms);
static struct kobj_attribute poll_ms_attr = __ATTR_RO(poll_ms);

static struct attribute *kurumi_screen_attrs[] = {
	&state_attr.attr,
	&seq_attr.attr,
	&since_ms_attr.attr,
	&poll_ms_attr.attr,
	NULL,
};

static const struct attribute_group kurumi_screen_attr_group = {
	.attrs = kurumi_screen_attrs,
};

static void kurumi_refresh_from_existing_backlight(void)
{
	struct backlight_device *bd;

	bd = backlight_device_get_by_type(BACKLIGHT_RAW);
	if (!bd)
		bd = backlight_device_get_by_type(BACKLIGHT_PLATFORM);
	if (!bd)
		bd = backlight_device_get_by_type(BACKLIGHT_FIRMWARE);
	if (bd)
		kurumi_screen_state_from_backlight(bd);
}

static int kurumi_backlight_notifier_call(struct notifier_block *nb,
					  unsigned long action, void *data)
{
	if (action == BACKLIGHT_REGISTERED)
		kurumi_screen_state_from_backlight(data);
	else if (action == BACKLIGHT_UNREGISTERED)
		kurumi_refresh_from_existing_backlight();

	return NOTIFY_OK;
}

static struct notifier_block kurumi_backlight_nb = {
	.notifier_call = kurumi_backlight_notifier_call,
};

static int __init kurumi_screen_state_init(void)
{
	int ret;

	kurumi_last_change_ms = kurumi_now_ms();
	kurumi_screen_kobj = kobject_create_and_add("kurumi_screen", kernel_kobj);
	if (!kurumi_screen_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(kurumi_screen_kobj, &kurumi_screen_attr_group);
	if (ret) {
		kobject_put(kurumi_screen_kobj);
		kurumi_screen_kobj = NULL;
		return ret;
	}

	backlight_register_notifier(&kurumi_backlight_nb);
	kurumi_refresh_from_existing_backlight();
	pr_info("kurumi_screen: sysfs state bridge enabled\n");
	return 0;
}

late_initcall(kurumi_screen_state_init);
