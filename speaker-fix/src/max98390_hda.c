// SPDX-License-Identifier: GPL-2.0
//
// MAX98390 HDA driver
//
// Based on PR #5616 from thesofproject/linux by Kevin Cuperus
//

#include <linux/module.h>
#include <linux/regmap.h>
#include <linux/component.h>
#include <sound/hda_codec.h>
#include "hda_scodec_component.h"
#include "hda_generic.h"
#include "max98390_hda.h"
#include "max98390_hda_filters.h"
#include "max98390_regs.h"

static void max98390_hda_playback_hook(struct device *dev, int action)
{
	struct max98390_hda_priv *priv = dev_get_drvdata(dev);
	int ret;

	switch (action) {
	case HDA_GEN_PCM_ACT_OPEN:

		/* Enable global and speaker amp */
		ret = regmap_write(priv->regmap, MAX98390_R23FF_GLOBAL_EN, 0x01);
		if (ret < 0)
			dev_err(dev, "Failed to write GLOBAL_EN: %d\n", ret);

		ret = regmap_write(priv->regmap, MAX98390_R203A_AMP_EN, 0x81);
		if (ret < 0)
			dev_err(dev, "Failed to write AMP_EN: %d\n", ret);

		break;

	case HDA_GEN_PCM_ACT_CLOSE:
		/* Disable speaker amp and global */
		regmap_write(priv->regmap, MAX98390_R203A_AMP_EN, 0x80);
		regmap_write(priv->regmap, MAX98390_R23FF_GLOBAL_EN, 0x00);
		break;

	default:
		break;
	}
}

static int max98390_hda_bind(struct device *dev, struct device *master, void *master_data)
{
	struct max98390_hda_priv *priv = dev_get_drvdata(dev);
	struct hda_component_parent *parent = master_data;
	struct hda_component *comp;

	comp = hda_component_from_index(parent, priv->index);
	if (!comp)
		return -EINVAL;

	comp->dev = dev;
	strscpy(comp->name, dev_name(dev), sizeof(comp->name));
	comp->playback_hook = max98390_hda_playback_hook;

	dev_info(dev, "MAX98390 HDA component bound (index %d)\n", priv->index);

	return 0;
}

static void max98390_hda_unbind(struct device *dev, struct device *master, void *master_data)
{
	struct max98390_hda_priv *priv = dev_get_drvdata(dev);
	struct hda_component_parent *parent = master_data;
	struct hda_component *comp;

	comp = hda_component_from_index(parent, priv->index);
	if (comp && comp->dev == dev) {
		comp->dev = NULL;
		memset(comp->name, 0, sizeof(comp->name));
		comp->playback_hook = NULL;
	}

	dev_info(dev, "MAX98390 HDA component unbound\n");
}

static const struct component_ops max98390_hda_comp_ops = {
	.bind = max98390_hda_bind,
	.unbind = max98390_hda_unbind,
};

static int max98390_hda_init(struct max98390_hda_priv *priv)
{
	int ret;
	unsigned int reg;

	/* Check device ID */
	ret = regmap_read(priv->regmap, MAX98390_R24FF_REV_ID, &reg);
	if (ret < 0)
		return ret;

	/* Software reset */
	ret = regmap_write(priv->regmap, MAX98390_SOFTWARE_RESET, 0x01);
	if (ret < 0)
		return ret;

	msleep(20);

	/* Basic register initialization (minimal setup for HDA) */
	regmap_write(priv->regmap, MAX98390_CLK_MON, 0x6f);
	regmap_write(priv->regmap, MAX98390_DAT_MON, 0x00);
	regmap_write(priv->regmap, MAX98390_PWR_GATE_CTL, 0x00);
	regmap_write(priv->regmap, MAX98390_PCM_RX_EN_A, 0x03);
	regmap_write(priv->regmap, MAX98390_ENV_TRACK_VOUT_HEADROOM, 0x0e);
	regmap_write(priv->regmap, MAX98390_BOOST_BYPASS1, 0x46);
	regmap_write(priv->regmap, MAX98390_FET_SCALING3, 0x03);

	/* PCM/I2S configuration - CRITICAL for correct audio format */
	/* 0xC0 = I2S mode, 32-bit samples (standard for HDA) */
	regmap_write(priv->regmap, MAX98390_PCM_MODE_CFG, 0xc0);
	regmap_write(priv->regmap, MAX98390_PCM_MASTER_MODE, 0x1c);
	regmap_write(priv->regmap, MAX98390_PCM_CLK_SETUP, 0x44);
	regmap_write(priv->regmap, MAX98390_PCM_SR_SETUP, 0x08);

	/* RESET EN - Write 0x00 to 0x23FF */
	regmap_write(priv->regmap, MAX98390_R23FF_GLOBAL_EN, 0x00);

	/* Wait 50ms */
	msleep(50);

	/* RESET SPK_EN - Write 0x80 to 0x203A */
	regmap_write(priv->regmap, MAX98390_R203A_AMP_EN, 0x80);

	/* RESET DSP_GLOBAL_EN - Write 0x00 to 0x23E1 */
	regmap_write(priv->regmap, MAX98390_R23E1_DSP_GLOBAL_EN, 0x00);

	/* Configure filters and load DSM firmware */
	max98390_configure_filters(priv);

	return 0;
}

