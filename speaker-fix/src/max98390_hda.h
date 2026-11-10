/* SPDX-License-Identifier: GPL-2.0 */
/*
 * MAX98390 HDA audio driver
 */

#ifndef __MAX98390_HDA_H__
#define __MAX98390_HDA_H__

#include <linux/regmap.h>
#include <linux/version.h>
#include <sound/hda_codec.h>

/*
 * Symbol namespaces became string literals in 6.13 (commit cdd30ebb1b9f).
 * Older kernels (e.g. Debian 13's 6.12) stringify a bare identifier, so a
 * quoted name ends up double-quoted and the .mod.c fails to build.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
#define MAX98390_HDA_NS "SND_HDA_SCODEC_MAX98390"
#else
#define MAX98390_HDA_NS SND_HDA_SCODEC_MAX98390
#endif

struct firmware;

enum max98390_hda_bus_type {
	MAX98390_HDA_I2C,
};

struct max98390_hda_priv {
	struct device *dev;
	struct regmap *regmap;
	enum max98390_hda_bus_type bus_type;
	int irq;
	int index;
	const char *acpi_subsystem_id;
	int i2c_addr;  /* I2C address for speaker identification */

	/* Optional Windows-matching tables (max98390_hda_windows.c) */
	const struct firmware *win_fw;
	const u8 *win_regs;
	u16 win_nregs;
	const u8 *win_dsm;
	u16 win_ndsm;
};

int max98390_hda_probe(struct device *dev, const char *device_name,
		       int id, int irq, struct regmap *regmap,
		       enum max98390_hda_bus_type bus_type, int i2c_addr);
void max98390_hda_remove(struct device *dev);

extern const struct dev_pm_ops max98390_hda_pm_ops;

#endif /* __MAX98390_HDA_H__ */
