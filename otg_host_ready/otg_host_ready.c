// SPDX-License-Identifier: GPL-2.0
/*
 * otg_host_ready - enable USB host (OTG) on Pixel 8 in recovery, without AoC.
 *
 * On Pixel, the dwc3 OTG state machine (dwc3-exynos-otg.c) only leaves
 * a_idle for a_host once dwc3_otg_host_ready(true) has been called. In
 * Android that call comes from aoc_usb_dev.c's probe, i.e. only after the AoC
 * coprocessor is up. Recovery never starts AoC, so OTG never works there.
 *
 * This module makes that call on load (host mode on, as before) and undoes it
 * on unload. /proc/otg_host_ready: read -> 1/0, write 1/0 -> host mode on/off.
 *
 * Finding dwc3_otg_host_ready():
 *  - kernel 6.1+ (Android 15-17): at runtime through a kprobe, after
 *    LeeGarChat's otg_host_shim (OrangeFox Pixel tree, used with permission).
 *    No link-time dependency on the symbol, so the module still loads if a
 *    firmware stops exporting it. kCFI checks the target's type at the call;
 *    the pointer below has the function's exact type.
 *  - kernel 5.15 (Android 14): a direct link to the exported symbol, as
 *    before. 5.15's jump-table CFI only allows cross-module indirect calls
 *    through the target module's jump table - a raw kprobe address would trip
 *    it (kernel panic) - so no kprobe there.
 *
 * Experimental: xHCI on Pixel may expect AoC for USB audio offload; plain
 * devices (storage, keyboards, mice) are what this is meant for.
 */
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
#include <linux/kprobes.h>
#define OTG_USE_KPROBE 1
#endif

#ifdef OTG_USE_KPROBE
static int (*host_ready_fn)(bool ready);

static int resolve_host_ready(void)
{
	struct kprobe kp = { .symbol_name = "dwc3_otg_host_ready" };
	int ret = register_kprobe(&kp);

	if (ret < 0) {
		pr_err("otg_host_ready: dwc3_otg_host_ready not found (%d) - is the dwc3 driver loaded?\n", ret);
		return ret;
	}
	host_ready_fn = (int (*)(bool))kp.addr;
	unregister_kprobe(&kp);
	if (!host_ready_fn)
		return -ENOENT;
	pr_info("otg_host_ready: dwc3_otg_host_ready found via kprobe\n");
	return 0;
}

static int call_host_ready(bool ready)
{
	return host_ready_fn ? host_ready_fn(ready) : -ENOENT;
}
#else
/* Exported by dwc3-exynos-usb.ko (drivers/usb/dwc3/dwc3-exynos-otg.c). */
extern int dwc3_otg_host_ready(bool ready);

static int resolve_host_ready(void)
{
	return 0;
}

static int call_host_ready(bool ready)
{
	return dwc3_otg_host_ready(ready);
}
#endif

static bool host_on;
static DEFINE_MUTEX(host_lock);
static struct proc_dir_entry *proc_entry;

static int set_host(bool on)
{
	int ret = 0;

	mutex_lock(&host_lock);
	if (on != host_on) {
		ret = call_host_ready(on);
		pr_info("otg_host_ready: dwc3_otg_host_ready(%d) = %d\n", on, ret);
		if (!ret)
			host_on = on;
	}
	mutex_unlock(&host_lock);
	return ret;
}

static int otg_show(struct seq_file *m, void *v)
{
	seq_printf(m, "%d\n", host_on ? 1 : 0);
	return 0;
}

static int otg_open(struct inode *inode, struct file *file)
{
	return single_open(file, otg_show, NULL);
}

static ssize_t otg_write(struct file *file, const char __user *ubuf,
			 size_t count, loff_t *ppos)
{
	char c;
	int ret;

	if (count == 0)
		return -EINVAL;
	if (copy_from_user(&c, ubuf, 1))
		return -EFAULT;
	if (c != '0' && c != '1')
		return -EINVAL;
	ret = set_host(c == '1');
	return ret ? ret : count;
}

static const struct proc_ops otg_ops = {
	.proc_open	= otg_open,
	.proc_read	= seq_read,
	.proc_write	= otg_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static int __init otg_host_ready_init(void)
{
	int ret = resolve_host_ready();

	if (ret)
		return ret;
	proc_entry = proc_create("otg_host_ready", 0600, NULL, &otg_ops);
	if (!proc_entry)
		pr_warn("otg_host_ready: could not create /proc/otg_host_ready\n");
	/* host mode on at load, as before; a failure here is logged, not fatal */
	set_host(true);
	return 0;
}

static void __exit otg_host_ready_exit(void)
{
	if (proc_entry)
		proc_remove(proc_entry);
	set_host(false);
}

module_init(otg_host_ready_init);
module_exit(otg_host_ready_exit);

MODULE_DESCRIPTION("Pixel 8 recovery: mark dwc3 OTG host ready without AoC");
MODULE_LICENSE("GPL");
