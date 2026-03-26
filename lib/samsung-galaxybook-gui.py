#!/usr/bin/env python3
# =============================================================================
# Samsung Galaxy Book 5 — Linux Fixes GUI
# =============================================================================
# Requires: python3-gobject (GTK3). Run via pkexec from samsung-galaxybook-gui.
# Launch via: samsung-galaxybook-gui
# =============================================================================

import os
import sys
import re
import json
import shutil
import subprocess
import threading
import pwd
import configparser

import cairo

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gdk, GdkPixbuf, Pango


# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR   = os.path.dirname(os.path.realpath(__file__))
LOCK_FILE    = "/tmp/samsung-galaxybook-gui.pid"
GALAXYBOOK_JSON = os.path.join(SCRIPT_DIR, "galaxybook.json")

# ── Testing: model override (set by --model startup flag) ─────────────────────
OVERRIDE_MODEL = None  # e.g. "940XHA" — bypasses real hardware detection

# ── Load galaxybook.json — single source of truth ────────────────────────────
def _load_galaxybook_data():
    try:
        with open(GALAXYBOOK_JSON) as _f:
            return json.load(_f)
    except Exception as _e:
        print(f"[WARN] Could not load galaxybook.json: {_e}")
        return {}

GB_DATA = _load_galaxybook_data()

# ── Build FIXES list from galaxybook.json ─────────────────────────────────────
def _build_fixes(data):
    fixes_map = data.get("fixes", {})
    order     = data.get("fix_order", list(fixes_map.keys()))
    return [
        {
            "key":   k,
            "title": fixes_map[k].get("label", k),
            "desc":  fixes_map[k].get("description", ""),
        }
        for k in order if k in fixes_map
    ]

FIXES = _build_fixes(GB_DATA)

# ── Colour tags ───────────────────────────────────────────────────────────────
TAG_INFO  = "tag_info"
TAG_WARN  = "tag_warn"
TAG_ERROR = "tag_error"
TAG_PLAIN = "tag_plain"
TAG_BOLD  = "tag_bold"

# ── Font helpers ──────────────────────────────────────────────────────────────
def _resolve_ui_font():
    """Return 'Inter' if it is available on the system, otherwise None (use GTK default).

    Checks Pango's font map so it works on both Wayland and X11, across all
    distros — regardless of whether Inter was installed as fonts-inter (Debian/
    Ubuntu), inter-font (Fedora), or ttf-inter (Arch).
    """
    try:
        context  = Pango.Context.new()
        font_map = context.get_font_map()
        families = [f.get_name() for f in font_map.list_families()]
        if "Inter" in families:
            return "Inter"
    except Exception:
        pass
    return None


# ── Status helpers ────────────────────────────────────────────────────────────
def status_label(st, msg, reboot_pending=False):
    """Return a human-readable status string."""
    labels = {
        "installed":     "✓  Installed",
        "not_installed": "○  Not installed",
        "not_needed":    "Not needed",
        "not_applicable":"Not applicable",
    }
    base = labels.get(st, st)
    if reboot_pending:
        base += "  —  Reboot required"
    elif msg:
        base += f"  —  {msg}"
    return base


