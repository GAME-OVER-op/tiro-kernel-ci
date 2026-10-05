# Kurumi Fan Governor

The fan governor is optional. Recovery offers cooler control immediately after
the Economy/Balance/Full runtime profile and installs one of six binaries:
`kurumi_eco`, `kurumi_balance`, `kurumi_full`, or the matching `_fan` variant.
The three binaries without `_fan` do not compile or start the cooler thread.
The `_fan` variants run the policy inside the static Rust `kurumi-daemon`. It is
a layer over the stock Nubia fan driver and does not access PWM or GPIO directly.

## Interfaces

- Nubia settings:
  - `nubia_parts_fan_enable`
  - `nubia_parts_fan_speed_level`
- Stock driver:
  - `/sys/kernel/fan/fan_enable`
  - `/sys/kernel/fan/fan_speed_level`

The daemon synchronizes settings and sysfs in both directions. Settings.Global
has priority when both sides change in the same polling interval. With
automatic mode enabled, level `0` is standby: `fan_enable=1`, level `0`, and
zero RPM. Disabling automatic mode writes `fan_enable=0`.

## Automatic policy

The governor waits 30 seconds after the fan driver appears. Active checks run
every 15 seconds with the screen on and every 60 seconds with the screen off.
It consumes the same `screen_active` state already maintained by
`kurumi-daemon`; there is no second screen observer. SoC temperature is the
maximum of the average available CPU and GPU thermal zones. While charging
below 100%, the battery curve is also evaluated and the higher level wins when
the screen is on.

When `nubia_parts_fan_enable=0`, the governor enters a minimal disabled state.
It checks only that single Settings.Global value once per minute. It does not
read fan level, fan sysfs, charge/capacity or thermal zones. The transition into
disabled state powers the stock fan driver off once. A `0 -> 1` settings change
returns to full synchronization on the next minute check.

| Screen | Charging state | Temperature reads | Policy |
| --- | --- | --- | --- |
| On | Not charging | CPU/GPU only | SoC curve |
| On | Charging, `<100%` | CPU/GPU + battery | Maximum of both curves |
| On | Battery `100%` | CPU/GPU only | SoC curve; charging curve is disabled |
| Off | Charging, `<100%` | Battery only | Battery curve |
| Off | Not charging or battery `100%` | None | Physical fan standby (`level=0`) |

With automatic mode enabled, screen-off standby writes level `0` to both
Settings.Global and sysfs, keeping the two interfaces synchronized. The prior
desired/manual level is retained only in daemon memory and restored when policy
allows operation again. The driver remains logically enabled in standby
(`fan_enable=1`, `fan_speed_level=0`). With automatic mode disabled it remains
fully disabled (`fan_enable=0`) and its selected backup level is preserved.

| SoC temperature | Level |
| --- | ---: |
| `<60 C` | 0 |
| `60-65 C` | 1 |
| `65-70 C` | 2 |
| `70-80 C` | 3 |
| `80-90 C` | 4 |
| `>=90 C` | 5 |

| Battery temperature while charging | Level |
| --- | ---: |
| `<=40 C` | 0 |
| `40-45 C` | 1 |
| `45-50 C` | 2 |
| `50-55 C` | 3 |
| `55-60 C` | 4 |
| `>=60 C` | 5 |

Increases are applied immediately. A decrease requires three consecutive
checks and proceeds one level at a time.

## Manual override

A user speed change in either Settings.Global or sysfs is mirrored to the other
side and suspends the automatic curve. The override is memory-only and resets
when automatic mode is toggled `1 -> 0 -> 1`, when the daemon restarts, or after
a reboot. A screen-off interval does not clear the override: the chosen level is
restored when screen/charging policy permits fan operation again.

No game minimum, profile-specific rule, or persistent fan configuration is
applied.
