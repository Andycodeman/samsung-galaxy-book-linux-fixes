// SPDX-License-Identifier: GPL-2.0
//
// MAX98390 HDA: optional per-amp init tables matching the Windows driver
//
// On the Galaxy Book4 Ultra (codec SUBSYS 144D:C1D8) the Windows ADIAmpDriver
// writes a per-amp register table (TDM RX/TX slots, thermal and DSM config)
// and one DSM coefficient table per amp pair (woofers 0x38/0x39, tweeters
// 0x3C/0x3D). The tables are not redistributed: extract_adi_tables.py builds
// max98390-galaxybook.bin from the user's own ADIAmpDriver.sys. When the file
// is missing this code does nothing and the built-in DSM blobs are used.
//

#include <linux/firmware.h>
#include <linux/delay.h>
#include <linux/regmap.h>
#include <linux/unaligned.h>
#include "max98390_hda.h"
#include "max98390_hda_windows.h"
#include "max98390_regs.h"

#define M98W_FW_NAME	"max98390-galaxybook.bin"
#define M98W_MAX_AMPS	4
#define M98W_MAX_DSM	4
#define M98W_REG8_SIZE	4	/* u16 reg, u16 val */
#define M98W_REG32_SIZE	8	/* u16 reg, u16 pad, u32 val */

static int m98w_parse(struct max98390_hda_priv *priv, const struct firmware *fw)
{
	const u8 *p = fw->data, *end = fw->data + fw->size;
	const u8 *dsm_tbl[M98W_MAX_DSM];
	u16 dsm_n[M98W_MAX_DSM];
	u16 n_amps, n_dsm, n;
	int i, idx = priv->index;

	if (fw->size < 8 || memcmp(p, "M98W", 4) || get_unaligned_le16(p + 4) != 1)
		return -EINVAL;
	n_amps = get_unaligned_le16(p + 6);
	p += 8;
	if (n_amps > M98W_MAX_AMPS || idx < 0 || idx >= n_amps)
		return -EINVAL;

	for (i = 0; i < n_amps; i++) {
		if (end - p < 2)
			return -EINVAL;
		n = get_unaligned_le16(p);
		p += 2;
		if (end - p < n * M98W_REG8_SIZE)
			return -EINVAL;
		if (i == idx) {
			priv->win_regs = p;
			priv->win_nregs = n;
		}
		p += n * M98W_REG8_SIZE;
	}

	if (end - p < 2)
		return -EINVAL;
	n_dsm = get_unaligned_le16(p);
	p += 2;
	if (n_dsm == 0 || n_dsm > M98W_MAX_DSM)
		return -EINVAL;
	for (i = 0; i < n_dsm; i++) {
		if (end - p < 2)
			return -EINVAL;
		n = get_unaligned_le16(p);
		p += 2;
		if (end - p < n * M98W_REG32_SIZE)
			return -EINVAL;
		dsm_tbl[i] = p;
		dsm_n[i] = n;
		p += n * M98W_REG32_SIZE;
	}

	if (end - p < n_amps || p[idx] >= n_dsm)
		return -EINVAL;
	priv->win_dsm = dsm_tbl[p[idx]];
	priv->win_ndsm = dsm_n[p[idx]];
	return 0;
}

int max98390_windows_load(struct max98390_hda_priv *priv)
{
	const struct firmware *fw;
	int ret;

	ret = firmware_request_nowarn(&fw, M98W_FW_NAME, priv->dev);
	if (ret)
		return ret;

	ret = m98w_parse(priv, fw);
	if (ret) {
		dev_warn(priv->dev, "%s is malformed (%d), ignoring it\n", M98W_FW_NAME, ret);
		release_firmware(fw);
		priv->win_regs = priv->win_dsm = NULL;
		return ret;
	}

	priv->win_fw = fw;
	dev_info(priv->dev, "using Windows amp tables: %u registers, %u DSM words\n",
		 priv->win_nregs, priv->win_ndsm);
	return 0;
}

void max98390_windows_release(struct max98390_hda_priv *priv)
{
	release_firmware(priv->win_fw);
	priv->win_fw = NULL;
	priv->win_regs = priv->win_dsm = NULL;
}

/*
 * Same order as ADIAmpDriver AmpReset (after the caller's software reset and
 * PCM format setup): amp and DSP off, per-amp byte table, off again, DSM
 * words (4-byte writes, MSB first), then DSP on. Amp enable is left to the
 * caller / playback hook.
 */
int max98390_windows_init(struct max98390_hda_priv *priv)
{
	struct regmap *map = priv->regmap;
	const u8 *e;
	u8 buf[4];
	int i, ret;

	if (!priv->win_fw)
		return -ENOENT;

	regmap_write(map, MAX98390_R23FF_GLOBAL_EN, 0x00);
	regmap_write(map, MAX98390_R203A_AMP_EN, 0x80);
	regmap_write(map, MAX98390_R23E1_DSP_GLOBAL_EN, 0x00);

	for (i = 0, e = priv->win_regs; i < priv->win_nregs; i++, e += M98W_REG8_SIZE) {
		ret = regmap_write(map, get_unaligned_le16(e), get_unaligned_le16(e + 2) & 0xff);
		if (ret)
			return ret;
	}

	regmap_write(map, MAX98390_R23FF_GLOBAL_EN, 0x00);
	usleep_range(50, 100);
	regmap_write(map, MAX98390_R203A_AMP_EN, 0x80);
	regmap_write(map, MAX98390_R23E1_DSP_GLOBAL_EN, 0x00);

	for (i = 0, e = priv->win_dsm; i < priv->win_ndsm; i++, e += M98W_REG32_SIZE) {
		put_unaligned_be32(get_unaligned_le32(e + 4), buf);
		ret = regmap_bulk_write(map, get_unaligned_le16(e), buf, sizeof(buf));
		if (ret)
			return ret;
	}

	return regmap_write(map, MAX98390_R23E1_DSP_GLOBAL_EN, 0x01);
}