class SamsungFixesApp(Gtk.Window):

    def __init__(self):
        super().__init__(title="Samsung Book Fixes")
        self.set_resizable(True)

        # --- 1. DETECT DISTRO OS ---
        # Ubuntu GNOME has a bug where get_geometry() returns inflated values
        # (e.g. 3324x2096 on a 1728x1080 screen) after fractional scaling is changed
        # mid-session. Confirmed on Ubuntu 25.10 and 26.04 with GNOME — not a live
        # environment issue as all other distros tested (including Kubuntu) were also
        # run as live environments and returned correct values. The bug is specific to
        # Ubuntu's GNOME session and its Xwayland scaling implementation.
        # Fix: Ubuntu uses get_workarea() which stays accurate; all others use get_geometry().
        _is_ubuntu = False
        try:
            with open("/etc/os-release", "r") as f:
                if "ubuntu" in f.read().lower():
                    _is_ubuntu = True
        except Exception:
            pass
        self._is_ubuntu = _is_ubuntu

        # --- 2. GET MONITOR ---
        _display = Gdk.Display.get_default()
        _monitor = _display.get_primary_monitor()
        if _monitor is None:
            # KDE may not set a primary monitor — pick largest
            _best = 0
            for _i in range(_display.get_n_monitors()):
                _m = _display.get_monitor(_i)
                _g = _m.get_geometry()  # Using geometry here prevents KDE bugs
                if _g.width * _g.height > _best:
                    _best = _g.width * _g.height
                    _monitor = _m

        # --- 3. GET CORRECT DIMENSIONS ---
        if _monitor is None:
            _w, _h = 1920, 1080
        else:
            if _is_ubuntu:
                # Ubuntu: get_workarea() returns stable correct values even after
                # scaling changes; get_geometry() returns inflated Xwayland values.
                _wa = _monitor.get_workarea()
                _w  = _wa.width
                _h  = _wa.height
            else:
                # All other distros: get_geometry() is accurate.
                # get_workarea() can over-subtract panel height on some DEs.
                _geom = _monitor.get_geometry()
                _w  = _geom.width
                _h  = _geom.height

        # --- 4. WINDOW SIZING ---
        # Base Window Multipliers
        _w_mult = 0.32
        _h_mult = 0.57

        # Dynamically scale the 60px titlebar/taskbar buffer based on DPI
        screen = Gdk.Screen.get_default()
        dpi = screen.get_resolution() if screen else 96.0
        _title_buffer = int(60 * (dpi / 96.0))

        # Calculate Final Window Dimensions
        # Enforce minimums so the window stays usable, but allow it to shrink
        # enough to fit inside 200% scaling boundaries to keep buttons clickable.
        _win_w = int(_w * _w_mult)
        _win_w = min(_w, max(450, _win_w))
        _min_w = min(_w, max(450, int(_win_w * 0.80)))

        _win_h = int((_h - _title_buffer) * _h_mult)
        # Ubuntu GNOME with 200%+ scaling reports a very small logical workarea
        # (e.g. 380-500px tall depending on scaling level). A hard 500px floor
        # would consume the entire workarea at any scaling >= 200% and collapse
        # pos_y to ~0. On Ubuntu, skip the floor entirely and let _h_mult govern
        # the height — 60% of available space is always a sensible size.
        # All other distros keep the 500px minimum.
        if not _is_ubuntu:
            _win_h = max(500, _win_h)
        _win_h = min(_h - _title_buffer, _win_h)

        self.set_default_size(_win_w, _win_h)
        self.set_size_request(_min_w, -1)  # minimum usable width

        # Store logical dims and window height for use in _build_ui
        self._logical_w = _w
        self._logical_h = _h
        self._win_w = _win_w
        self._win_h = _win_h

        # --- 5. SPACING & MARGIN MULTIPLIER ---
        # Get GTK integer scale factor (e.g., 1 for 100/165%, 2 for 200%)
        _scale = _monitor.get_scale_factor() if _monitor else 1

        # Unify DE behavior by normalizing the logical width using DPI
        _normalized_w = _w / (dpi / 96.0)

        # Spacing scale: 1.0 at baseline (1745px), shrinks at higher scaling
        _sp_raw = _normalized_w / 1745
        _base_sp = 1.0 + (_sp_raw - 1.0) * 0.4

        # Divide by GTK scale so 200% integer scaling doesn't physically double the margins
        _sp = _base_sp / _scale

        # Lower the minimum bound to 0.3 so the multiplier safely halves at 2x scale
        self._sp = max(0.3, min(1.3, _sp))

        # Apply scaled CSS (buttons etc)
        self._apply_css()

        # Scale font to screen — only active when DPI > 96 (KDE) or gtk_scale=1
        # at DPI=96 (100% scaling on HiDPI). Leaves font alone at gtk_scale=2
        # since GTK's integer doubling already handles text size correctly there.
        self._scale_font_to_screen(_w, _scale)

        # Track running operation
        self._running      = False
        self._status       = {}
        self._gb_data      = _load_galaxybook_data()  # in-memory galaxybook.json
        self._hw_model     = None   # detected model prefix e.g. "940XHA"
        self._hw_series    = None   # e.g. "book5"
        self._hw_label     = None   # e.g. "Galaxy Book 5"
        self._secure_boot  = None   # True/False/None
        self._distro_str   = "unknown"
        self._kernel_str   = "unknown"
        self._real_user    = None   # logged-in desktop user (we run as root)
        self._real_uid     = None
        self._current_de   = "unknown"  # detected desktop environment
        self._current_proc = None   # subprocess being streamed, if any

        # Per-fix button refs: {key: {"install": btn, "uninstall": btn, "status_lbl": lbl}}
        self._fix_widgets = {}

        self._build_ui()
        self._check_theme_mismatch()
        self.connect("delete-event", self._on_delete_event)

        # Set window icon from bundled SVG
        icon_path = os.path.join(SCRIPT_DIR, "samsung-galaxybook-icon.svg")
        if os.path.exists(icon_path):
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(icon_path, 64, 64)
                self.set_icon(pixbuf)
            except Exception:
                pass

        # Set initial desktop shortcut button label
        self._update_shortcut_button()


        # Initial status load
        GLib.idle_add(self._startup_detect)
        # Wait 500ms after startup to ensure GTK is fully rendered, then print stats
        GLib.timeout_add(500, self._print_diagnostics)

    # ── UI Construction ───────────────────────────────────────────────────────

    def _is_dark_theme(self):
        """Return True if the real user's GTK theme appears to be a dark theme.
        Reads the user's settings.ini directly since the app runs as root via
        pkexec — GTK's runtime settings reflect root's theme, not the user's."""
        _, real_home = self._get_real_user_home()
        if real_home:
            settings_path = os.path.join(real_home, ".config", "gtk-3.0", "settings.ini")
            if os.path.exists(settings_path):
                try:
                    cfg = configparser.ConfigParser()
                    cfg.read(settings_path)
                    section = cfg["Settings"] if "Settings" in cfg else {}
                    prefer_dark = section.get("gtk-application-prefer-dark-theme", "false")
                    if prefer_dark.strip().lower() in ("1", "true"):
                        return True
                    theme_name = section.get("gtk-theme-name", "").lower()
                    return "dark" in theme_name
                except Exception:
                    pass
        # Fallback to GTK runtime settings if we can't read the user's file
        settings = Gtk.Settings.get_default()
        prefer_dark = settings.get_property("gtk-application-prefer-dark-theme")
        if prefer_dark:
            return True
        theme_name = (settings.get_property("gtk-theme-name") or "").lower()
        return "dark" in theme_name

    def _apply_css(self):
        """Apply CSS scaled to screen size, adapting to dark or light GTK theme."""
        sp    = self._sp
        # Match the button padding from the user's preferred CSS
        pad_v = max(4, int(8 * sp))
        pad_h = max(10, int(16 * sp))
        dark  = self._is_dark_theme()

        if dark:
            # Dark theme: dark terminal to match the dark window
            terminal_bg      = "#1a1a2e"
            terminal_fg      = "#e0e0e0"
            card_bg          = "#181c26"
            card_border      = "rgba(255,255,255,0.08)"
            card_border_hover= "rgba(255,255,255,0.15)"
            status_installed = "#22c55e"
            status_missing   = "#606880"
            status_na        = "#c9830a"
            status_untested  = "#e9b84a"
            status_warn_colour = "#e9b84a"  # amber — same as untested
            btn_install_bg   = "rgba(30,111,215,0.14)"
            btn_install_fg   = "#5a9ffd"
            btn_install_bd   = "rgba(30,111,215,0.38)"
            btn_install_hbg  = "rgba(30,111,215,0.26)"
            btn_red_bg       = "rgba(239,68,68,0.12)"
            btn_red_fg       = "#f87171"
            btn_red_bd       = "rgba(239,68,68,0.35)"
            btn_red_hbg      = "rgba(239,68,68,0.22)"
            btn_dis_bg       = "rgba(255,255,255,0.04)"
            btn_dis_fg       = "rgba(255,255,255,0.20)"
            btn_dis_bd       = "rgba(255,255,255,0.06)"
        else:
            # Light theme: black terminal — matches the original screenshot aesthetic
            terminal_bg      = "#1e1e1e"
            terminal_fg      = "#d4d4d4"
            card_bg          = "#ffffff"
            card_border      = "rgba(0,0,0,0.10)"
            card_border_hover= "rgba(0,0,0,0.20)"
            status_installed = "#16a34a"
            status_missing   = "#9ca3af"
            status_na        = "#b45309"
            status_untested  = "#b07800"
            status_warn_colour = "#b07800"  # amber — same as untested
            btn_install_bg   = "rgba(26,111,223,0.07)"
            btn_install_fg   = "#1a6fdf"
            btn_install_bd   = "rgba(26,111,223,0.30)"
            btn_install_hbg  = "rgba(26,111,223,0.15)"
            btn_red_bg       = "rgba(220,38,38,0.06)"
            btn_red_fg       = "#dc2626"
            btn_red_bd       = "rgba(220,38,38,0.28)"
            btn_red_hbg      = "rgba(220,38,38,0.14)"
            btn_dis_bg       = "rgba(0,0,0,0.04)"
            btn_dis_fg       = "rgba(0,0,0,0.25)"
            btn_dis_bd       = "rgba(0,0,0,0.08)"

        css = f"""
    /* ── Terminal ──────────────────────────────────── */
    textview text {{
        background-color: {terminal_bg};
        color: {terminal_fg};
        font-family: "DejaVu Sans Mono", "Monospace", monospace;
    }}
    scrolledwindow {{
    border: none;
    box-shadow: none;
    }}
    textview {{
        background-color: {terminal_bg};
        font-family: "DejaVu Sans Mono", "Monospace", monospace;
    }}

    /* ── Fix card rows ─────────────────────────────── */
    .fix-card {{
        background-color: {card_bg};
        border: 1px solid {card_border};
        border-radius: 8px;
        box-shadow: none;
    }}
    .fix-card:hover {{
        border-color: {card_border_hover};
    }}

    /* ── Status label colour classes ───────────────── */
    .status-installed {{
        color: {status_installed};
        font-weight: bold;
    }}
    .status-not-installed {{
        color: {status_missing};
    }}
    .status-na {{
        color: {status_na};
    }}
    .status-untested {{
        color: {status_untested};
        font-style: italic;
    }}

    /* ── Install (blue ghost) buttons ──────────────── */
    .btn-green {{
        background: {btn_install_bg};
        background-image: none;
        color: {btn_install_fg};
        border: 1px solid {btn_install_bd};
        border-radius: 5px;
        box-shadow: none;
        padding: {pad_v}px {pad_h}px;
        font-weight: 500;
    }}
    .btn-green:hover {{
        background: {btn_install_hbg};
        background-image: none;
        box-shadow: none;
    }}
    .btn-green:active {{
        background: {btn_install_hbg};
        background-image: none;
    }}
    .btn-green:disabled {{
        background: {btn_dis_bg};
        background-image: none;
        color: {btn_dis_fg};
        border-color: {btn_dis_bd};
        box-shadow: none;
    }}

    /* ── Uninstall (red ghost) buttons ─────────────── */
    .btn-red {{
        background: {btn_red_bg};
        background-image: none;
        color: {btn_red_fg};
        border: 1px solid {btn_red_bd};
        border-radius: 5px;
        box-shadow: none;
        padding: {pad_v}px {pad_h}px;
        font-weight: 500;
    }}
    .btn-red:hover {{
        background: {btn_red_hbg};
        background-image: none;
        box-shadow: none;
    }}
    .btn-red:active {{
        background: {btn_red_hbg};
        background-image: none;
    }}
    .btn-red:disabled {{
        background: {btn_dis_bg};
        background-image: none;
        color: {btn_dis_fg};
        border-color: {btn_dis_bd};
        box-shadow: none;
    }}

    /* ── Status bar label — override dim-label opacity ─ */
    #status-bar {{
        opacity: 0.75;
    }}

    /* ── Misc button overrides ─────────────────────── */
    #btn-shortcut {{
        font-weight: normal;
    }}
    #btn-copy, #btn-clear {{
        box-shadow: none;
        padding: {max(2, int(4 * sp))}px {max(8, int(10 * sp))}px;
        font-size: small;
    }}

    /* ── Urgent reboot button ──────────────────────── */
    .btn-reboot-urgent {{
        background: {"rgba(220,60,60,0.25)" if dark else "rgba(200,30,30,0.12)"};
        background-image: none;
        color: {"#ff6b6b" if dark else "#cc0000"};
        border: 2px solid {"rgba(255,80,80,0.7)" if dark else "rgba(200,30,30,0.6)"};
        border-radius: 5px;
        box-shadow: 0 0 {max(4, int(8 * sp))}px {"rgba(255,80,80,0.5)" if dark else "rgba(200,30,30,0.35)"};
        padding: {max(5, int(9 * sp))}px {max(14, int(22 * sp))}px;
        font-weight: bold;
    }}
    .btn-reboot-urgent:hover {{
        background: {"rgba(220,60,60,0.38)" if dark else "rgba(200,30,30,0.22)"};
        background-image: none;
        box-shadow: 0 0 {max(6, int(12 * sp))}px {"rgba(255,80,80,0.7)" if dark else "rgba(200,30,30,0.5)"};
    }}
    .btn-reboot-urgent:disabled {{
        background: rgba(0,0,0,0.04);
        background-image: none;
        color: rgba(0,0,0,0.25);
        border-color: rgba(0,0,0,0.08);
        box-shadow: none;
    }}

    /* ── Install All / Uninstall All — subtle glow ─── */
    .btn-all-green {{
        border: 1px solid {btn_install_bd};
        border-radius: 5px;
        box-shadow: 0 0 {max(3, int(6 * sp))}px {("rgba(90,159,253,0.4)" if dark else "rgba(26,111,223,0.25)")};
        font-weight: 600;
    }}
    .btn-all-green:hover {{
        box-shadow: 0 0 {max(4, int(8 * sp))}px {("rgba(90,159,253,0.6)" if dark else "rgba(26,111,223,0.4)")};
    }}
    .btn-all-green:disabled {{
        box-shadow: none;
    }}
    .btn-all-red {{
        border: 1px solid {btn_red_bd};
        border-radius: 5px;
        box-shadow: 0 0 {max(3, int(6 * sp))}px {("rgba(231,76,60,0.4)" if dark else "rgba(180,30,20,0.25)")};
        font-weight: 600;
    }}
    .btn-all-red:hover {{
        box-shadow: 0 0 {max(4, int(8 * sp))}px {("rgba(231,76,60,0.6)" if dark else "rgba(180,30,20,0.4)")};
    }}
    .btn-all-red:disabled {{
        box-shadow: none;
    }}

    """.encode()

        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        self._status_warn_colour = status_warn_colour
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _scale_font_to_screen(self, logical_width, gtk_scale):
        """Scale the GTK font size based on screen width and GTK scale factor.

        Three cases:
        - DPI > 96 (KDE, real DPI reported): normalize by DPI, scale vs 1745px baseline.
        - DPI = 96, gtk_scale = 1 (100% on HiDPI): logical_w is large, scale font up.
        - DPI = 96, gtk_scale = 2 (165%+ fractional): GTK handles it, leave font alone.

        Font family set by _apply_user_font_settings is preserved — only size changes."""
        try:
            gtk_settings = Gtk.Settings.get_default()
            font_str = gtk_settings.get_property("gtk-font-name")  # e.g. "Inter 11"
            parts = font_str.rsplit(None, 1)
            if len(parts) == 2:
                try:
                    base_size = float(parts[1])
                    font_family = parts[0]
                except ValueError:
                    return
            else:
                return

            screen = Gdk.Screen.get_default()
            dpi = screen.get_resolution() if screen else 96.0
            _BASELINE = 1745

            if dpi > 96.0:
                # KDE / compositors reporting real DPI — normalize and scale
                normalized_width = logical_width / (dpi / 96.0)
                _raw_ratio = normalized_width / _BASELINE
                _damped = 1.0 + (_raw_ratio - 1.0) * 0.4
                _damped = max(0.88, min(1.3, _damped))
            elif gtk_scale == 1:
                # DPI=96, no integer scaling — 100% on HiDPI screen, scale font up
                _raw_ratio = logical_width / _BASELINE
                _damped = 1.0 + (_raw_ratio - 1.0) * 0.4
                _damped = max(0.88, min(1.3, _damped))
            else:
                # DPI=96, gtk_scale=2 — GTK integer doubling handles text, leave alone
                return

            scaled_size = round(base_size * _damped, 1)
            gtk_settings.set_property("gtk-font-name", f"{font_family} {scaled_size}")
        except Exception:
            pass  # Never block startup due to font scaling failure

    def _print_diagnostics(self):
        """Prints screen and window metrics to the terminal after startup."""
        _display = Gdk.Display.get_default()
        _monitor = _display.get_primary_monitor() or _display.get_monitor(0)

        # Get the total raw screen size
        _geom = _monitor.get_geometry() if _monitor else Gdk.Rectangle()

        # Get the GTK reported scale and DPI
        _scale = _monitor.get_scale_factor() if _monitor else 1
        _dpi = Gdk.Screen.get_default().get_resolution()

        # Get the EXACT size the GUI window ended up being
        _alloc_w = self.get_allocated_width()
        _alloc_h = self.get_allocated_height()

        print("\n" + "═"*55)
        print(" 🖥️  DISPLAY & LAYOUT DIAGNOSTICS")
        print("═"*55)
        print(f" Raw Screen Dims  : {_geom.width} x {_geom.height}")
        print(f" Usable Workarea  : {self._logical_w} x {self._logical_h} (Logical)")
        print(f" GTK Scale Factor : {_scale}x")
        print(f" Reported DPI     : {_dpi}")
        print(f" App's Multiplier : {self._sp:.2f}")
        print(f" Final GUI Window : {_alloc_w} x {_alloc_h} (Allocated)")
        print("═"*55 + "\n")

        # Returning False tells GTK to only run this timer once!
        return False

    def _build_ui(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=int(8 * self._sp))
        self._outer = outer
        outer.set_margin_top(int(14 * self._sp))
        outer.set_margin_bottom(int(14 * self._sp))
        outer.set_margin_start(int(12 * self._sp))
        outer.set_margin_end(int(12 * self._sp))
        self.add(outer)

        # ── Header ────────────────────────────────────────────────────────────
        hdr = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=int(6 * self._sp))
        hdr.set_margin_bottom(int(4 * self._sp))

        self._info_lbl = Gtk.Label()
        self._info_lbl.set_halign(Gtk.Align.START)
        self._info_lbl.set_justify(Gtk.Justification.LEFT)
        self._info_lbl.set_line_wrap(True)
        self._info_lbl.set_markup("<span alpha='60%'>Loading…</span>")
        hdr.pack_start(self._info_lbl, False, False, 0)

        self._sb_lbl = Gtk.Label()
        self._sb_lbl.set_halign(Gtk.Align.START)
        self._sb_lbl.set_markup("<span alpha='60%'>Secure Boot: Checking…</span>")
        hdr.pack_start(self._sb_lbl, False, False, 0)

        # ── Model override banner (only shown when --model flag is active) ────
        if OVERRIDE_MODEL:
            self._override_banner = Gtk.Label()
            self._override_banner.set_halign(Gtk.Align.START)
            self._override_banner.set_markup(
                f"<span background='#7a4000' foreground='#ffcc00' weight='bold'"
                f" font_size='small'>  ⚠ TEST MODE — model override: {OVERRIDE_MODEL} — install/uninstall disabled  </span>"
            )
            hdr.pack_start(self._override_banner, False, False, 0)

        outer.pack_start(hdr, False, False, 0)
        # outer.pack_start(Gtk.Separator(), False, False, 0)  # temporarily removed for testing

        # ── Fix rows ──────────────────────────────────────────────────────────
        fixes_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=int(6 * self._sp))
        fixes_box.set_margin_top(int(4 * self._sp))
        fixes_box.set_margin_bottom(int(4 * self._sp))

        fixes_box.set_hexpand(True)
        fixes_box.set_vexpand(False)

        for fix in FIXES:
            row = self._build_fix_row(fix)
            fixes_box.pack_start(row, False, False, 0)

        fixes_scroll = Gtk.ScrolledWindow()
        fixes_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        fixes_scroll.set_propagate_natural_height(False)
        fixes_scroll.add(fixes_box)

        # ── Bottom fade gradient — hints that more fixes are below ────────────
        self._fade = Gtk.DrawingArea()
        self._fade.set_valign(Gtk.Align.END)
        self._fade.set_vexpand(False)
        self._fade.set_hexpand(True)
        self._fade.set_size_request(-1, int(90 * self._sp))
        self._fade.set_can_focus(False)
        self._fade.connect("draw", self._draw_fade)

        # ── Top fade gradient — appears when user has scrolled down ──────────
        self._fade_top = Gtk.DrawingArea()
        self._fade_top.set_valign(Gtk.Align.START)
        self._fade_top.set_vexpand(False)
        self._fade_top.set_hexpand(True)
        self._fade_top.set_size_request(-1, int(60 * self._sp))
        self._fade_top.set_can_focus(False)
        self._fade_top.set_no_show_all(True)  # hidden until user scrolls down
        self._fade_top.connect("draw", self._draw_fade_top)

        fixes_overlay = Gtk.Overlay()
        self._fixes_overlay = fixes_overlay
        fixes_overlay.add(fixes_scroll)
        fixes_overlay.add_overlay(self._fade)
        fixes_overlay.add_overlay(self._fade_top)
        fixes_overlay.set_overlay_pass_through(self._fade, True)
        fixes_overlay.set_overlay_pass_through(self._fade_top, True)

        # Hide fade when scrolled to the bottom, or if content fits without scrolling
        _adj = fixes_scroll.get_vadjustment()
        _adj.connect("value-changed", self._on_fixes_scrolled)
        _adj.connect("changed", self._on_fixes_scrolled)
        self._fixes_adj = _adj

        outer.pack_start(fixes_overlay, True, True, 0)

        # ── Install All / Uninstall All row ───────────────────────────────────
        all_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=int(20 * self._sp))
        all_row.set_margin_top(int(12 * self._sp))
        all_row.set_margin_bottom(int(4 * self._sp))
        all_row.set_halign(Gtk.Align.CENTER)

        self._btn_install_all = Gtk.Button(label="Install All")
        self._btn_install_all.get_style_context().add_class("btn-green")
        self._btn_install_all.get_style_context().add_class("btn-all-green")
        self._btn_install_all.set_tooltip_text("Install all applicable fixes, then rebuild initramfs once")
        self._btn_install_all.set_sensitive(False)
        self._btn_install_all.connect("clicked", self._on_install_all)
        all_row.pack_start(self._btn_install_all, False, False, 0)

        self._btn_uninstall_all = Gtk.Button(label="Uninstall All")
        self._btn_uninstall_all.get_style_context().add_class("btn-red")
        self._btn_uninstall_all.get_style_context().add_class("btn-all-red")
        self._btn_uninstall_all.set_tooltip_text("Uninstall all installed fixes, then rebuild initramfs once")
        self._btn_uninstall_all.set_sensitive(False)
        self._btn_uninstall_all.connect("clicked", self._on_uninstall_all)
        all_row.pack_start(self._btn_uninstall_all, False, False, 0)

        outer.pack_start(all_row, False, False, 0)
        # the fixes area above to redistribute its size when shown/hidden
        term_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        term_box.set_vexpand(False)
        self._term_box = term_box

        # Terminal header — always visible: label + Copy + Clear + Show/Hide Terminal
        term_hdr = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=int(4 * self._sp))
        term_hdr.set_margin_top(int(8 * self._sp))
        term_hdr.set_margin_bottom(int(4 * self._sp))

        term_lbl = Gtk.Label()
        term_lbl.set_markup("<span size='medium' alpha='75%'>Terminal Output</span>")
        term_lbl.set_halign(Gtk.Align.START)
        term_lbl.set_margin_start(int(8 * self._sp))
        term_hdr.pack_start(term_lbl, True, True, 0)

        self._btn_copy = Gtk.Button(label="Copy")
        self._btn_copy.set_name("btn-copy")
        self._btn_copy.set_tooltip_text("Copy terminal output to clipboard")
        self._btn_copy.connect("clicked", self._copy_output)
        self._btn_copy.set_no_show_all(True)
        term_hdr.pack_start(self._btn_copy, False, False, 0)

        self._btn_clear = Gtk.Button(label="Clear")
        self._btn_clear.set_name("btn-clear")
        self._btn_clear.set_tooltip_text("Clear terminal output")
        self._btn_clear.connect("clicked", self._clear_output)
        self._btn_clear.set_no_show_all(True)
        term_hdr.pack_start(self._btn_clear, False, False, 0)

        self._btn_show_output = Gtk.Button(label="Hide Terminal")
        self._btn_show_output.get_style_context().add_class("btn-red")
        self._btn_show_output.set_tooltip_text("Show or hide the terminal output")
        self._btn_show_output.connect("clicked", self._on_toggle_output)
        term_hdr.pack_start(self._btn_show_output, False, False, 0)

        self._term_hdr = term_hdr
        term_box.pack_start(term_hdr, False, False, 0)


        scroll = Gtk.ScrolledWindow()
        self._scroll = scroll
        scroll.set_shadow_type(Gtk.ShadowType.NONE)
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.set_min_content_width(1)  # prevent scroll box from forcing window width
        scroll.set_margin_top(int(6 * self._sp))

        self._terminal_h = max(80, int(self._win_h * 0.39))
        scroll.set_min_content_height(self._terminal_h)
        scroll.set_max_content_height(self._terminal_h)

        scroll.set_hexpand(True)

        self._textview = Gtk.TextView()
        self._textview.set_editable(False)
        self._textview.set_cursor_visible(False)
        self._textview.set_wrap_mode(Gtk.WrapMode.NONE)
        self._textview.set_monospace(True)
        self._textview.set_left_margin(6)
        self._textview.set_right_margin(6)
        self._textview.set_top_margin(4)
        self._textview.set_size_request(1, -1)  # prevent textview driving window width

        buf = self._textview.get_buffer()
        buf.create_tag(TAG_INFO,  foreground="#2ecc71", weight=Pango.Weight.NORMAL)
        buf.create_tag(TAG_WARN,  foreground="#f39c12", weight=Pango.Weight.NORMAL)
        buf.create_tag(TAG_ERROR, foreground="#e74c3c", weight=Pango.Weight.BOLD)
        buf.create_tag(TAG_PLAIN, foreground=None)
        buf.create_tag(TAG_BOLD,  weight=Pango.Weight.BOLD)

        scroll.add(self._textview)
        term_box.pack_start(scroll, False, False, 0)

        outer.pack_start(term_box, False, False, 0)

        # ── Bottom bar ────────────────────────────────────────────────────────
        self._bottom_separator = Gtk.Separator()
        self._bottom_separator.set_no_show_all(True)
        outer.pack_start(self._bottom_separator, False, False, 0)

        bottom = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=int(8 * self._sp))
        bottom.set_margin_top(int(8 * self._sp))

        status_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=int(4 * self._sp))
        status_box.set_margin_start(int(12 * self._sp))

        # Spinner stack: shows a static dot at rest, animates when busy
        self._spinner = Gtk.Spinner()

        spinner_dot = Gtk.Label(label="○")
        spinner_dot.get_style_context().add_class("dim-label")

        self._spinner_stack = Gtk.Stack()
        self._spinner_stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self._spinner_stack.add_named(spinner_dot, "idle")
        self._spinner_stack.add_named(self._spinner, "busy")
        self._spinner_stack.set_visible_child_name("idle")
        status_box.pack_start(self._spinner_stack, False, False, 0)

        self._status_bar = Gtk.Label(label="Ready")
        self._status_bar.set_name("status-bar")
        self._status_bar.set_halign(Gtk.Align.START)
        self._status_bar.get_style_context().add_class("dim-label")
        self._status_bar.set_ellipsize(Pango.EllipsizeMode.END)
        status_box.pack_start(self._status_bar, True, True, 0)

        bottom.pack_start(status_box, True, True, 0)

        self._btn_reboot = Gtk.Button(label="⟳  Reboot Now")
        self._btn_reboot.set_name("btn-reboot")
        self._btn_reboot.get_style_context().add_class("btn-reboot-urgent")
        self._btn_reboot.set_tooltip_text("A reboot is required for changes to take effect")
        self._btn_reboot.connect("clicked", self._on_reboot)
        self._btn_reboot.set_no_show_all(True)  # hidden until reboot is required
        bottom.pack_start(self._btn_reboot, False, False, 0)

        self._btn_desktop_shortcut = Gtk.Button(label="Desktop Shortcut")
        self._btn_desktop_shortcut.set_name("btn-shortcut")
        self._btn_desktop_shortcut.set_tooltip_text("Create a desktop shortcut for this app")
        self._btn_desktop_shortcut.connect("clicked", self._on_desktop_shortcut)
        bottom.pack_start(self._btn_desktop_shortcut, False, False, 0)

        self._btn_fix_theme = Gtk.Button(label="Fix Theme")
        self._btn_fix_theme.set_tooltip_text("Copy your GTK theme to root so the app matches your desktop")
        self._btn_fix_theme.connect("clicked", self._on_fix_theme)
        self._btn_fix_theme.set_no_show_all(True)  # hidden unless theme mismatch detected
        bottom.pack_start(self._btn_fix_theme, False, False, 0)

        outer.pack_start(bottom, False, False, 0)

    def _draw_fade(self, widget, cr):
        """Draw a vertical gradient at the bottom of the fix list to hint scrollability."""
        if not self._fade.get_visible():
            return
        try:
            w = widget.get_allocated_width()
            h = widget.get_allocated_height()
            dark = self._is_dark_theme()
            r, g, b = (0.094, 0.110, 0.149) if dark else (1.0, 1.0, 1.0)
            grad = cairo.LinearGradient(0, 0, 0, h)
            grad.add_color_stop_rgba(0.0, r, g, b, 0.0)
            grad.add_color_stop_rgba(0.35, r, g, b, 0.5)
            grad.add_color_stop_rgba(1.0, r, g, b, 0.97)
            cr.set_source(grad)
            cr.rectangle(0, 0, w, h)
            cr.fill()
        except Exception:
            pass

    def _draw_fade_top(self, widget, cr):
        """Draw a vertical gradient at the top of the fix list when scrolled down."""
        if not self._fade_top.get_visible():
            return
        try:
            w = widget.get_allocated_width()
            h = widget.get_allocated_height()
            dark = self._is_dark_theme()
            r, g, b = (0.094, 0.110, 0.149) if dark else (1.0, 1.0, 1.0)
            grad = cairo.LinearGradient(0, 0, 0, h)
            grad.add_color_stop_rgba(0.0, r, g, b, 0.97)
            grad.add_color_stop_rgba(0.65, r, g, b, 0.5)
            grad.add_color_stop_rgba(1.0, r, g, b, 0.0)
            cr.set_source(grad)
            cr.rectangle(0, 0, w, h)
            cr.fill()
        except Exception:
            pass

    def _on_fixes_scrolled(self, adj):
        """Show/hide top and bottom fade gradients based on scroll position."""
        val = adj.get_value()
        at_top    = val <= 2
        at_bottom = val >= adj.get_upper() - adj.get_page_size() - 2
        if at_bottom:
            self._fade.hide()
        else:
            self._fade.show()
        if at_top:
            self._fade_top.hide()
        else:
            self._fade_top.show()

    def _build_fix_row(self, fix):
        """Build a single fix row with title, description, status and buttons."""
        frame = Gtk.Frame()
        frame.set_shadow_type(Gtk.ShadowType.NONE)
        frame.get_style_context().add_class("fix-card")

        grid = Gtk.Grid()
        grid.set_column_spacing(int(12 * self._sp))
        grid.set_row_spacing(int(2 * self._sp))
        grid.set_margin_top(int(10 * self._sp))
        grid.set_margin_bottom(int(10 * self._sp))
        grid.set_margin_start(int(12 * self._sp))
        grid.set_margin_end(int(12 * self._sp))
        frame.add(grid)

        # Title
        title_lbl = Gtk.Label()
        title_lbl.set_markup(f"<b>{fix['title']}</b>")
        title_lbl.set_halign(Gtk.Align.START)
        title_lbl.set_hexpand(True)
        grid.attach(title_lbl, 0, 0, 1, 1)

        # Description — slightly smaller and dimmed for visual hierarchy
        desc_lbl = Gtk.Label()
        desc_lbl.set_label(fix["desc"])
        desc_lbl.set_halign(Gtk.Align.START)
        desc_lbl.set_hexpand(True)
        desc_lbl.set_line_wrap(True)
        desc_lbl.set_xalign(0)
        desc_lbl.get_style_context().add_class("dim-label")
        grid.attach(desc_lbl, 0, 1, 1, 1)

        # Status label — same small size for consistency
        status_lbl = Gtk.Label(label="Checking…")
        status_lbl.set_halign(Gtk.Align.START)
        status_lbl.set_xalign(0)
        status_lbl.set_line_wrap(True)
        grid.attach(status_lbl, 0, 2, 1, 1)

        # Buttons
        btn_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=int(4 * self._sp))
        btn_box.set_valign(Gtk.Align.CENTER)

        btn_install = Gtk.Button(label="Install")
        btn_install.set_sensitive(False)
        btn_install.get_style_context().add_class("btn-green")
        btn_install.connect("clicked", self._on_install, fix["key"])
        btn_box.pack_start(btn_install, False, False, 0)

        btn_uninstall = Gtk.Button(label="Uninstall")
        btn_uninstall.set_sensitive(False)
        btn_uninstall.get_style_context().add_class("btn-red")
        btn_uninstall.connect("clicked", self._on_uninstall, fix["key"])
        btn_box.pack_start(btn_uninstall, False, False, 0)

        grid.attach(btn_box, 1, 0, 1, 3)

        self._fix_widgets[fix["key"]] = {
            "card":       frame,
            "install":    btn_install,
            "uninstall":  btn_uninstall,
            "status_lbl": status_lbl,
            "desc_lbl":   desc_lbl,
        }

        return frame

    # ── Status refresh ────────────────────────────────────────────────────────

    def _show_error_dialog(self, title, message):
        """Show a prominent modal error dialog."""
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK,
            text=title,
        )
        dialog.format_secondary_markup(message)
        dialog.run()
        dialog.destroy()

    def _check_required_files(self):
        """Check galaxybook.json exists. Returns True if OK."""
        if not os.path.isfile(GALAXYBOOK_JSON):
            GLib.idle_add(
                self._show_error_dialog,
                "Missing file: galaxybook.json",
                "galaxybook.json was not found in the lib/ folder.\n\n"
                "Please reinstall the Samsung Galaxy Book Linux Fixes."
            )
            return False
        return True

    def _get_real_user_info(self):
        """Detect the logged-in desktop user (we run as root via pkexec)."""
        try:
            result = subprocess.run(
                ["loginctl", "list-sessions", "--no-legend"],
                capture_output=True, text=True)
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 4 and parts[3] == "seat0":
                    user = parts[2]
                    uid  = subprocess.run(
                        ["id", "-u", user],
                        capture_output=True, text=True).stdout.strip()
                    return user, uid
        except Exception:
            pass
        return None, None

    def _detect_hardware(self):
        """Read DMI and match against galaxybook.json series prefixes."""
        if OVERRIDE_MODEL:
            model = OVERRIDE_MODEL.upper().lstrip("NP")
        else:
            try:
                vendor = open("/sys/class/dmi/id/sys_vendor").read().strip()
                if "samsung" not in vendor.lower():
                    return None, None, None, False
            except Exception:
                pass
            try:
                product = open("/sys/class/dmi/id/product_name").read().strip()
                model   = product.upper().lstrip("NP")
            except Exception:
                return None, None, None, False

        series_data = self._gb_data.get("series", {})
        for series_key, sdata in series_data.items():
            if sdata.get("blocked"):
                continue
            for prefix in sdata.get("prefixes", []):
                if model.startswith(prefix):
                    return model, series_key, sdata.get("label", series_key), False

        # Model not found in any series — unknown hardware
        return model, None, None, True

    def _detect_secure_boot(self):
        """Return True if Secure Boot is enabled, False if disabled, None if unknown."""
        try:
            lockdown = open("/sys/kernel/security/lockdown").read()
            if "[integrity]" in lockdown or "[confidentiality]" in lockdown:
                return True
            if "[none]" in lockdown:
                return False
        except Exception:
            pass
        try:
            result = subprocess.run(
                ["mokutil", "--sb-state"],
                capture_output=True, text=True, timeout=5)
            if "SecureBoot enabled" in result.stdout:
                return True
            if "SecureBoot disabled" in result.stdout:
                return False
        except Exception:
            pass
        return None

    def _detect_distro_kernel(self):
        """Read distro from /etc/os-release and kernel from uname."""
        kernel = subprocess.run(
            ["uname", "-r"], capture_output=True, text=True).stdout.strip()
        distro = "unknown"
        try:
            with open("/etc/os-release") as f:
                for line in f:
                    if line.startswith("PRETTY_NAME="):
                        distro = line.split("=", 1)[1].strip().strip('"')
                        break
        except Exception:
            pass
        return distro, kernel

    def _detect_de(self):
        """Detect the running desktop environment. Returns lowercase string e.g. 'kde', 'gnome'."""
        # Check environment variables first (reliable when not running as root)
        for var in ["XDG_CURRENT_DESKTOP", "DESKTOP_SESSION"]:
            val = os.environ.get(var, "").lower()
            if val:
                if "kde" in val or "plasma" in val:
                    return "kde"
                if "gnome" in val:
                    return "gnome"
                if "cinnamon" in val:
                    return "cinnamon"
                if "xfce" in val:
                    return "xfce"
                if "mate" in val:
                    return "mate"
        # Fall back to process detection (works when running as root via pkexec)
        if self._real_user:
            try:
                result = subprocess.run(
                    ["pgrep", "-u", self._real_user, "plasmashell"],
                    capture_output=True)
                if result.returncode == 0:
                    return "kde"
                result = subprocess.run(
                    ["pgrep", "-u", self._real_user, "gnome-shell"],
                    capture_output=True)
                if result.returncode == 0:
                    return "gnome"
            except Exception:
                pass
        return "unknown"

    def _startup_detect(self):
        """Run hardware/distro detection then trigger status refresh."""
        if not self._check_required_files():
            GLib.idle_add(self._apply_status, None)
            return

        self._real_user, self._real_uid = self._get_real_user_info()
        self._hw_model, self._hw_series, self._hw_label, hw_unknown = self._detect_hardware()
        self._secure_boot  = self._detect_secure_boot()
        self._distro_str, self._kernel_str = self._detect_distro_kernel()
        self._current_de   = self._detect_de()

        # Reload gb_data fresh in case it changed since module load
        self._gb_data = _load_galaxybook_data()

        self._refresh_status(hw_unknown=hw_unknown)

    def _refresh_status(self, hw_unknown=False):
        """Build status dict from galaxybook.json + file checks. Pure Python, no subprocess."""
        self._set_all_buttons_sensitive(False)
        self._status_bar.set_text("Checking status…")
        self._spinner_stack.set_visible_child_name("busy")
        self._spinner.start()

        def worker():
            ROOT_DIR  = os.path.dirname(SCRIPT_DIR)
            data      = self._gb_data
            fixes_map = data.get("fixes", {})
            order     = data.get("fix_order", list(fixes_map.keys()))

            fixes_status = {}

            for fix_key in order:
                fix_info = fixes_map.get(fix_key, {})
                applicable_models = fix_info.get("applicable_models", {})

                # ── Applicability ─────────────────────────────────────────────
                hw_status = "untested"
                applicable = False
                if self._hw_model and self._hw_series:
                    if applicable_models == "*":
                        # Wildcard — applies to all models
                        hw_status  = "confirmed"
                        applicable = True
                    else:
                        # Check each model prefix in applicable_models dict
                        model_status = None
                        for prefix, status in applicable_models.items():
                            if self._hw_model.startswith(prefix):
                                model_status = status
                                break
                        if model_status is None:
                            # Not in applicable_models at all — not applicable
                            fixes_status[fix_key] = {
                                "status": "not_applicable", "applicable": False,
                                "can_install": False, "can_uninstall": False,
                                "message": "", "warning": "", "hw_status": "not_applicable",
                                "reboot_pending": False,
                            }
                            continue
                        if model_status in ("hidden", "not_applicable"):
                            fixes_status[fix_key] = {
                                "status": "not_applicable", "applicable": False,
                                "can_install": False, "can_uninstall": False,
                                "message": "", "warning": "", "hw_status": model_status,
                                "reboot_pending": False,
                            }
                            continue
                        hw_status  = model_status  # confirmed / likely / untested
                        applicable = True

                # ── Desktop environment check ─────────────────────────────────
                requires_de = fix_info.get("requires_de", "")
                if requires_de:
                    de_match = requires_de.lower() in self._current_de.lower()
                    if not de_match:
                        fixes_status[fix_key] = {
                            "status": "not_applicable", "applicable": False,
                            "can_install": False, "can_uninstall": False,
                            "message": "", "warning": "", "hw_status": "not_applicable",
                            "reboot_pending": False,
                        }
                        continue

                # ── Install status via script_identifier ──────────────────────
                identifiers = fix_info.get("script_identifier", [])
                if identifiers:
                    installed = all(os.path.exists(p) for p in identifiers)
                else:
                    installed = False
                status = "installed" if installed else "not_installed"

                # ── Reboot pending ────────────────────────────────────────────
                reboot_marker = fix_info.get("reboot_marker")
                reboot_pending = bool(reboot_marker and os.path.isfile(reboot_marker))

                # ── Secure Boot blocking ──────────────────────────────────────
                sb_behaviour = fix_info.get("secure_boot_behaviour", "none")
                warning = ""
                can_install   = applicable and not installed and not reboot_pending
                can_uninstall = applicable and installed and not reboot_pending

                if self._secure_boot and sb_behaviour == "block":
                    can_install = False
                    warning = "Secure Boot is enabled — this fix requires Secure Boot to be disabled"
                elif self._secure_boot and sb_behaviour == "warn":
                    warning = "Secure Boot is enabled — this fix may not work correctly"

                # ── Script file existence check ───────────────────────────────
                install_rel   = fix_info.get("install_script", "")
                uninstall_rel = fix_info.get("uninstall_script", "")
                install_path   = os.path.join(ROOT_DIR, install_rel) if install_rel else ""
                uninstall_path = os.path.join(ROOT_DIR, uninstall_rel) if uninstall_rel else ""
                missing = [p for p in [install_path, uninstall_path] if p and not os.path.isfile(p)]
                if missing:
                    can_install = can_uninstall = False
                    warning = "Files missing: " + ", ".join(
                        os.path.relpath(p, SCRIPT_DIR) for p in missing)

                fixes_status[fix_key] = {
                    "status":        status,
                    "applicable":    applicable,
                    "can_install":   can_install,
                    "can_uninstall": can_uninstall,
                    "message":       "",  # reserved for dynamic runtime info only
                    "warning":       warning,
                    "hw_status":     hw_status,
                    "reboot_pending": reboot_pending,
                }

            # ── Overall reboot required ───────────────────────────────────────
            reboot_required = any(
                v.get("reboot_pending") for v in fixes_status.values())

            result = {
                "kernel":         self._kernel_str,
                "distro":         self._distro_str,
                "hardware":       self._hw_series or ("unknown_model" if hw_unknown else "unknown"),
                "hardware_model": self._hw_model or "",
                "unknown_model":  hw_unknown,
                "secure_boot":    self._secure_boot,
                "reboot_required": reboot_required,
                "fixes":          fixes_status,
            }
            GLib.idle_add(self._apply_status, result)

        threading.Thread(target=worker, daemon=True).start()

    def _apply_status(self, data):
        """Apply status dict to the UI (called on GTK main thread)."""
        self._spinner.stop()
        self._spinner_stack.set_visible_child_name("idle")

        if data is None:
            self._status_bar.set_text("Status check failed")
            return

        self._status = data
        kernel  = data.get("kernel", "unknown")
        distro  = data.get("distro", "unknown")
        hw      = data.get("hardware", "unknown")
        model   = data.get("hardware_model", "")
        hw_str  = f"<b>{hw} - {model}</b>" if model and model != "unknown" else f"<b>{hw}</b>"
        self._info_lbl.set_markup(
            f"<span alpha='60%'>Kernel: {kernel}  |  {distro}  |  {hw_str}</span>")

        secure_boot = data.get("secure_boot", None)
        if secure_boot is True:
            self._sb_lbl.set_markup(
                "<span foreground='#e67e22'>●</span>"
                " <span alpha='60%'>Secure Boot: <b>Enabled</b> — some fixes may not work</span>"
            )
        elif secure_boot is False:
            self._sb_lbl.set_markup(
                "<span foreground='#2ecc71'>●</span>"
                " <span alpha='60%'>Secure Boot: Disabled</span>"
            )
        else:
            self._sb_lbl.set_markup("<span alpha='60%'>Secure Boot: Unknown</span>")

        if data.get("unknown_model"):
            self._show_terminal_widgets()
            self._append_output(
                f"⚠  Unrecognised hardware model: {model or 'unknown'}\n\n"
                f"  This model was not found in the compatibility list.\n"
                f"  No fixes are available for unrecognised hardware.\n\n"
                f"  If you believe this is a supported Samsung Galaxy Book,\n"
                f"  please raise an issue on the GitHub repository.\n",
                TAG_WARN
            )
            self._status_bar.set_text("Unrecognised hardware — no fixes available")
            for w in self._fix_widgets.values():
                w["card"].hide()
            self._btn_install_all.set_sensitive(False)
            self._btn_uninstall_all.set_sensitive(False)
            self._set_all_buttons_sensitive(False)
            return

        fixes = data.get("fixes", {})

        for fix in FIXES:
            key  = fix["key"]
            info = fixes.get(key, {})
            st   = info.get("status", "unknown")
            msg  = info.get("message", "")
            warn = info.get("warning", "")
            can_i = info.get("can_install", False)
            can_u = info.get("can_uninstall", False)
            hw_status = info.get("hw_status", "confirmed")

            w = self._fix_widgets.get(key)
            if not w:
                continue

            # webcamfix variants: use description as dynamic message
            status_lbl_set = False
            if key in ("webcamfix_book5", "webcamfix_libcamera") and w.get("desc_lbl"):
                if msg:
                    if " ⚠ " in msg:
                        desc_part, warn_part = msg.split(" ⚠ ", 1)
                        w["desc_lbl"].set_text(desc_part.strip())
                        w["status_lbl"].set_markup(
                            f"<span foreground='{self._status_warn_colour}'>"
                            f"⚠  {warn_part.strip()}</span>"
                        )
                        status_lbl_set = True
                    else:
                        w["desc_lbl"].set_text(msg)
                msg = ""

            # Warning from Secure Boot or missing files
            if warn and not status_lbl_set:
                w["status_lbl"].set_markup(
                    f"<span foreground='{self._status_warn_colour}'>⚠  {warn}</span>")
                status_lbl_set = True

            if not status_lbl_set:
                _reboot_pending = info.get("reboot_pending", False)
                w["status_lbl"].set_text(status_label(st, msg, _reboot_pending))

            # hw_status badge on desc_lbl (shown even when installed)
            if w.get("desc_lbl") and not status_lbl_set:
                desc_text = w["desc_lbl"].get_text()
                for badge in ["⚠ Untested on your model — ", "⚠ Reported working — not verified — "]:
                    desc_text = desc_text.replace(badge, "")
                if hw_status == "untested":
                    w["desc_lbl"].set_text("⚠ Untested on your model — " + desc_text)
                elif hw_status == "likely":
                    w["desc_lbl"].set_text("⚠ Reported working — not verified — " + desc_text)
                else:
                    w["desc_lbl"].set_text(desc_text)

            # CSS status colour
            ctx = w["status_lbl"].get_style_context()
            ctx.remove_class("status-installed")
            ctx.remove_class("status-not-installed")
            ctx.remove_class("status-na")
            ctx.remove_class("status-untested")
            if st == "installed":
                ctx.add_class("status-installed")
            elif st in ("not_applicable", "not_needed"):
                ctx.add_class("status-na")
            elif hw_status in ("untested", "likely"):
                ctx.add_class("status-untested")
            else:
                ctx.add_class("status-not-installed")

            w["install"].set_sensitive(can_i and not self._running and not OVERRIDE_MODEL)
            w["uninstall"].set_sensitive(can_u and not self._running and not OVERRIDE_MODEL)

            if info.get("applicable", True):
                w["card"].show()
            else:
                w["card"].hide()

        reboot_required = data.get("reboot_required", False)
        if reboot_required:
            self._btn_reboot.show()
            self._btn_reboot.set_sensitive(not self._running)
            self._status_bar.set_text("Reboot required")
        else:
            self._btn_reboot.hide()
            self._btn_reboot.set_sensitive(False)
            self._status_bar.set_text("Ready")

        any_installable   = any(fixes.get(f["key"], {}).get("can_install", False) for f in FIXES)
        any_uninstallable = any(fixes.get(f["key"], {}).get("can_uninstall", False) for f in FIXES)
        self._btn_install_all.set_tooltip_text("Install all applicable fixes, then rebuild initramfs once")
        self._btn_uninstall_all.set_tooltip_text("Uninstall all installed fixes, then rebuild initramfs once")
        self._btn_install_all.set_sensitive(any_installable and not self._running and not OVERRIDE_MODEL)
        self._btn_uninstall_all.set_sensitive(any_uninstallable and not self._running and not OVERRIDE_MODEL)

        if self._btn_fix_theme.get_visible() and not self._running:
            self._btn_fix_theme.set_sensitive(True)

        if not getattr(self, "_fixes_height_locked", False):
            def _lock():
                h = self._fixes_overlay.get_allocated_height()
                if h > 1:
                    self._fixes_overlay.set_size_request(-1, h)
                    self._fixes_overlay.set_vexpand(False)
                    self._fixes_height_locked = True
                    self._btn_show_output.set_sensitive(True)
                    return False
                return True
            GLib.timeout_add(50, _lock)

    # ── Button handlers ───────────────────────────────────────────────────────

    def _on_install(self, _btn, fix_key):
        self._run_fix_sequence([fix_key], uninstall=False)

    def _on_uninstall(self, _btn, fix_key):
        self._run_fix_sequence([fix_key], uninstall=True)

    def _on_install_all(self, _btn):
        keys = [
            f["key"] for f in FIXES
            if self._status and
               self._status.get("fixes", {}).get(f["key"], {}).get("can_install", False)
        ]
        self._run_fix_sequence(keys, uninstall=False, skip_initramfs=True)

    def _on_uninstall_all(self, _btn):
        keys = [
            f["key"] for f in FIXES
            if self._status and
               self._status.get("fixes", {}).get(f["key"], {}).get("can_uninstall", False)
        ]
        self._run_fix_sequence(keys, uninstall=True, skip_initramfs=True)

    def _on_reboot(self, _btn):
        """Confirm and reboot the system."""
        if not self._confirm("Reboot now?\n\nAll unsaved work will be lost."):
            return
        release_lock()
        subprocess.run(["reboot"])

    def _confirm(self, message):
        """Show a confirmation dialog. Returns True if user clicks OK."""
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text=message,
        )
        response = dialog.run()
        dialog.destroy()
        return response == Gtk.ResponseType.OK

    # ── Fix execution ─────────────────────────────────────────────────────────

    def _run_fix_sequence(self, keys, uninstall=False, skip_initramfs=False):
        """Run a list of fixes sequentially in a background thread."""
        self._running = True
        self._set_all_buttons_sensitive(False)
        self._btn_reboot.set_sensitive(False)
        self._spinner_stack.set_visible_child_name("busy")
        self._spinner.start()
        if not self._scroll.get_visible():
            self.resize(self.get_allocated_width(),
                        self.get_allocated_height() + self._terminal_h)
            GLib.idle_add(self._show_terminal_widgets)

        ROOT_DIR   = os.path.dirname(SCRIPT_DIR)
        fix_titles = {f["key"]: f["title"] for f in FIXES}
        fixes_map  = self._gb_data.get("fixes", {})
        results    = {}  # key -> "ok" | "failed" | "skipped"

        def _check_webcam_not_in_use():
            """Return True if webcam is safe to modify, False if in use."""
            led_paths = [
                "/sys/class/leds/OVTI02E1_00::privacy_led/brightness",
                "/sys/class/leds/OVTI02C1_00::privacy_led/brightness",
            ]
            for led in led_paths:
                try:
                    if open(led).read().strip() == "1":
                        return False
                except Exception:
                    pass
            return True

        def _rebuild_initramfs():
            GLib.idle_add(self._append_output,
                          f"\n{'─'*60}\nRebuilding initramfs\n{'─'*60}\n", TAG_BOLD)
            GLib.idle_add(self._status_bar.set_text, "Rebuilding initramfs…")
            if shutil.which("dracut"):
                cmd = ["dracut", "--force"]
            elif shutil.which("update-initramfs"):
                cmd = ["update-initramfs", "-u", "-k", "all"]
            elif shutil.which("mkinitcpio"):
                cmd = ["mkinitcpio", "-P"]
            else:
                GLib.idle_add(self._append_output,
                              "  ⚠ Could not detect initramfs tool — rebuild manually.\n",
                              TAG_WARN)
                return False
            try:
                proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, bufsize=1)
                for line in proc.stdout:
                    GLib.idle_add(self._append_output_line, line)
                proc.wait()
                if proc.returncode == 0:
                    GLib.idle_add(self._append_output,
                                  "  ✓ initramfs rebuilt successfully\n", TAG_INFO)
                    return True
                else:
                    GLib.idle_add(self._append_output,
                                  f"  ⚠ initramfs rebuild exited with code {proc.returncode}\n",
                                  TAG_WARN)
                    return False
            except Exception as e:
                GLib.idle_add(self._append_output,
                              f"  ⚠ initramfs rebuild failed: {e}\n", TAG_WARN)
                return False

        def worker():
            need_initramfs = False

            for key in keys:
                fix_info = fixes_map.get(key, {})
                title    = fix_titles.get(key, key)
                action   = "Uninstalling" if uninstall else "Installing"
                GLib.idle_add(self._append_output,
                              f"\n{'─'*60}\n{action}: {title}\n{'─'*60}\n",
                              TAG_BOLD)
                GLib.idle_add(self._status_bar.set_text, f"{action} {title}…")

                # Webcam toggle — check camera not in use before proceeding
                if key == "webcamtoggle":
                    if not _check_webcam_not_in_use():
                        GLib.idle_add(self._append_output,
                                      "  ⚠ Webcam is currently in use — cannot modify toggle.\n"
                                      "  Close all applications using the camera and try again.\n",
                                      TAG_WARN)
                        results[key] = "skipped"
                        continue

                # Resolve script path from galaxybook.json
                script_rel = (fix_info.get("uninstall_script") if uninstall
                              else fix_info.get("install_script"))
                if not script_rel:
                    GLib.idle_add(self._append_output,
                                  f"  ✗ No script path found for {key} in galaxybook.json\n",
                                  TAG_ERROR)
                    results[key] = "failed"
                    continue

                script_path = os.path.join(ROOT_DIR, script_rel)
                if not os.path.isfile(script_path):
                    GLib.idle_add(self._append_output,
                                  f"  ✗ Script not found: {script_path}\n", TAG_ERROR)
                    results[key] = "failed"
                    continue

                env = os.environ.copy()
                if self._hw_model:
                    env["SAMSUNG_GALAXYBOOK_MODEL"] = self._hw_model
                # Tell scripts to skip their own initramfs rebuild —
                # the GUI handles it once at the end of the sequence.
                # Write a sudoers drop-in so sudo sub-processes inside scripts
                # also inherit SKIP_INITRAMFS (sudo strips env by default).
                env["SKIP_INITRAMFS"] = "1"
                _sudoers_dropin = "/etc/sudoers.d/galaxybook-skip-initramfs"
                try:
                    with open(_sudoers_dropin, "w") as _sf:
                        _sf.write("Defaults env_keep += \"SKIP_INITRAMFS\"\n")
                    import stat as _stat
                    os.chmod(_sudoers_dropin, _stat.S_IRUSR | _stat.S_IRGRP)
                except Exception:
                    pass

                try:
                    proc = subprocess.Popen(
                        ["bash", script_path],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, bufsize=1, env=env,
                        start_new_session=True)
                    self._current_proc = proc
                    for line in proc.stdout:
                        GLib.idle_add(self._append_output_line, line)
                    proc.wait()
                    self._current_proc = None
                    if proc.returncode != 0:
                        results[key] = "failed"
                        GLib.idle_add(self._append_output,
                                      f"  ✗ {title} exited with code {proc.returncode}\n",
                                      TAG_ERROR)
                    else:
                        results[key] = "ok"
                        # Track if any successful fix needs initramfs rebuild
                        if fix_info.get("requires_initramfs", False):
                            need_initramfs = True
                        # Write or remove reboot marker — GUI owns this, not the scripts
                        reboot_marker = fix_info.get("reboot_marker")
                        needs_reboot = False
                        if reboot_marker:
                            try:
                                os.makedirs("/tmp", exist_ok=True)
                                with open(reboot_marker, "w"):
                                    pass
                                needs_reboot = True
                            except Exception:
                                pass
                        _sep = "─" * 60
                        _action_word = "uninstalled" if uninstall else "installed"
                        if needs_reboot:
                            _msg = f"  ✓ {title} {_action_word} — reboot required"
                        else:
                            _msg = f"  ✓ {title} {_action_word} — no reboot needed"
                        GLib.idle_add(self._append_output,
                                      f"\n{_sep}\n{_msg}\n{_sep}\n\n\n",
                                      TAG_PLAIN)
                except Exception as e:
                    results[key] = "failed"
                    GLib.idle_add(self._append_output,
                                  f"  ✗ Failed to run {title}: {e}\n", TAG_ERROR)

            # ── Initramfs rebuild — once at end if any fix needed it ──────────
            # Scripts always skip their own rebuild (SKIP_INITRAMFS=1 above),
            # so the GUI owns this exactly once per sequence.
            initramfs_ok = None
            if need_initramfs:
                initramfs_ok = _rebuild_initramfs()

            # ── Per-fix summary ───────────────────────────────────────────────
            if len(keys) > 1:
                action_word = "Uninstall" if uninstall else "Install"
                GLib.idle_add(self._append_output,
                              f"\n{'═'*60}\n  {action_word} All — Results\n{'═'*60}\n",
                              TAG_BOLD)
                for key in keys:
                    t      = fix_titles.get(key, key)
                    result = results.get(key, "skipped")
                    if result == "ok":
                        GLib.idle_add(self._append_output, f"  ✓  {t}\n", TAG_INFO)
                    elif result == "failed":
                        GLib.idle_add(self._append_output, f"  ✗  {t} — FAILED\n", TAG_ERROR)
                    else:
                        GLib.idle_add(self._append_output, f"  ─  {t} — skipped\n", TAG_PLAIN)
                if initramfs_ok is True:
                    GLib.idle_add(self._append_output, "  ✓  initramfs rebuilt\n", TAG_INFO)
                elif initramfs_ok is False:
                    GLib.idle_add(self._append_output,
                                  "  ⚠  initramfs rebuild failed — check output above\n", TAG_WARN)
                failed = [fix_titles.get(k, k) for k, v in results.items() if v == "failed"]
                if failed:
                    GLib.idle_add(self._append_output,
                                  f"\n  ⚠ {len(failed)} fix(es) reported errors — "
                                  f"check output above for details.\n", TAG_WARN)
                GLib.idle_add(self._append_output, f"{'═'*60}\n", TAG_BOLD)

            GLib.idle_add(self._on_sequence_complete)

        threading.Thread(target=worker, daemon=True).start()

    def _on_sequence_complete(self):
        """Called on GTK thread when a fix sequence finishes."""
        self._running = False
        self._spinner.stop()
        self._spinner_stack.set_visible_child_name("idle")
        self._status_bar.set_text("Done — refreshing status…")
        # Remove sudoers drop-in now that scripts are done
        try:
            os.remove("/etc/sudoers.d/galaxybook-skip-initramfs")
        except Exception:
            pass
        # Reload gb_data in case galaxybook.json changed, then refresh
        self._gb_data = _load_galaxybook_data()
        self._refresh_status()

    # ── Output helpers ────────────────────────────────────────────────────────

    def _append_output_line(self, line):
        """Append a line from bash output, colour-coding by prefix."""
        # Strip ANSI escape codes
        line_clean = re.sub(r'\x1b\[[0-9;]*m', '', line)

        if "[INFO]" in line_clean:
            tag = TAG_INFO
        elif "[WARN]" in line_clean:
            tag = TAG_WARN
        elif "[ERROR]" in line_clean:
            tag = TAG_ERROR
        elif "══" in line_clean:
            tag = TAG_BOLD
        else:
            tag = TAG_PLAIN

        self._append_output(line_clean, tag)

    def _append_output(self, text, tag=TAG_PLAIN):
        """Append text with a colour tag to the output buffer."""
        buf  = self._textview.get_buffer()
        end  = buf.get_end_iter()
        buf.insert_with_tags_by_name(end, text, tag)
        # Defer scroll until GTK has recalculated layout bounds
        def _scroll_to_bottom():
            adj = self._textview.get_parent().get_vadjustment()
            adj.set_value(adj.get_upper() - adj.get_page_size())
            return False
        GLib.idle_add(_scroll_to_bottom)

    def _copy_output(self, _widget):
        """Copy the full terminal output text to the clipboard."""
        buf   = self._textview.get_buffer()
        start = buf.get_start_iter()
        end   = buf.get_end_iter()
        text  = buf.get_text(start, end, include_hidden_chars=False)
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_text(text, -1)
        clipboard.store()

    def _clear_output(self, _widget):
        """Clear the terminal output buffer."""
        self._textview.get_buffer().set_text("")

    def _on_delete_event(self, _widget, _event):
        """Intercept window close before the WM animation fires."""
        if self._running:
            dialog = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.WARNING,
                buttons=Gtk.ButtonsType.NONE,
                text="Operation in progress",
            )
            dialog.format_secondary_text(
                "An install or uninstall is currently running.\n"
                "Closing now will immediately kill the operation and may leave\n"
                "the system in an incomplete state.\n\n"
                "In most cases, re-running the fix will recover — but the\n"
                "Fingerprint Fix may require manually reinstalling libfprint\n"
                "if closed mid-install.\n\n"
                "Are you sure you want to close?"
            )
            dialog.add_button("Yes",                   Gtk.ResponseType.YES)
            dialog.add_button("NO — keep running",     Gtk.ResponseType.NO)
            dialog.set_default_response(Gtk.ResponseType.NO)
            response = dialog.run()
            dialog.destroy()
            if response != Gtk.ResponseType.YES:
                return True  # block the close

        if self._current_proc is not None:
            try:
                import signal
                os.killpg(os.getpgid(self._current_proc.pid), signal.SIGKILL)
            except Exception:
                try:
                    self._current_proc.kill()
                except Exception:
                    pass
        release_lock()
        sys.exit(0)

    # ── Theme fix ─────────────────────────────────────────────────────────────

    def _get_real_user_home(self):
        """Detect the logged-in desktop user via loginctl (same logic as webcam-toggle.sh)."""
        try:
            result = subprocess.run(
                ["loginctl", "list-sessions", "--no-legend"],
                capture_output=True, text=True
            )
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 4 and parts[3] == "seat0":
                    username = parts[2]
                    home = pwd.getpwnam(username).pw_dir
                    return username, home
        except Exception:
            pass
        return None, None

    # ── Output Toggle ────────────────────────────────────────────────────────

    def _show_terminal_widgets(self):
        """Show terminal widgets — called via GLib.idle_add after resize()
        so the window is fully expanded before GTK lays out the new widgets."""
        self._scroll.set_min_content_height(self._terminal_h)
        self._bottom_separator.hide()
        self._scroll.show()
        self._textview.show()
        self._btn_copy.show()
        self._btn_clear.show()
        self._btn_show_output.get_style_context().remove_class("btn-green")
        self._btn_show_output.get_style_context().add_class("btn-red")
        self._btn_show_output.set_label("Hide Terminal")
        return False  # one-shot idle

    def _on_toggle_output(self, _widget):
        """Show or hide the terminal output box."""
        current_w = self.get_allocated_width()
        current_h = self.get_allocated_height()
        if self._scroll.get_visible():
            self._scroll.set_min_content_height(0)
            self._scroll.hide()
            self._btn_copy.hide()
            self._btn_clear.hide()
            self._bottom_separator.show()
            self._btn_show_output.get_style_context().remove_class("btn-red")
            self._btn_show_output.get_style_context().add_class("btn-green")
            self._btn_show_output.set_label("Show Terminal")
            self.resize(current_w, current_h - self._terminal_h)
        else:
            GLib.idle_add(self._show_terminal_widgets)

    # ── Desktop Shortcut ─────────────────────────────────────────────────────

    def _get_desktop_file_path(self):
        """Return the path to the .desktop file for the logged-in user, or None."""
        try:
            result = subprocess.run(
                ["loginctl", "list-sessions", "--no-legend"],
                capture_output=True, text=True
            )
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 4 and parts[3] == "seat0":
                    home = pwd.getpwnam(parts[2]).pw_dir
                    return os.path.join(
                        home, ".local", "share", "applications",
                        "samsung-galaxybook-fixes.desktop"
                    )
        except Exception:
            pass
        return None

    def _get_shortcut_paths(self):
        """Return (user_home, desktop_file_path, desktop_link_path, icon_path)
        for the logged-in seat0 user, or None if no user found."""
        username, home = self._get_real_user_home()
        if not home:
            return None
        app_dir   = os.path.join(home, ".local", "share", "applications")
        icons_dir = os.path.join(home, ".local", "share", "icons")
        desktop_dir = os.path.join(home, "Desktop")
        # XDG_DESKTOP_DIR may differ — try xdg-user-dir
        try:
            result = subprocess.run(
                ["sudo", "-u", username, "xdg-user-dir", "DESKTOP"],
                capture_output=True, text=True
            )
            xdg = result.stdout.strip()
            if xdg:
                desktop_dir = xdg
        except Exception:
            pass
        app_file    = os.path.join(app_dir, "samsung-galaxybook-fixes.desktop")
        desktop_link = os.path.join(desktop_dir, "samsung-galaxybook-fixes.desktop")
        icon_src    = os.path.join(SCRIPT_DIR, "samsung-galaxybook-icon.svg")
        icon_dst    = os.path.join(icons_dir, "samsung-galaxybook-icon.svg")
        return username, home, app_file, desktop_link, icon_src, icon_dst, app_dir, icons_dir, desktop_dir

    def _update_shortcut_button(self):
        """Set button label and colour based on whether the .desktop file exists."""
        desktop_file = self._get_desktop_file_path()
        ctx = self._btn_desktop_shortcut.get_style_context()
        ctx.remove_class("btn-green")
        ctx.remove_class("btn-red")
        if desktop_file and os.path.exists(desktop_file):
            self._btn_desktop_shortcut.set_label("Remove Shortcut")
            self._btn_desktop_shortcut.set_tooltip_text("Remove the desktop shortcut for this app")
            ctx.add_class("btn-red")
        else:
            self._btn_desktop_shortcut.set_label("Desktop Shortcut")
            self._btn_desktop_shortcut.set_tooltip_text("Create a desktop shortcut for this app")
            ctx.add_class("btn-green")

    def _on_desktop_shortcut(self, _widget):
        """Create or remove the desktop shortcut."""
        paths = self._get_shortcut_paths()
        if not paths:
            self._show_error("Could not detect the logged-in user session.")
            return
        username, home, app_file, desktop_link, icon_src, icon_dst, app_dir, icons_dir, desktop_dir = paths

        if os.path.exists(app_file):
            # Remove shortcut
            try:
                os.remove(app_file)
                if os.path.exists(desktop_link):
                    os.remove(desktop_link)
                self._update_shortcut_button()
                self._status_bar.set_text("Desktop shortcut removed")
            except Exception as e:
                self._show_error(f"Failed to remove shortcut: {e}")
        else:
            # Create shortcut
            try:
                os.makedirs(app_dir, exist_ok=True)
                os.makedirs(desktop_dir, exist_ok=True)

                # Copy icon to user icons dir if it exists
                icon_path_in_desktop = icon_src  # fallback to source location
                if os.path.exists(icon_src):
                    os.makedirs(icons_dir, exist_ok=True)
                    shutil.copy2(icon_src, icon_dst)
                    # Fix ownership to real user
                    uid = pwd.getpwnam(username).pw_uid
                    gid = pwd.getpwnam(username).pw_gid
                    os.chown(icon_dst, uid, gid)
                    icon_path_in_desktop = icon_dst

                # Build Exec path — script lives in SCRIPT_DIR
                gui_script = os.path.join(SCRIPT_DIR, "..", "samsung-galaxybook-gui")
                gui_script = os.path.realpath(gui_script)

                desktop_content = (
                    "[Desktop Entry]\n"
                    "Version=1.0\n"
                    "Type=Application\n"
                    "Name=Samsung Galaxy Book Fixes\n"
                    "Comment=Configure Samsung Galaxy Book hardware fixes\n"
                    f"Exec=bash {gui_script}\n"
                    f"Icon={icon_path_in_desktop}\n"
                    "Terminal=false\n"
                    "Categories=System;Settings;\n"
                    "Keywords=samsung;galaxybook;hardware;fixes;\n"
                )

                # Write to applications dir
                with open(app_file, "w") as f:
                    f.write(desktop_content)

                # Fix ownership
                uid = pwd.getpwnam(username).pw_uid
                gid = pwd.getpwnam(username).pw_gid
                os.chown(app_file, uid, gid)
                os.chmod(app_file, 0o755)

                # Copy to Desktop and mark as trusted
                shutil.copy2(app_file, desktop_link)
                os.chown(desktop_link, uid, gid)
                os.chmod(desktop_link, 0o755)
                # Mark trusted so KDE/GNOME show it without a warning
                try:
                    subprocess.run(
                        ["gio", "set", desktop_link,
                         "metadata::trusted", "true"],
                        env={**os.environ, "HOME": home,
                             "DBUS_SESSION_BUS_ADDRESS":
                             f"unix:path=/run/user/{uid}/bus"},
                        capture_output=True
                    )
                except Exception:
                    pass

                self._update_shortcut_button()
                self._status_bar.set_text("Desktop shortcut created")
            except Exception as e:
                self._show_error(f"Failed to create shortcut: {e}")

    def _show_error(self, message):
        """Show a simple error dialog."""
        dlg = Gtk.MessageDialog(
            transient_for=self, flags=0,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text=message,
        )
        dlg.run()
        dlg.destroy()

    def _check_theme_mismatch(self):
        """Show the Fix Theme button if the user's GTK theme differs from root's.
        Only compares theme-relevant keys — ignores font/DPI which we handle ourselves."""
        _, real_home = self._get_real_user_home()
        if not real_home:
            return

        user_settings = os.path.join(real_home, ".config", "gtk-3.0", "settings.ini")
        root_settings = "/root/.config/gtk-3.0/settings.ini"

        if not os.path.exists(user_settings):
            return  # user has no custom theme — nothing to copy

        # Keys that actually affect appearance (not font/DPI which we scale ourselves)
        THEME_KEYS = {
            "gtk-theme-name", "gtk-icon-theme-name", "gtk-cursor-theme-name",
            "gtk-cursor-theme-size", "gtk-application-prefer-dark-theme",
            "gtk-button-images", "gtk-menu-images", "gtk-enable-animations",
        }

        def _read_theme_keys(path):
            cfg = configparser.ConfigParser()
            try:
                cfg.read(path)
                section = cfg["Settings"] if "Settings" in cfg else {}
                return {k: v for k, v in section.items() if k in THEME_KEYS}
            except Exception:
                return {}

        user_keys = _read_theme_keys(user_settings)
        root_keys = _read_theme_keys(root_settings) if os.path.exists(root_settings) else {}

        if user_keys and user_keys == root_keys:
            return  # theme keys already match — keep button hidden

        # Theme is missing or differs — show the button
        self._btn_fix_theme.show()

    def _on_fix_theme(self, _widget):
        """Write only the theme-relevant keys from the user's settings.ini to
        root's settings.ini. Avoids copying KDE-generated files (bookmarks,
        assets, window_decorations.css etc.) that root doesn't need."""
        _, real_home = self._get_real_user_home()
        if not real_home:
            err = Gtk.MessageDialog(
                transient_for=self, flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text="Could not detect the logged-in user session.",
            )
            err.run()
            err.destroy()
            return

        user_settings = os.path.join(real_home, ".config", "gtk-3.0", "settings.ini")
        root_settings = "/root/.config/gtk-3.0/settings.ini"

        THEME_KEYS = {
            "gtk-theme-name", "gtk-icon-theme-name", "gtk-cursor-theme-name",
            "gtk-cursor-theme-size", "gtk-application-prefer-dark-theme",
            "gtk-button-images", "gtk-menu-images", "gtk-enable-animations",
        }

        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Sync GTK theme to root?",
        )
        dialog.format_secondary_text(
            "This will copy your GTK theme settings to root so the app "
            "matches your desktop theme.\n\n"
            "The app will need to restart for the theme to take effect."
        )
        response = dialog.run()
        dialog.destroy()

        if response != Gtk.ResponseType.OK:
            return

        try:
            root_gtk = "/root/.config/gtk-3.0"

            if not os.path.exists(root_gtk):
                # Root has no gtk-3.0 folder at all — safe to copy everything
                shutil.copytree(
                    os.path.join(real_home, ".config", "gtk-3.0"),
                    root_gtk
                )
            else:
                # Root already has a gtk-3.0 folder — only merge THEME_KEYS
                # into the existing settings.ini to avoid overwriting KDE-managed
                # files like window_decorations.css, assets/ etc.
                user_cfg = configparser.ConfigParser()
                user_cfg.read(user_settings)
                user_section = user_cfg["Settings"] if "Settings" in user_cfg else {}
                theme_values = {k: v for k, v in user_section.items() if k in THEME_KEYS}

                if not theme_values:
                    raise ValueError("No theme keys found in user settings.ini")

                root_cfg = configparser.ConfigParser()
                root_cfg.read(root_settings)
                if "Settings" not in root_cfg:
                    root_cfg["Settings"] = {}
                for k, v in theme_values.items():
                    root_cfg["Settings"][k] = v
                with open(root_settings, "w") as f:
                    root_cfg.write(f)

            self._btn_fix_theme.hide()
        except Exception as e:
            err = Gtk.MessageDialog(
                transient_for=self, flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text=f"Failed to sync theme: {e}",
            )
            err.run()
            err.destroy()
            return

        # Offer restart
        restart_dlg = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.YES_NO,
            text="Theme installed.",
        )
        restart_dlg.format_secondary_text("Restart the app now to apply the theme?")
        restart_response = restart_dlg.run()
        restart_dlg.destroy()

        if restart_response == Gtk.ResponseType.YES:
            release_lock()
            os.execv(sys.executable, [sys.executable] + sys.argv)

    # ── Utility ───────────────────────────────────────────────────────────────

    def _set_all_buttons_sensitive(self, sensitive):
        """Enable or disable all install/uninstall buttons and the Fix Theme button."""
        for w in self._fix_widgets.values():
            w["install"].set_sensitive(sensitive)
            w["uninstall"].set_sensitive(sensitive)
        # Disable Fix Theme during operations — restarting mid-fix would be destructive
        if self._btn_fix_theme.get_visible():
            self._btn_fix_theme.set_sensitive(sensitive)
        # Install All / Uninstall All — re-enable only when status has been refreshed
        # (handled by _apply_status), so here we only disable them
        if not sensitive:
            self._btn_install_all.set_sensitive(False)
            self._btn_uninstall_all.set_sensitive(False)


