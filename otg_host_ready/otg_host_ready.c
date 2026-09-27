// SPDX-License-Identifier: GPL-2.0
/*
 * otg_host_ready - enable USB host (OTG) on Pixel 8 in recovery, without AoC.
 *
 * On Pixel, the dwc3 OTG state machine (dwc3-exynos-otg.c) only leaves
 * a_idle for a_host once dwc3_otg_host_ready(true) has been called. In
 * Android that call comes from aoc_usb_dev.c's probe, i.e. only after the AoC
 * coprocessor is up. Recovery never starts AoC, so OTG never works there.
 *
 * This module makes that one call on load, and undoes it on unload.
 * Experimental: xHCI on Pixel may expect AoC for USB audio offload; plain
 * devices (storage, keyboards, mice) are what this is meant for.
 */
#include <linux/module.h>
#include <linux/printk.h>

/* Exported by dwc3-exynos-usb.ko (drivers/usb/dwc3/dwc3-exynos-otg.c). */
extern int dwc3_otg_host_ready(bool ready);

static int __init otg_host_ready_init(void)
{
	int ret = dwc3_otg_host_ready(true);

	pr_info("otg_host_ready: dwc3_otg_host_ready(true) = %d\n", ret);
	return 0;
}

static void __exit otg_host_ready_exit(void)
{
	int ret = dwc3_otg_host_ready(false);

	pr_info("otg_host_ready: dwc3_otg_host_ready(false) = %d\n", ret);
}

module_init(otg_host_ready_init);
module_exit(otg_host_ready_exit);

MODULE_DESCRIPTION("Pixel 8 recovery: mark dwc3 OTG host ready without AoC");
MODULE_LICENSE("GPL");
