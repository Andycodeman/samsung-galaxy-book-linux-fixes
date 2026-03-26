# Hardware Compatibility Editor — User Manual

`hardware-compat-editor.py` is a standalone GTK3 admin tool for maintaining `lib/galaxybook.json`. It is intended for project maintainers only — end users never need to run it.

Launch via the accompanying desktop file (`samsung-galaxybook-compat-editor.desktop`), or from a terminal:

```bash
python3 ./hardware-compat-editor.py
```

---

## Contents

1. [What This Tool Does](#1-what-this-tool-does)
2. [First Launch](#2-first-launch)
3. [The Main View — The Compatibility Grid](#3-the-main-view--the-compatibility-grid)
4. [The Most Common Task — Updating Fix Compatibility](#4-the-most-common-task--updating-fix-compatibility)
5. [Adding a New Fix](#5-adding-a-new-fix)
6. [Editing an Existing Fix](#6-editing-an-existing-fix)
7. [Editing a Model](#7-editing-a-model)
8. [Reordering Fixes](#8-reordering-fixes)
9. [Saving, Pushing, and Restoring](#9-saving-pushing-and-restoring)
10. [How Changes Here Affect the Main GUI](#10-how-changes-here-affect-the-main-gui)
11. [Settings](#11-settings)
12. [galaxybook.json — Structure Reference](#12-galaxybookjson--structure-reference)
13. [Quick Reference — What to Do When](#13-quick-reference--what-to-do-when)

---

## 1. What This Tool Does

Everything in the Samsung Galaxy Book Fixes GUI (`samsung-galaxybook-gui.py`) is driven by a single file: `lib/galaxybook.json`. The GUI reads this file at startup and uses it to decide:

- Which laptop models are supported and how to identify them from the hardware
- Which fixes exist, where their install.sh and uninstall.sh scripts are located on disk, and what they do
- Which fixes apply to which models (and whether they're confirmed working, likely, untested, or not applicable)
- Where the install and uninstall scripts for each fix live on disk
- How to detect whether a fix is currently installed
- Whether a fix requires a reboot, an initramfs rebuild, or a specific desktop environment
- Whether to show a Secure Boot warning before installing

**The Hardware Compatibility Editor is a graphical front-end for editing `galaxybook.json` safely.** You never need to edit the JSON by hand — and in fact you shouldn't, because the editor makes backups before every save and validates your input. Any change you make in the editor and save is immediately picked up by the main GUI the next time it opens.

---

## 2. First Launch

On first launch you will be asked for two things:

**galaxybook.json path** — the full path to `lib/galaxybook.json` in your local clone of the repo. Use the Browse button to locate it. Example:
```
/home/andy/git/samsung-galaxybook5-fixes/lib/galaxybook.json
```

**GitHub remote URL** — the SSH or HTTPS URL of the repo. The editor accepts any format:
- `https://github.com/david-bartlett/samsung-galaxybook5-fixes`
- `git@github.com:david-bartlett/samsung-galaxybook5-fixes.git`
- `david-bartlett/samsung-galaxybook5-fixes`

These settings are saved to `~/.config/galaxybook-compat/config.conf` and can be changed later via **☰ Menu → Settings**.

<img src="https://raw.githubusercontent.com/david-bartlett/samsung-galaxy-book4-linux-fixes-fork/galaxybook5-fixes/.github/images/hce6.png" width="50%">

---

## 3. The Main View — The Compatibility Grid

After setup, the main view shows a grid of every **fix × every model**, grouped by hardware series (Galaxy Book 5, Book 4, Book 3).

<img src="https://raw.githubusercontent.com/david-bartlett/samsung-galaxy-book4-linux-fixes-fork/galaxybook5-fixes/.github/images/hce1.png" width="50%">

Each cell in the grid shows the status of that fix for that model as a colour-coded button:

| Colour | Status | What it means in the main GUI |
| ------ | ------ | ----------------------------- |
| 🟢 Green | Confirmed | Fix shown normally — verified working on this model |
| 🔵 Blue | Likely | Fix shown with `⚠ Reported working — not verified` warning |
| 🟠 Orange | Untested | Fix shown with `⚠ Untested on your model` warning |
| ⬜ Grey | Hidden | Fix card hidden — applicable but intentionally not shown |
| Dark | N/A | Fix card hidden — not applicable to this model |
| — | (no entry) | Fix has no entry at all for this model |

The warning badges appear in the fix description in the main GUI whether the fix is installed or not — so if you later downgrade a model from Confirmed to Untested, users who already have it installed will see the warning badge after their next `git pull`.

**Click any cell** to change its status via a popover.

**Click any fix column header** (e.g. "Fan Speed Fix") to open the Edit Fix form for that fix.

**Click any model name** on the left (e.g. "940XHA Galaxy Book 5 Pro 14"") to open the Edit Model form for that model.

---

## 4. The Most Common Task — Updating Fix Compatibility

When a community member reports that a fix works on a model:

<img src="https://raw.githubusercontent.com/david-bartlett/samsung-galaxy-book4-linux-fixes-fork/galaxybook5-fixes/.github/images/hce2.png" width="50%">

1. Find the model row and fix column in the grid
2. Click the cell — a popover appears with all status options
3. Select **Confirmed** (or **Likely** if not fully verified)
4. Click **Save** at the bottom of the window
5. Click **Push to GitHub** to commit and push `galaxybook.json` directly

That's it. The main GUI picks up the change automatically — no code changes needed anywhere.

---

## 5. Adding a New Fix

When you've written a new `install.sh` / `uninstall.sh` pair and want it to appear in the main GUI, use **☰ Menu → Add Fix**.

<img src="https://raw.githubusercontent.com/david-bartlett/samsung-galaxy-book4-linux-fixes-fork/galaxybook5-fixes/.github/images/hce3.png" width="50%">

### Fields to fill in

**Fix key** *(required, permanent)* — a short internal identifier used everywhere in the codebase. Set it once and it cannot be changed later. Use lowercase, hyphens and underscores allowed. Examples: `webcam-toggle`, `fanspeed`, `myfix`.

**Label** *(required)* — the display name shown as the fix card heading in the main GUI. Example: `Fan Speed Fix`.

**Description** — the short text shown under the label in the fix card. Keep it concise — one line.

**Install script** *(required)* — the path to your `install.sh` relative to the repo root. Use the Browse button to select it. Example: `lib/fanspeed-fix/install.sh`.

**Uninstall script** *(required)* — same as above for `uninstall.sh`. Example: `lib/fanspeed-fix/uninstall.sh`.

**Requires reboot** — tick this if your fix requires a reboot after install or uninstall. The main GUI will show a "Reboot Now" button and write a reboot marker file at `/tmp/<fix-key>-need-reboot` after the script completes.

**Script identifiers** *(required)* — this is the most important field to get right. These are file paths that the main GUI checks to determine whether the fix is currently installed. The GUI checks that all listed paths exist on disk — if they all exist, the fix is shown as "Installed". If any are missing, it's shown as "Not installed".

Good choices for script identifiers:
- A marker file written by your install script: `/var/lib/samsung-galaxybook/<fix>.installed`
- A config file your script installs: `/etc/modprobe.d/my-fix.conf`
- A binary your script installs: `/usr/local/bin/my-tool`

Avoid paths that only exist on certain distros (e.g. `/etc/initramfs-tools/` only exists on Ubuntu/Debian). Use paths that are consistent across Fedora, Ubuntu, and Arch. The simplest approach is to add a `touch /var/lib/samsung-galaxybook/<fix>.installed` at the end of your install script and a matching `rm -f` in your uninstall script, then use that path as the identifier.

**Secure Boot behaviour** — controls what the main GUI does when Secure Boot is enabled:
- `none` — fix works fine with Secure Boot, no warning shown
- `warn` — shows an amber warning but still allows install
- `block` — disables the Install button entirely when Secure Boot is on

**Requires initramfs rebuild** — tick this if your fix modifies the initramfs (e.g. DSDT overrides, firmware changes). The main GUI runs a single initramfs rebuild at the end of a fix sequence — it will never rebuild twice even if multiple fixes require it.

**Requires desktop environment** — if your fix is DE-specific (e.g. a KDE-only OSD notification fix), select the DE here. The fix card will be hidden on all other desktop environments. Leave as `none` for hardware fixes that apply regardless of DE.

**Notes** — admin notes visible in the editor only, never shown to end users.

When you save a new fix, all known models are set to `Untested` in `applicable_models`. Update statuses in the grid as community testing confirms compatibility.

---

## 6. Editing an Existing Fix

Click any **fix column header** in the grid to open the Edit Fix form. All the same fields as Add Fix are available, plus:

<img src="https://raw.githubusercontent.com/david-bartlett/samsung-galaxy-book4-linux-fixes-fork/galaxybook5-fixes/.github/images/hce4.png" width="50%">

**Applicable Models — quick set** — at the bottom of the form, below Notes. Shows a summary of the current compatibility status counts. You can bulk-set all models to a chosen status in one click (with a confirmation dialog), or edit the raw JSON directly in the text box and click Apply JSON.

**Delete Fix** — removes the fix entry from `galaxybook.json`. Script files on disk are not touched — you must remove those manually. A backup is made before deletion.

---

## 7. Editing a Model

Click any **model name** on the left side of the grid to open the Edit Model form.

<img src="https://raw.githubusercontent.com/david-bartlett/samsung-galaxy-book4-linux-fixes-fork/galaxybook5-fixes/.github/images/hce5.png" width="50%">

| Field | Description |
|-------|-------------|
| Display name | Full name shown in the main GUI header, e.g. `Galaxy Book 5 Pro 14"` |
| CPU | CPU description, e.g. `Core Ultra 7 258V (Lunar Lake)` |
| Camera sensor | Sensor ID, e.g. `OV02E10` — shown as a subtitle under the model name in the grid |
| Speaker amp | Amplifier chip, e.g. `MAX98390` — shown alongside the camera sensor |
| Notes | Admin notes — not shown to end users |
| Advanced — Hardware IDs | Collapsible section for PCI subsystem ID and kernel quirk table status (reference data only, not currently used by any scripts) |

---

## 8. Reordering Fixes

The order fixes appear in `fix_order` in `galaxybook.json` is the order they appear in the main GUI. To change the order, use **☰ Menu → Reorder Fixes**. Use the ▲/▼ buttons to move fixes up or down, then click **Apply Order**. This marks the file as dirty — click Save to write the change.

---

## 9. Saving, Pushing, and Restoring


**Save** — writes `galaxybook.json` to disk and creates a timestamped backup in `~/.config/galaxybook-compat/backups/`. Up to 10 backups are kept; older ones are removed automatically. The title bar shows `*` when there are unsaved changes.

**Push to GitHub** — stages `lib/galaxybook.json`, commits it with an auto-generated message (`galaxybook: update model compatibility data (YYYY-MM-DD HH:MM)`), and pushes to the `main` branch of the configured remote. If you have unsaved changes, you'll be asked whether to save first. Only `lib/galaxybook.json` is ever committed — no other files are touched.

**Restore Backup** — shows a list of available backups sorted newest first. Select one and click Restore to roll back. The current state is backed up before restoring.

---

## 10. How Changes Here Affect the Main GUI

To be clear about the relationship between the editor, `galaxybook.json`, and the main GUI:

| What you change in the editor | Effect in the main GUI |
| ----------------------------- | ---------------------- |
| Cell status → Confirmed | Fix card shown, no warning badge |
| Cell status → Likely | Fix card shown, `⚠ Reported working — not verified` in description |
| Cell status → Untested | Fix card shown, `⚠ Untested on your model` in description |
| Cell status → Hidden or N/A | Fix card hidden entirely, install/uninstall disabled |
| Fix label | Fix card heading text |
| Fix description | Fix card body text |
| Script identifiers | What the GUI checks to show Installed / Not installed |
| Requires reboot | Whether GUI shows Reboot Now button after install/uninstall |
| Requires initramfs | Whether GUI runs `dracut`/`update-initramfs` at end of sequence |
| Secure Boot behaviour | Whether Install button is disabled or warned when Secure Boot is on |
| Requires DE | Whether fix card is hidden on non-matching desktop environments |
| Fix order | Order fix cards appear in the GUI |
| Model display name / camera / speaker | Subtitle text shown in the fix card hw_status badge |

**No code changes to the main GUI are ever needed** when updating compatibility data, adding a fix, or changing fix metadata. The GUI reads `galaxybook.json` fresh on every launch.

---

## 11. Settings

Access via **☰ Menu → Settings**. You can update the `galaxybook.json` path and GitHub remote URL at any time. The backup directory location and count are shown at the bottom of the settings panel.

---

## 12. galaxybook.json — Structure Reference

For cases where you need to understand or manually verify the JSON structure. The editor handles all of this for you in normal use.

### `fix_order`
Array of fix keys in the order fixes appear in the main GUI:
```json
"fix_order": ["fanspeed", "fingerprint", "fnkeys", "kdeosd", ...]
```

### `series`
Hardware families — used by the main GUI for model detection and grouping:
```json
"book5": {
  "label": "Galaxy Book 5",
  "cpu_gen": "Lunar Lake (Core Ultra 2xx)",
  "ipu": "IPU7",
  "prefixes": ["940XHA", "960XHA", "960QHA", "750XHD", ...],
  "blocked": false
}
```
Set `"blocked": true` to hide an entire series from the main GUI.

### `models`
Per-model hardware detail:
```json
"940XHA": {
  "name": "Galaxy Book 5 Pro 14\"",
  "series": "book5",
  "cpu": "Core Ultra 7 258V (Lunar Lake)",
  "camera_sensor": "OV02E10",
  "speaker_amp": "MAX98390",
  "notes": "Mic confirmed working after speaker fix."
}
```

### `fixes`
The full fix registry — one entry per fix:
```json
"fanspeed": {
  "label": "Fan Speed Fix",
  "description": "ACPI DSDT override to fix _FST fan RPM reporting",
  "install_script": "lib/fanspeed-fix/install.sh",
  "uninstall_script": "lib/fanspeed-fix/uninstall.sh",
  "reboot_marker": "/tmp/fanfix-need-reboot",
  "secure_boot_behaviour": "block",
  "requires_initramfs": true,
  "requires_de": "",
  "script_identifier": ["/var/lib/samsung-galaxybook/dsdt-firmware.sha256"],
  "applicable_models": {
    "940XHA": "confirmed",
    "960XHA": "confirmed",
    "960QHA": "untested"
  },
  "notes": "Book 4 and Book 5 confirmed. Book 3 compatibility unknown."
}
```

`applicable_models` can also be `"*"` (wildcard) — means the fix applies to all models as Confirmed. Used for fixes that are filtered by `requires_de` rather than by hardware.

---

## 13. Quick Reference — What to Do When

| Situation | What to do |
| --------- | ---------- |
| Community member confirms fix works on a model | Click cell → Confirmed → Save → Push |
| You've written a new fix and want it in the GUI | Menu → Add Fix, fill in all fields, Save |
| You want to change a fix's label or description | Click column header → Edit Fix → Save |
| A fix should only show on KDE | Click column header → Edit Fix → Requires DE → kde → Save |
| You want to hide a fix on a specific model | Click cell → Hidden → Save |
| You want to reorder how fixes appear | Menu → Reorder Fixes → ▲/▼ → Apply Order → Save |
| Something went wrong and you need to roll back | Restore Backup → select backup → Restore |