# ── Entry point ───────────────────────────────────────────────────────────────

def acquire_lock():
    """Ensure only one instance runs at a time using a PID file.
    Shows a GTK error dialog and exits if another instance is detected."""
    if os.path.exists(LOCK_FILE):
        try:
            with open(LOCK_FILE) as f:
                existing_pid = int(f.read().strip())
            # Check if that PID is actually still running
            os.kill(existing_pid, 0)
            # It's alive — show error dialog and exit
            # Need GTK initialised first for the dialog
            dialog = Gtk.MessageDialog(
                transient_for=None,
                flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text="Samsung Galaxy Book — Linux Fixes is already running.",
            )
            dialog.format_secondary_text(f"Process ID: {existing_pid}")
            dialog.run()
            dialog.destroy()
            sys.exit(1)
        except (ValueError, ProcessLookupError):
            # Stale lockfile — process no longer exists, remove it and continue
            os.remove(LOCK_FILE)
        except PermissionError:
            # Process exists but owned by another user — treat as running
            dialog = Gtk.MessageDialog(
                transient_for=None,
                flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text="Samsung Galaxy Book — Linux Fixes is already running.",
            )
            dialog.format_secondary_text(f"Process ID: {existing_pid}")
            dialog.run()
            dialog.destroy()
            sys.exit(1)

    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))