int max98390_hda_probe(struct device *dev, const char *device_name,
		       int id, int irq, struct regmap *regmap,
		       enum max98390_hda_bus_type bus_type, int i2c_addr)
{
	struct max98390_hda_priv *priv;
	int ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->dev = dev;
	priv->regmap = regmap;
	priv->bus_type = bus_type;
	priv->irq = irq;
	priv->index = id;
	priv->i2c_addr = i2c_addr;
	dev_set_drvdata(dev, priv);

	ret = max98390_hda_init(priv);
	if (ret)
		return ret;

	ret = component_add(dev, &max98390_hda_comp_ops);
	if (ret)
		return ret;

	return 0;
}
EXPORT_SYMBOL_NS_GPL(max98390_hda_probe, "SND_HDA_SCODEC_MAX98390");

void max98390_hda_remove(struct device *dev)
{
	struct max98390_hda_priv *priv = dev_get_drvdata(dev);

	component_del(dev, &max98390_hda_comp_ops);

	if (priv && priv->regmap) {
		/* Disable amp on removal */
		regmap_write(priv->regmap, MAX98390_R203A_AMP_EN, 0x80);
	}
}
EXPORT_SYMBOL_NS_GPL(max98390_hda_remove, "SND_HDA_SCODEC_MAX98390");

static int max98390_hda_runtime_suspend(struct device *dev)
{
	struct max98390_hda_priv *priv = dev_get_drvdata(dev);

	regmap_write(priv->regmap, MAX98390_R203A_AMP_EN, 0x80);
	regcache_cache_only(priv->regmap, true);
	regcache_mark_dirty(priv->regmap);

	return 0;
}

static int max98390_hda_runtime_resume(struct device *dev)
{
	struct max98390_hda_priv *priv = dev_get_drvdata(dev);

	regcache_cache_only(priv->regmap, false);
	regcache_sync(priv->regmap);

	return 0;
}

/*
 * Hibernate powers the amps off, losing every register written at probe,
 * including the DSM tuning. REGCACHE_NONE means there is nothing to replay,
 * so re-run the full init. Covers resume, thaw and restore (issue #98).
 */
static int max98390_hda_resume(struct device *dev)
{
	struct max98390_hda_priv *priv = dev_get_drvdata(dev);
	int ret;

	ret = max98390_hda_init(priv);
	if (ret) {
		dev_err(dev, "Failed to re-initialise amp on resume: %d\n", ret);
		return ret;
	}

	dev_info(dev, "MAX98390 amp re-initialised on resume\n");

	return 0;
}

const struct dev_pm_ops max98390_hda_pm_ops = {
	SYSTEM_SLEEP_PM_OPS(NULL, max98390_hda_resume)
	RUNTIME_PM_OPS(max98390_hda_runtime_suspend, max98390_hda_runtime_resume, NULL)
};
EXPORT_SYMBOL_NS_GPL(max98390_hda_pm_ops, "SND_HDA_SCODEC_MAX98390");

MODULE_DESCRIPTION("HDA MAX98390 side codec library");
MODULE_AUTHOR("Kevin Cuperus <cuperus.kevin@hotmail.com>");
MODULE_LICENSE("GPL");
