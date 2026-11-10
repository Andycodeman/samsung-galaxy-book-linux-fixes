// SPDX-License-Identifier: GPL-2.0
//
// MAX98390 HDA I2C driver
// Based on PR #5616 from thesofproject/linux by Kevin Cuperus
//

#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/i2c.h>

#include "max98390_hda.h"
#include "max98390_regs.h"

static int max98390_hda_i2c_probe(struct i2c_client *clt)
{
	const char *name_suffix;
	int index;

	/*
	 * Derive component index from I2C address:
	 *   0x38 -> 0, 0x39 -> 1, 0x3c -> 2, 0x3d -> 3
	 * First try parsing ".N" suffix (serial-multi-instantiate naming),
	 * then fall back to address-based mapping.
	 */
	name_suffix = strrchr(dev_name(&clt->dev), '.');
	if (name_suffix && kstrtoint(name_suffix + 1, 10, &index) == 0) {
		/* serial-multi-instantiate style: "...max98390-hda.N" */
	} else {
		/* Manual or ACPI instantiation: derive from I2C address */
		switch (clt->addr) {
		case 0x38: index = 0; break;
		case 0x39: index = 1; break;
		case 0x3c: index = 2; break;
		case 0x3d: index = 3; break;
		default:
			dev_err(&clt->dev, "Unexpected I2C address 0x%02x\n", clt->addr);
			return -EINVAL;
		}
	}

	dev_info(&clt->dev, "MAX98390 HDA I2C probe: addr=0x%02x index=%d name=%s\n",
		 clt->addr, index, dev_name(&clt->dev));

	return max98390_hda_probe(&clt->dev, "MAX98390", index, clt->irq,
				  devm_regmap_init_i2c(clt, &max98390_regmap),
				  MAX98390_HDA_I2C, clt->addr);
}

static void max98390_hda_i2c_remove(struct i2c_client *clt)
{
	max98390_hda_remove(&clt->dev);
}

static const struct i2c_device_id max98390_hda_i2c_id[] = {
	{ "max98390-hda", 0 },
	{}
};
MODULE_DEVICE_TABLE(i2c, max98390_hda_i2c_id);

static const struct acpi_device_id max98390_acpi_hda_match[] = {
	{ "MAX98390", 0 },
	{ "MX98390", 0 },
	{}
};
MODULE_DEVICE_TABLE(acpi, max98390_acpi_hda_match);

static struct i2c_driver max98390_hda_i2c_driver = {
	.driver = {
		.name		= "max98390-hda",
		.acpi_match_table = max98390_acpi_hda_match,
		.pm		= &max98390_hda_pm_ops,
	},
	.id_table	= max98390_hda_i2c_id,
	.probe		= max98390_hda_i2c_probe,
	.remove		= max98390_hda_i2c_remove,
};
module_i2c_driver(max98390_hda_i2c_driver);

MODULE_DESCRIPTION("HDA MAX98390 I2C driver");
MODULE_IMPORT_NS(MAX98390_HDA_NS);
MODULE_AUTHOR("Kevin Cuperus <cuperus.kevin@hotmail.com>");
MODULE_LICENSE("GPL");