def release_lock():
    """Remove the PID lockfile on exit."""
    try:
        os.remove(LOCK_FILE)
    except FileNotFoundError:
        pass


def _apply_user_font_settings():
    """Read the logged-in user's GTK/Xft font settings and apply them to root's session.
    This ensures correct font size when fractional scaling is active.

    After applying the user's base font, the size is preserved but the family
    is switched to Inter if it is installed — falling back to whatever the user's
    system font is if Inter is not available."""
    try:
        result = subprocess.run(
            ["loginctl", "list-sessions", "--no-legend"],
            capture_output=True, text=True
        )
        user_name = None
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[3] == "seat0":
                user_name = parts[2]
                break
        if not user_name:
            return

        home = pwd.getpwnam(user_name).pw_dir
        settings_ini = os.path.join(home, ".config", "gtk-3.0", "settings.ini")

        gtk_settings = Gtk.Settings.get_default()

        # Step 1 — read gtk-font-name from user's settings.ini (gets us the right size)
        if os.path.exists(settings_ini):
            cfg = configparser.ConfigParser()
            cfg.read(settings_ini)
            font_name = cfg.get("Settings", "gtk-font-name", fallback=None)
            if font_name:
                gtk_settings.set_property("gtk-font-name", font_name)

        # Step 2 — switch family to Inter if available, preserving the point size
        inter_family = _resolve_ui_font()
        if inter_family:
            current = gtk_settings.get_property("gtk-font-name")  # e.g. "Noto Sans 11"
            parts   = current.rsplit(None, 1)
            if len(parts) == 2:
                try:
                    size = float(parts[1])
                    gtk_settings.set_property("gtk-font-name", f"{inter_family} {size}")
                except ValueError:
                    pass  # size token not numeric — leave font unchanged

        # DPI is handled by the Wayland compositor — do not override
    except Exception:
        pass  # Never block startup due to font detection failure


