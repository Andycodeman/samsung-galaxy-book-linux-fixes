#!/usr/bin/env python3
"""Camera Relay systray indicator — thin wrapper around the camera-relay CLI."""

import json
import os
import subprocess
import sys
import threading

# Require a display server
if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
    print("camera-relay-systray: No display detected, exiting.", file=sys.stderr)
    sys.exit(0)

# Single instance enforcement via lock file
import fcntl

LOCK_FILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "camera-relay-systray.lock")
_lock_fd = open(LOCK_FILE, "w")
try:
    fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    print("camera-relay-systray: Another instance is already running.", file=sys.stderr)
    sys.exit(0)

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gio

# Name shown by the tray/panel instead of the script filename
GLib.set_prgname("camera-relay")
GLib.set_application_name("Camera Relay")

# Prefer Ayatana AppIndicator (publishes ToolTip, so KDE shows hover text),
# fall back to legacy AppIndicator3. GNOME (with extension), KDE, others.
USE_APPINDICATOR = False
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
    USE_APPINDICATOR = True
except (ValueError, ImportError):
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3
        USE_APPINDICATOR = True
    except (ValueError, ImportError):
        pass

RELAY_CMD = "/usr/local/bin/camera-relay"

# Runtime state files written by camera-relay in its cache dir (same paths as
# STATE_CACHE / PID_FILE there). The daemon flips the state file between
# "idle" and "streaming" on every transition and removes it (plus the pid
# file) on stop — so watching them means the icon can react in milliseconds
# instead of waiting for the next poll.
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
WATCH_FILES = ("camera-relay-state", "camera-relay.pid")

# Safety-net poll for anything the file watch could miss (e.g. a relay that
# stopped long before this process started, or weird filesystem changes).
FALLBACK_POLL_INTERVAL = 60  # seconds


