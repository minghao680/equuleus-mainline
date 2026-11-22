// SPDX-License-Identifier: GPL-2.0
/*
 * Restart reason for Qualcomm SDM845 boards whose bootloader reads IMEM.
 *
 * "reboot bootloader" does nothing on the Xiaomi Mi 8 Pro: mainline's qcom-pon
 * writes the PMIC's PON_SOFT_RB_SPARE register, but this ABL consults a word in
 * IMEM instead. The vendor kernel writes both:
 *
 *     qpnp_pon_set_restart_reason(PON_RESTART_REASON_BOOTLOADER);
 *     __raw_writel(0x77665500, restart_reason);
 *
 * and 0x77665500 is the magic it looks for. Without it the bootloader sees an
 * ordinary restart.
 *
 * Offsets are from the vendor sdm845.dtsi, which describes the same IMEM layout:
 *
 *     restart_reason@65c { reg = <0x65c 4>; };
 *
 * Mainline's sdm845.dtsi does not declare that child, so this driver finds the
 * IMEM syscon and maps the offset itself.
 *
 * A restart handler is used rather than reboot-mode because the value depends on
 * the command string, and reboot-mode's magic table would need one entry per
 * command in the device tree for no benefit - the numbers are fixed by the
 * bootloader, not by the board.
 */

#include <linux/io.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/reboot.h>
#include <linux/regmap.h>

#define IMEM_RESTART_REASON_OFFSET	0x65c

#define QCOM_RESTART_NORMAL		0x77665501
#define QCOM_RESTART_BOOTLOADER		0x77665500
#define QCOM_RESTART_RECOVERY		0x77665502
#define QCOM_RESTART_RTC		0x77665503

struct qcom_restart_reason {
	struct regmap *imem;
	struct notifier_block nb;
};

static int qcom_restart_reason_notify(struct notifier_block *nb,
				      unsigned long action, void *data)
{
	struct qcom_restart_reason *rr =
		container_of(nb, struct qcom_restart_reason, nb);
	const char *cmd = data;
	u32 magic;

	if (cmd && !strcmp(cmd, "bootloader"))
		magic = QCOM_RESTART_BOOTLOADER;
	else if (cmd && !strcmp(cmd, "recovery"))
		magic = QCOM_RESTART_RECOVERY;
	else if (cmd && !strcmp(cmd, "rtc"))
		magic = QCOM_RESTART_RTC;
	else
		magic = QCOM_RESTART_NORMAL;

	/*
	 * Best effort: if this fails the device still reboots, it just will not
	 * land in the requested mode, and that is not worth failing a reboot over.
	 */
	regmap_write(rr->imem, IMEM_RESTART_REASON_OFFSET, magic);

	return NOTIFY_DONE;
}

static int qcom_restart_reason_probe(struct platform_device *pdev)
{
	struct qcom_restart_reason *rr;
	struct device *dev = &pdev->dev;
	int ret;

	rr = devm_kzalloc(dev, sizeof(*rr), GFP_KERNEL);
	if (!rr)
		return -ENOMEM;

	/*
	 */
	/*
	 * The IMEM node has no label upstream, so it cannot be referenced by
	 * phandle from a board file. Its compatible string is stable.
	 */
	rr->imem = syscon_regmap_lookup_by_compatible("qcom,sdm845-imem");
	if (IS_ERR(rr->imem))
		return dev_err_probe(dev, PTR_ERR(rr->imem),
				     "cannot find the IMEM syscon\n");

	rr->nb.notifier_call = qcom_restart_reason_notify;
	rr->nb.priority = 128;

	ret = register_restart_handler(&rr->nb);
	if (ret)
		return dev_err_probe(dev, ret, "cannot register restart handler\n");

	platform_set_drvdata(pdev, rr);

	dev_info(dev, "restart reason will be written to IMEM +0x%x\n",
		 IMEM_RESTART_REASON_OFFSET);

	return 0;
}

static void qcom_restart_reason_remove(struct platform_device *pdev)
{
	struct qcom_restart_reason *rr = platform_get_drvdata(pdev);

	unregister_restart_handler(&rr->nb);
}

static const struct of_device_id qcom_restart_reason_of_match[] = {
	{ .compatible = "qcom,imem-restart-reason" },
	{ }
};
MODULE_DEVICE_TABLE(of, qcom_restart_reason_of_match);

static struct platform_driver qcom_restart_reason_driver = {
	.probe = qcom_restart_reason_probe,
	.remove = qcom_restart_reason_remove,
	.driver = {
		.name = "qcom-imem-restart-reason",
		.of_match_table = qcom_restart_reason_of_match,
	},
};
module_platform_driver(qcom_restart_reason_driver);

MODULE_DESCRIPTION("Qualcomm IMEM restart reason");
MODULE_LICENSE("GPL");