def main():
    acquire_lock()
    _apply_user_font_settings()

    app = SamsungFixesApp()

    # 1. Flicker-Free setup
    app._scroll.set_no_show_all(True)
    app._bottom_separator.show()

    app._btn_show_output.get_style_context().remove_class("btn-red")
    app._btn_show_output.get_style_context().add_class("btn-green")
    app._btn_show_output.set_label("Show Terminal")
    app._btn_show_output.set_sensitive(False)

    # 2. Position and size the window
    # Get available desktop area for positioning.
    _display = Gdk.Display.get_default()
    _monitor = _display.get_primary_monitor()
    if _monitor is None:
        _best = 0
        for _i in range(_display.get_n_monitors()):
            _m = _display.get_monitor(_i)
            _g = _m.get_geometry()
            if _g.width * _g.height > _best:
                _best = _g.width * _g.height
                _monitor = _m

    # Use get_geometry() for positioning on non-Ubuntu — get_workarea() on KDE
    # returns values in a mixed coordinate space at high GTK scale factors,
    # giving incorrect dimensions (e.g. 1188x703 instead of 1440x900).
    # Ubuntu still uses get_workarea() as get_geometry() is broken there.
    if _monitor:
        if app._is_ubuntu:
            _wa = _monitor.get_workarea()
            _work_x, _work_y = _wa.x, _wa.y
            _work_w, _work_h = _wa.width, _wa.height
        else:
            _geom = _monitor.get_geometry()
            _work_x, _work_y = _geom.x, _geom.y
            _work_w, _work_h = _geom.width, _geom.height
    else:
        _work_x, _work_y = 0, 0
        _work_w, _work_h = app._logical_w, app._logical_h

    # Centre horizontally
    pos_x = _work_x + int((_work_w / 2) - (app._win_w / 2))

    # Detect KDE for Y offset adjustment
    _is_kde = subprocess.run(["pgrep", "plasmashell"], capture_output=True).returncode == 0

    _full_h = app._win_h + app._terminal_h
    # Use a fixed panel buffer rather than scaling by _sp — at high scale factors
    # _sp shrinks too much and the offset becomes ineffective.
    _y_offset = 60 if _is_kde else 30

    # Clamp full_h so centring maths never goes negative
    _clamped_full_h = min(_full_h, _work_h - 10)
    pos_y = _work_y + max(0, int((_work_h / 2) - (_clamped_full_h / 2)) - _y_offset)

    app.move(pos_x, pos_y)
    print(f"\nWindow Position  : x={pos_x}, y={pos_y}, y_offset={_y_offset}")
    app.set_default_size(app._win_w, app._win_h)

    app.show_all()
    Gtk.main()