class CameraRelaySystray:
    def __init__(self):
        self.running = False
        self.persistent = False

        if USE_APPINDICATOR:
            self.indicator = AppIndicator3.Indicator.new(
                "camera-relay",
                "camera-video-symbolic",
                AppIndicator3.IndicatorCategory.HARDWARE,
            )
            self.indicator.set_title("Camera Relay")
            self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
            self.indicator.set_menu(self._build_menu())
        else:
            print(
                "camera-relay-systray: AppIndicator3 not available. "
                "Install the Ayatana AppIndicator library "
                "(gir1.2-ayatanaappindicator3-0.1 / libayatana-appindicator-gtk3 / "
                "libayatana-appindicator); on GNOME also gnome-shell-extension-appindicator.",
                file=sys.stderr,
            )
            print(
                "camera-relay-systray: Falling back to Gtk.StatusIcon.",
                file=sys.stderr,
            )
            self.status_icon = Gtk.StatusIcon()
            self.status_icon.set_from_icon_name("camera-video-symbolic")
            self.status_icon.set_tooltip_text("Camera Relay")
            self.status_icon.connect("popup-menu", self._on_status_icon_popup)
            self.status_icon.set_visible(True)

        # Watch the daemon's runtime files so state changes reach the icon
        # immediately, then do an initial sync and set up the slow fallback.
        self._install_runtime_watch()
        self._poll_status()
        GLib.timeout_add_seconds(FALLBACK_POLL_INTERVAL, self._poll_status)

    def _install_runtime_watch(self):
        """Monitor the runtime dir for changes to the relay's state files.

        Uses one directory watcher (handles create/delete/attribution, and
        the file does not have to exist yet — e.g. when the relay is stopped
        at startup). Events are debounced: `cat > file` triggers
        several inotify events in quick succession, and each of those would
        otherwise spawn a status subprocess.
        """
        try:
            gio_dir = Gio.File.new_for_path(RUNTIME_DIR)
            self._runtime_monitor = gio_dir.monitor_directory(
                Gio.FileMonitorFlags.NONE, None
            )
            self._runtime_monitor.connect("changed", self._on_runtime_event)
        except Exception as e:  # watcher unavailable -> keep poll-only
            self._runtime_monitor = None
            print(
                "camera-relay-systray: file watch unavailable (%s), "
                "relying on the %ds fallback poll." % (e, FALLBACK_POLL_INTERVAL),
                file=sys.stderr,
            )

    def _on_runtime_event(self, _monitor, file, _other_file, _event_type):
        name = file.get_basename() if file else ""
        if name in WATCH_FILES:
            self._deferred_poll()

    def _deferred_poll(self):
        """Coalesce bursts of watch events into one poll shortly after."""
        if getattr(self, "_pending_poll_source", None):
            return
        self._pending_poll_source = GLib.timeout_add(250, self._poll_returns_false)

    def _poll_returns_false(self):
        self._pending_poll_source = None
        self._poll_status()
        return False  # one-shot

    def _build_menu(self):
        menu = Gtk.Menu()

        self.item_toggle = Gtk.MenuItem(label="Start Relay")
        self.item_toggle.connect("activate", self._on_toggle)
        menu.append(self.item_toggle)

        menu.append(Gtk.SeparatorMenuItem())

        self.item_persistent = Gtk.MenuItem(label="Enable Persistent Mode")
        self.item_persistent.connect("activate", self._on_persistent_toggle)
        menu.append(self.item_persistent)

        menu.append(Gtk.SeparatorMenuItem())

        self.item_status = Gtk.MenuItem(label="Status: checking...")
        self.item_status.set_sensitive(False)
        menu.append(self.item_status)

        menu.append(Gtk.SeparatorMenuItem())

        item_hide = Gtk.MenuItem(label="Hide Indicator")
        item_hide.connect("activate", self._on_hide)
        menu.append(item_hide)

        item_stop_hide = Gtk.MenuItem(label="Stop Relay & Hide")
        item_stop_hide.connect("activate", self._on_stop_and_hide)
        menu.append(item_stop_hide)

        item_disable_hide = Gtk.MenuItem(label="Disable Relay & Hide")
        item_disable_hide.connect("activate", self._on_disable_and_hide)
        menu.append(item_disable_hide)

        menu.show_all()
        return menu

    def _on_status_icon_popup(self, icon, button, time):
        menu = self._build_menu()
        menu.popup(None, None, Gtk.StatusIcon.position_menu, icon, button, time)

    def _get_status(self):
        try:
            result = subprocess.run(
                [RELAY_CMD, "status", "--json"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            return json.loads(result.stdout)
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            return {"running": False, "persistent": False, "camera": "", "device": ""}

    def _poll_status(self):
        status = self._get_status()
        self.running = status.get("running", False)
        self.persistent = status.get("persistent", False)
        self.state = status.get("state", "stopped")

        # Update menu labels
        if hasattr(self, "item_toggle"):
            if self.running:
                self.item_toggle.set_label("Stop Relay")
            else:
                self.item_toggle.set_label("Start Relay")
        if hasattr(self, "item_persistent"):
            self.item_persistent.set_label(
                "Disable Persistent Mode"
                if self.persistent
                else "Enable Persistent Mode"
            )
        if hasattr(self, "item_status"):
            if not self.running:
                label = "Status: STOPPED"
            elif self.state == "idle":
                label = "Status: ON-DEMAND (idle)"
            elif self.state == "streaming":
                label = "Status: STREAMING"
            else:
                label = "Status: RUNNING"
            if self.persistent:
                label += " (persistent)"
            self.item_status.set_label(label)

        # Update icon: streaming=active, idle/on-demand=ready, stopped=disabled
        if self.running and self.state == "streaming":
            icon = "camera-video-symbolic"
        elif self.running:
            icon = "camera-switch-symbolic"  # idle/on-demand
        else:
            icon = "camera-disabled-symbolic"

        if USE_APPINDICATOR:
            self.indicator.set_icon(icon)
        else:
            self.status_icon.set_from_icon_name(icon)

        return True  # keep polling

    def _on_toggle(self, _widget):
        action = "stop" if self.running else "start"
        # Disable toggle while action is in progress
        if hasattr(self, "item_toggle"):
            self.item_toggle.set_label("Stopping..." if self.running else "Starting...")
            self.item_toggle.set_sensitive(False)

        def _run_action():
            try:
                result = subprocess.run(
                    [RELAY_CMD, action],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                if result.returncode != 0:
                    error = result.stderr.strip() or result.stdout.strip() or "Unknown error"
                    GLib.idle_add(self._show_error, f"Failed to {action} relay:\n\n{error}")
            except subprocess.TimeoutExpired:
                GLib.idle_add(self._show_error, f"Timed out trying to {action} relay")
            except Exception as e:
                GLib.idle_add(self._show_error, f"Error: {e}")
            # Update UI from main thread after action completes
            GLib.idle_add(self._poll_status_once)

        threading.Thread(target=_run_action, daemon=True).start()

    def _poll_status_once(self):
        """One-shot status update (for use with GLib.idle_add after actions)."""
        self._poll_status()
        # Re-enable toggle button
        if hasattr(self, "item_toggle"):
            self.item_toggle.set_sensitive(True)
        return False  # do NOT repeat

    def _show_error(self, message):
        dialog = Gtk.MessageDialog(
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text="Camera Relay Error",
        )
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()
        return False  # for GLib.idle_add

    def _on_persistent_toggle(self, _widget):
        if self.persistent:
            subprocess.Popen([RELAY_CMD, "disable-persistent"])
            GLib.timeout_add(1000, self._poll_status)
        else:
            self._show_persistent_warning()

    def _show_persistent_warning(self):
        dialog = Gtk.MessageDialog(
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Enable On-Demand Camera Relay?",
        )
        dialog.format_secondary_text(
            "The camera relay daemon will start on login and make the "
            "camera visible to apps like Zoom, OBS, and Chrome.\n\n"
            "Idle: Near-zero CPU and battery usage\n"
            "Streaming: ~2-3% CPU (only while camera is in use)\n\n"
            "The camera activates automatically when an app opens it, "
            "and deactivates when the last app closes it.\n\n"
            "You can disable this later from this menu or by running:\n\n"
            "  camera-relay disable-persistent"
        )
        dialog.set_title("Camera Relay")

        response = dialog.run()
        dialog.destroy()

        if response == Gtk.ResponseType.OK:
            subprocess.Popen([RELAY_CMD, "enable-persistent", "--yes"])
            GLib.timeout_add(1000, self._poll_status)

    def _on_hide(self, _widget):
        """Just close the indicator — relay keeps running."""
        Gtk.main_quit()

    def _on_stop_and_hide(self, _widget):
        """Stop the relay now but keep persistent enabled (restarts on next login)."""
        subprocess.run([RELAY_CMD, "stop"], capture_output=True, timeout=10)
        Gtk.main_quit()

    def _on_disable_and_hide(self, _widget):
        """Disable persistent mode, stop relay, and close indicator."""
        dialog = Gtk.MessageDialog(
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Disable Camera Relay?",
        )
        dialog.format_secondary_text(
            "This will stop the camera relay and prevent it from starting "
            "on login. The internal camera won't be visible to most apps "
            "(Zoom, Chrome, OBS, etc.) without it.\n\n"
            "The relay uses near-zero CPU when idle — there's usually no "
            "reason to disable it.\n\n"
            "You can re-enable it later by running:\n\n"
            "  camera-relay enable-persistent"
        )
        dialog.set_title("Camera Relay")
        response = dialog.run()
        dialog.destroy()

        if response == Gtk.ResponseType.OK:
            subprocess.run([RELAY_CMD, "disable-persistent"], capture_output=True, timeout=10)
            subprocess.run([RELAY_CMD, "stop"], capture_output=True, timeout=10)
            Gtk.main_quit()


if __name__ == "__main__":
    app = CameraRelaySystray()
    Gtk.main()
