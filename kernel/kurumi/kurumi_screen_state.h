/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_KURUMI_SCREEN_STATE_H
#define _LINUX_KURUMI_SCREEN_STATE_H

struct backlight_device;

#ifdef CONFIG_KURUMI_SCREEN_STATE
void kurumi_screen_state_from_backlight(const struct backlight_device *bd);
#else
static inline void kurumi_screen_state_from_backlight(const struct backlight_device *bd) { }
#endif

#endif /* _LINUX_KURUMI_SCREEN_STATE_H */