def screenshot_mode(version, out_path):
    """Render a curated screenshot of the GUI and save it to out_path.

    Called headlessly from galaxybook-tools-gui after the version bump so the
    title bar always shows the correct version that was just written to disk.

    Usage: python3 samsung-galaxybook-gui.py --screenshot 2.7 /path/to/out.png
    """
    try:
        from PIL import Image, ImageDraw
        import cairo as _cairo
    except ImportError as e:
        print(f"[screenshot] Missing dependency: {e}")
        print("[screenshot] Install with: pip install Pillow")
        sys.exit(1)

    # ── Fake status payload ───────────────────────────────────────────────────
    # Speaker Fix = not_installed  → shows blue Install button + reboot button
    # Webcam Toggle = not_installed → shows blue Install button
    # Everything else installed and applicable for a Book 5 940XHA
    fake_status = {
        "version":         version,
        "kernel":          "6.19.8-200.fc43.x86_64",
        "distro":          "Fedora Linux 43 (KDE Plasma)",
        "hardware":        "book5",
        "hardware_model":  "940XHA",
        "reboot_required": True,
        "secure_boot": False,
        "fixes": {
            "fanspeed":          {"status": "installed",      "applicable": True,  "can_install": False, "can_uninstall": True,  "message": "",                                                                                          "warning": "", "hw_status": "confirmed",  "reboot_pending": False},
            "fingerprint":       {"status": "installed",      "applicable": True,  "can_install": False, "can_uninstall": True,  "message": "",                                                                                          "warning": "", "hw_status": "confirmed",  "reboot_pending": False},
            "fnkeys":            {"status": "not_installed",  "applicable": True,  "can_install": True,  "can_uninstall": False, "message": "",                                                                                          "warning": "", "hw_status": "confirmed",  "reboot_pending": False},
            "kdeosd":            {"status": "installed",      "applicable": True,  "can_install": False, "can_uninstall": True,  "message": "",                                                                                          "warning": "", "hw_status": "confirmed",  "reboot_pending": False},
            "mic":               {"status": "not_applicable", "applicable": False, "can_install": False, "can_uninstall": False, "message": "",                                                                                          "warning": "", "hw_status": "not_applicable", "reboot_pending": False},
            "ov02c10":           {"status": "not_applicable", "applicable": False, "can_install": False, "can_uninstall": False, "message": "",                                                                                          "warning": "", "hw_status": "not_applicable", "reboot_pending": False},
            "speaker":           {"status": "not_installed",  "applicable": True,  "can_install": True,  "can_uninstall": False, "message": "",                                                                                          "warning": "", "hw_status": "confirmed",  "reboot_pending": False},
            "webcamfix_book5":   {"status": "installed",      "applicable": True,  "can_install": False, "can_uninstall": True,  "message": "Intel IPU7 Lunar Lake — vision drivers, ACPI rotation fix, libcamera pipeline",            "warning": "", "hw_status": "confirmed",  "reboot_pending": True},
            "webcamfix_libcamera": {"status": "not_applicable", "applicable": False, "can_install": False, "can_uninstall": False, "message": "",                                                                                       "warning": "", "hw_status": "not_applicable", "reboot_pending": False},
            "webcamtoggle":      {"status": "installed",      "applicable": True,  "can_install": False, "can_uninstall": True,  "message": "",                                                                                          "warning": "", "hw_status": "confirmed",  "reboot_pending": False},
        },
    }

    # ── Fake terminal content — tail end of a speaker fix install ─────────────
    fake_terminal = [
        ("\n",                                                        TAG_PLAIN),
        ("\n",                                                        TAG_PLAIN),
        ("═══ Function Key Fix: Uninstalling DKMS module ═══\n",     TAG_BOLD),
        ("[INFO] Running dkms remove...\n",                           TAG_INFO),
        ("[INFO] ✓ samsung-galaxybook-fnkeys DKMS module removed\n",  TAG_INFO),
        ("[INFO] Removing /etc/modules-load.d/fnkeys.conf...\n",      TAG_INFO),
        ("[INFO] ✓ Module config removed\n",                          TAG_INFO),
        ("\n",                                                        TAG_PLAIN),
        ("━" * 52 + "\n",                                            TAG_BOLD),
        ("                    Complete\n",                            TAG_BOLD),
        ("━" * 52 + "\n",                                            TAG_BOLD),
        ("\n",                                                        TAG_PLAIN),
        ("[INFO] ✓ Function Key Fix uninstalled successfully\n",      TAG_INFO),
        ("  Changes will take effect after reboot.\n",                TAG_PLAIN),
    ]

    # ── Bootstrap a minimal SamsungFixesApp inside a GtkOffscreenWindow ───────
    # GtkOffscreenWindow renders entirely to an internal Cairo surface without
    # needing a compositor — works correctly on both X11 and Wayland.
    _apply_user_font_settings()

    # Force light theme for screenshot
    SamsungFixesApp._is_dark_theme = lambda self: False

    WIN_W      = 614
    WIN_H      = 530
    TERM_H     = 250
    TOTAL_H    = WIN_H + TERM_H

    app            = SamsungFixesApp.__new__(SamsungFixesApp)
    Gtk.Window.__init__(app, title=f"Samsung Book Fixes - v{version}")
    app._is_ubuntu    = False
    app._logical_w    = 1920
    app._logical_h    = 1080
    app._win_w        = WIN_W
    app._win_h        = WIN_H
    app._terminal_h   = TERM_H
    app._sp           = 1.0
    app._running      = False
    app._status       = {}
    app._current_proc = None
    app._fix_widgets  = {}
    app._status_warn_colour = "#f39c12"
    app._apply_css()
    app._build_ui()
    app.set_default_size(WIN_W, TOTAL_H)
    app.set_resizable(False)

    # Show terminal section
    app._scroll.set_min_content_height(TERM_H)
    app._scroll.set_max_content_height(TERM_H)
    app._btn_copy.show()
    app._btn_clear.show()
    app._bottom_separator.hide()
    app._btn_show_output.get_style_context().remove_class("btn-green")
    app._btn_show_output.get_style_context().add_class("btn-red")
    app._btn_show_output.set_label("Hide Terminal")

    # Populate terminal and apply fake status
    for text, tag in fake_terminal:
        app._append_output(text, tag)

    # Show window, apply status AFTER show_all so card.hide() calls win
    app.connect("delete-event", Gtk.main_quit)
    app.show_all()
    # Load icon after show_all so KWin sees it when the window is mapped
    icon_path = os.path.join(SCRIPT_DIR, "samsung-galaxybook-icon.svg")
    if os.path.exists(icon_path):
        try:
            # Try set_icon_from_file first (more reliable on Wayland/KWin)
            app.set_icon_from_file(icon_path)
        except Exception:
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(icon_path, 64, 64)
                app.set_icon(pixbuf)
            except Exception:
                pass
    app._apply_status(fake_status)
    # Re-hide non-applicable cards — show_all() overrides card.hide()
    for key, info in fake_status["fixes"].items():
        if not info.get("applicable", True) and key in app._fix_widgets:
            app._fix_widgets[key]["card"].hide()

    # ── Capture via Spectacle (KDE screenshot tool) ───────────────────────────
    # spectacle -b -a captures the active window in the background.
    # We present() our window to make it active, then spectacle fires after
    # --delay ms so the window is fully painted before capture.
    import tempfile as _tempfile
    import shutil as _shutil

    _render_succeeded = [False]

    def _capture_and_quit():
        try:
            if not _shutil.which("spectacle"):
                print("[screenshot] spectacle not found")
                Gtk.main_quit()
                return False

            # Make our window the active window
            app.present()

            # Use a temp file so we can post-process with Pillow
            tmp = _tempfile.NamedTemporaryFile(suffix=".png", delete=False)
            tmp.close()

            # -b background, -a active window, -n no notify,
            # -e no decoration, -S no shadow, -d 1500ms delay
            result = subprocess.run(
                ["spectacle", "-b", "-a", "-n", "-S",
                 "-d", "800", "-o", tmp.name],
                capture_output=True, text=True
            )

            if result.returncode != 0 or not os.path.isfile(tmp.name):
                print(f"[screenshot] spectacle failed: {result.stderr.strip()}")
                Gtk.main_quit()
                return False

            # Apply rounded corners + 1px border with Pillow
            base = Image.open(tmp.name).convert("RGBA")
            w, h = base.size

            RADIUS = 12
            mask   = Image.new("L", (w, h), 0)
            md     = ImageDraw.Draw(mask)
            md.rounded_rectangle([0, 0, w - 1, h - 1], radius=RADIUS, fill=255)

            out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            out.paste(base, mask=mask)

            bd = ImageDraw.Draw(out)
            bd.rounded_rectangle(
                [0, 0, w - 1, h - 1],
                radius=RADIUS,
                outline=(180, 180, 180, 220),
                width=1,
            )

            os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
            out.save(out_path, "PNG")
            os.unlink(tmp.name)
            print(f"[screenshot] Saved → {out_path}")
            _render_succeeded[0] = True

        except Exception as e:
            print(f"[screenshot] Render failed: {e}")
        finally:
            Gtk.main_quit()

        return False

    # Small initial delay to let the window fully paint before spectacle fires
    GLib.timeout_add(200, _capture_and_quit)
    Gtk.main()


if __name__ == "__main__":
    # Allow headless screenshot mode — bypasses pkexec/lock requirements
    # Usage: python3 samsung-galaxybook-gui.py --screenshot <version> <out_path>
    if "--screenshot" in sys.argv:
        try:
            idx  = sys.argv.index("--screenshot")
            ver  = sys.argv[idx + 1]
            dest = sys.argv[idx + 2]
        except IndexError:
            print("Usage: samsung-galaxybook-gui.py --screenshot <version> <output_path>")
            sys.exit(1)
        screenshot_mode(ver, dest)
    else:
        # ── Test Mode: --model <MODEL> overrides hardware detection ──────────
        # Usage: ./samsung-galaxybook-gui --model 940XHA
        # Also accepts SAMSUNG_GALAXYBOOK_MODEL env var.
        _model_override = os.environ.get("SAMSUNG_GALAXYBOOK_MODEL", "")
        if _model_override:
            OVERRIDE_MODEL = _model_override.upper().lstrip("NP")
            print(f"[TEST MODE] Model override: {OVERRIDE_MODEL}", flush=True)
        elif "--model" in sys.argv:
            try:
                idx = sys.argv.index("--model")
                OVERRIDE_MODEL = sys.argv[idx + 1]
                sys.argv.pop(idx + 1)
                sys.argv.pop(idx)
                print(f"[TEST MODE] Model override: {OVERRIDE_MODEL}", flush=True)
            except IndexError:
                print("Usage: samsung-galaxybook-gui --model <MODEL_NUMBER>")
                sys.exit(1)
        main()
