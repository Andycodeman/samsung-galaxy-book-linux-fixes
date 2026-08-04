/*
 * camera-relay-gst — setgid launcher for the libcamera pipeline
 *
 * The raw IPU6/IPU7 ISYS nodes are owned by the 'camera-relay' group so
 * that ordinary applications cannot open them (see
 * 74-camera-relay-mc-nodes.rules). libcamera still needs them, so the one
 * process that legitimately drives the camera gets the group through this
 * setgid launcher. The UID never changes: the pipeline stays inside the
 * user's session, keeping the uaccess ACLs on the loopback and the media
 * node, the EGL context used for GPU debayer, and the monitor's
 * same-UID /proc scan all working.
 *
 * SECURITY — the two properties this file exists to hold:
 *
 *   1. It never executes a command line it was handed. Doing so would give
 *      the caller the group back and defeat the whole arrangement. Every
 *      input is validated and the pipeline is assembled here.
 *
 *   2. It builds a fresh environment instead of filtering the inherited
 *      one. GStreamer and libcamera both load code from paths named by
 *      environment variables (GST_PLUGIN_PATH, GST_REGISTRY,
 *      LIBCAMERA_IPA_MODULE_PATH, ...); a deny-list would rot. Directory
 *      arguments are accepted only under root-owned prefixes.
 *
 * setresgid() before exec is deliberate: with egid != rgid the loader
 * marks the child AT_SECURE and glibc drops LD_LIBRARY_PATH. That is
 * survivable here because ld.so.conf.d puts the patched libcamera ahead
 * of the system one, but an AT_SECURE child also loses other inherited
 * state for no benefit. Equalising the three GIDs keeps the child normal.
 *
 * Build:  gcc -O2 -Wall -o camera-relay-gst camera-relay-gst.c
 * Usage:  camera-relay-gst --camera NAME --v4l2-sink /dev/video0
 *         camera-relay-gst --camera NAME --fd-sink 3 --width 1920 --height 1080
 *         camera-relay-gst --list-cameras
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Shared writable state for the pipeline's own caches. Root-owned,
 * group-writable, so a user cannot plant a poisoned GStreamer registry
 * (the registry maps elements to .so paths that get dlopen()ed). */
#define CACHE_DIR "/var/cache/camera-relay"

#define MAX_ARGS 64

/*
 * Slots append_color_filter() must leave free. The longest tail emitted after
 * it is the --v4l2-sink path:
 *
 *   "!"  caps  "!"  v4l2sink  device=…  io-mode=mmap  sync=false   → 7
 *   NULL terminator                                                → 8
 *
 * and one iteration of that loop can append two entries at once ("!" plus the
 * element name), so it has to stop while there is still room for both → 9.
 *
 * Keep this in step with the tail in main(): the --fd-sink path is one shorter,
 * which is exactly what hid an off-by-one here until it was caught under ASan.
 */
#define TAIL_SLOTS 9

/* Directory arguments must live under one of these. All root-owned, so a
 * validated path cannot point at anything the caller controls. */
static const char *const TRUSTED_PREFIXES[] = {
	"/usr/lib/", "/usr/lib64/", "/usr/share/",
	"/usr/local/lib/", "/usr/local/lib64/", "/usr/local/share/",
	NULL
};

/* Where GLVND keeps EGL vendor ICDs. Narrower than TRUSTED_PREFIXES because
 * this value selects which driver the debayer runs on. */
static const char *const EGL_VENDOR_PREFIXES[] = {
	"/etc/glvnd/egl_vendor.d/", "/usr/share/glvnd/egl_vendor.d/",
	NULL
};

/* Pure video filters. Excluding sources and sinks is what keeps a color
 * filter from turning into file or network access. */
static const char *const FILTER_ELEMENTS[] = {
	"videobalance", "videoflip", "videoconvert", "videoscale",
	"gamma", "coloreffects", "videomedian", "aspectratiocrop",
	NULL
};

static const char *const GST_LAUNCH_PATHS[] = {
	"/usr/bin/gst-launch-1.0", "/usr/local/bin/gst-launch-1.0", NULL
};

static const char *const CAM_PATHS[] = {
	"/usr/local/bin/cam", "/usr/bin/cam", NULL
};

static void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fprintf(stderr, "camera-relay-gst: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	exit(1);
}

static int in_list(const char *needle, const char *const *list)
{
	for (; *list; list++)
		if (!strcmp(needle, *list))
			return 1;
	return 0;
}

static const char *first_existing(const char *const *paths)
{
	for (; *paths; paths++)
		if (!access(*paths, X_OK))
			return *paths;
	return NULL;
}

/* Every accepted character must be one we are willing to hand to the
 * gst-launch parser. Backslash is needed for ACPI names like
 * \_SB_.PC00.LNK0; '!' and whitespace are what a pipeline injection would
 * need, so they are absent by construction. */
static int valid_camera_name(const char *s)
{
	if (!*s || strlen(s) > 128)
		return 0;
	for (; *s; s++) {
		if (*s >= 'A' && *s <= 'Z') continue;
		if (*s >= 'a' && *s <= 'z') continue;
		if (*s >= '0' && *s <= '9') continue;
		if (strchr("._-:\\/", *s)) continue;
		return 0;
	}
	return 1;
}

static int valid_ident(const char *s, const char *extra)
{
	if (!*s)
		return 0;
	for (; *s; s++) {
		if (*s >= 'A' && *s <= 'Z') continue;
		if (*s >= 'a' && *s <= 'z') continue;
		if (*s >= '0' && *s <= '9') continue;
		if (strchr(extra, *s)) continue;
		return 0;
	}
	return 1;
}

static void require_prefix(const char *opt, const char *path,
			   const char *const *prefixes)
{
	const char *const *p;
	size_t len;

	if (path[0] != '/')
		die("%s must be an absolute path", opt);
	if (strstr(path, ".."))
		die("%s must not contain '..'", opt);

	for (p = prefixes; *p; p++) {
		len = strlen(*p);
		/* Match the prefix with or without its trailing slash, so
		 * "/usr/local/lib" itself is accepted. */
		if (!strncmp(path, *p, len) ||
		    (!strncmp(path, *p, len - 1) && path[len - 1] == '\0'))
			return;
	}
	die("%s must be under a root-owned system directory, got '%s'", opt, path);
}

static void require_trusted_dir(const char *opt, const char *path)
{
	require_prefix(opt, path, TRUSTED_PREFIXES);
}

/*
 * The EGL vendor pin is a colon-separated list of ICD files; validate each
 * element. Without it the debayer lands on whichever ICD GLVND happens to load
 * first, which on a hybrid laptop is NVIDIA's — and libcamera's EGL debayer
 * fails against it, so every frame comes out black.
 */
static void require_egl_vendor_list(const char *opt, const char *list)
{
	char *copy, *tok, *save;

	if (!*list)
		die("%s must not be empty", opt);
	copy = strdup(list);
	if (!copy)
		die("out of memory");

	for (tok = strtok_r(copy, ":", &save); tok;
	     tok = strtok_r(NULL, ":", &save))
		require_prefix(opt, tok, EGL_VENDOR_PREFIXES);

	free(copy);
}

/* gst-launch joins its argv and re-parses the result, so a backslash in
 * the camera name is an escape unless doubled. */
static char *escape_backslashes(const char *s)
{
	char *out, *o;

	out = malloc(strlen(s) * 2 + 1);
	if (!out)
		die("out of memory");
	for (o = out; *s; s++) {
		if (*s == '\\')
			*o++ = '\\';
		*o++ = *s;
	}
	*o = '\0';
	return out;
}

/*
 * Append a RELAY_COLOR_FILTER spec, e.g. "videobalance saturation=0.85",
 * optionally chained with '!'. Each stage must name an allow-listed filter
 * and carry only simple name=value properties.
 */
static int append_color_filter(char **argv, int argc, char *spec)
{
	int expect_element = 1;
	char *tok, *save;

	for (tok = strtok_r(spec, " \t", &save); tok;
	     tok = strtok_r(NULL, " \t", &save)) {
		if (argc >= MAX_ARGS - TAIL_SLOTS)
			die("color filter too long");

		if (!strcmp(tok, "!")) {
			if (expect_element)
				die("color filter has an empty stage");
			expect_element = 1;
			argv[argc++] = tok;
			continue;
		}

		if (expect_element) {
			if (!in_list(tok, FILTER_ELEMENTS))
				die("color filter element '%s' is not allowed", tok);
			argv[argc++] = "!";
			argv[argc++] = tok;
			expect_element = 0;
			continue;
		}

		/* property: name=value */
		char *eq = strchr(tok, '=');
		if (!eq || eq == tok)
			die("color filter expects name=value, got '%s'", tok);
		*eq = '\0';
		if (!valid_ident(tok, "-_") || !valid_ident(eq + 1, "._-"))
			die("color filter property '%s' is not allowed", tok);
		*eq = '=';
		argv[argc++] = tok;
	}

	if (expect_element)
		die("color filter ends with a dangling '!'");
	return argc;
}

/*
 * Replace the inherited environment wholesale. Only entries built here
 * survive, so nothing the caller set can steer code loading.
 */
static char **build_environment(const char *gst_plugin_path,
				const char *ipa_path,
				const char *softisp_mode,
				const char *egl_vendor)
{
	static char *env[12];
	static char buf[6][PATH_MAX + 64];
	int n = 0, b = 0;

	env[n++] = "PATH=/usr/local/bin:/usr/bin:/bin";
	/* Mesa and GStreamer both want somewhere to cache; point them at the
	 * group-writable directory rather than the user's HOME. */
	env[n++] = "HOME=" CACHE_DIR;
	env[n++] = "GST_REGISTRY=" CACHE_DIR "/gst-registry.bin";
	env[n++] = "MESA_SHADER_CACHE_DIR=" CACHE_DIR "/mesa";

	if (gst_plugin_path) {
		snprintf(buf[b], sizeof(buf[b]), "GST_PLUGIN_PATH=%s", gst_plugin_path);
		env[n++] = buf[b++];
	}
	if (ipa_path) {
		snprintf(buf[b], sizeof(buf[b]), "LIBCAMERA_IPA_MODULE_PATH=%s", ipa_path);
		env[n++] = buf[b++];
	}
	if (softisp_mode) {
		snprintf(buf[b], sizeof(buf[b]), "LIBCAMERA_SOFTISP_MODE=%s", softisp_mode);
		env[n++] = buf[b++];
	}
	if (egl_vendor) {
		snprintf(buf[b], sizeof(buf[b]),
			 "__EGL_VENDOR_LIBRARY_FILENAMES=%s", egl_vendor);
		env[n++] = buf[b++];
	}

	env[n] = NULL;
	return env;
}

/*
 * Take the group for real. Leaving egid != rgid would make the child
 * AT_SECURE; it also leaves a saved-set GID around for no reason.
 */
static void assume_group(void)
{
	gid_t egid = getegid();

	if (egid == getgid())
		/* Not actually setgid — either an uninstalled build or a
		 * system where the caller already holds the group. Let the
		 * pipeline run and fail on its own if access is missing. */
		return;

	if (setresgid(egid, egid, egid) < 0)
		die("setresgid: %s", strerror(errno));
}

static void usage(void)
{
	fprintf(stderr,
		"usage: camera-relay-gst --camera NAME (--v4l2-sink DEV | --fd-sink N)\n"
		"                        [--width W --height H] [--color-filter SPEC]\n"
		"                        [--gst-plugin-path DIR] [--ipa-path DIR]\n"
		"                        [--softisp-mode cpu|gpu] [--egl-vendor ICD[:ICD...]]\n"
		"       camera-relay-gst --list-cameras\n");
	exit(1);
}

int main(int argc, char *argv[])
{
	const char *camera = NULL, *v4l2_sink = NULL, *gst_plugin_path = NULL;
	const char *ipa_path = NULL, *softisp_mode = NULL, *egl_vendor = NULL;
	char *color_filter = NULL;
	long fd_sink = -1, width = 0, height = 0;
	int list_cameras = 0;
	char *gst_argv[MAX_ARGS];
	char caps[128], camera_arg[300], sink_arg[64];
	int n = 0, i;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *val = NULL;

		/* Options that take a value */
		if (i + 1 < argc)
			val = argv[i + 1];

		if (!strcmp(a, "--list-cameras")) {
			list_cameras = 1;
		} else if (!strcmp(a, "--camera") && val) {
			camera = val; i++;
		} else if (!strcmp(a, "--v4l2-sink") && val) {
			v4l2_sink = val; i++;
		} else if (!strcmp(a, "--fd-sink") && val) {
			fd_sink = strtol(val, NULL, 10); i++;
		} else if (!strcmp(a, "--width") && val) {
			width = strtol(val, NULL, 10); i++;
		} else if (!strcmp(a, "--height") && val) {
			height = strtol(val, NULL, 10); i++;
		} else if (!strcmp(a, "--color-filter") && val) {
			color_filter = argv[++i];
		} else if (!strcmp(a, "--gst-plugin-path") && val) {
			gst_plugin_path = val; i++;
		} else if (!strcmp(a, "--ipa-path") && val) {
			ipa_path = val; i++;
		} else if (!strcmp(a, "--softisp-mode") && val) {
			softisp_mode = val; i++;
		} else if (!strcmp(a, "--egl-vendor") && val) {
			egl_vendor = val; i++;
		} else {
			usage();
		}
	}

	/* Validate everything that reaches the child environment before either
	 * branch uses it — these select which code the pipeline loads, and
	 * --list-cameras passes them through just the same. */
	if (softisp_mode && strcmp(softisp_mode, "cpu") && strcmp(softisp_mode, "gpu"))
		die("--softisp-mode must be 'cpu' or 'gpu'");
	if (gst_plugin_path)
		require_trusted_dir("--gst-plugin-path", gst_plugin_path);
	if (ipa_path)
		require_trusted_dir("--ipa-path", ipa_path);
	if (egl_vendor)
		require_egl_vendor_list("--egl-vendor", egl_vendor);

	assume_group();

	if (list_cameras) {
		const char *cam = first_existing(CAM_PATHS);
		char *cam_argv[] = { NULL, "-l", NULL };

		if (camera || v4l2_sink || fd_sink >= 0)
			die("--list-cameras takes no other options");
		if (!cam)
			die("cam not found; install libcamera tools");

		cam_argv[0] = (char *)cam;
		execve(cam, cam_argv, build_environment(gst_plugin_path, ipa_path,
						        softisp_mode, egl_vendor));
		die("execve %s: %s", cam, strerror(errno));
	}

	/* ── validate ─────────────────────────────────────────────────── */

	if (!camera)
		usage();
	if (!valid_camera_name(camera))
		die("camera name contains characters that are not allowed");

	if ((v4l2_sink != NULL) == (fd_sink >= 0))
		die("give exactly one of --v4l2-sink or --fd-sink");

	if (v4l2_sink) {
		/* The length bound is what the charset check leaves unsaid:
		 * without it "/dev/video" plus a hundred digits validates and
		 * then silently truncates into sink_arg. snprintf keeps that
		 * safe, but saying the bound is better than relying on it. */
		if (strncmp(v4l2_sink, "/dev/video", 10) ||
		    !valid_ident(v4l2_sink + 10, "") ||
		    strlen(v4l2_sink + 10) > 3)
			die("--v4l2-sink must be /dev/videoN, got '%s'", v4l2_sink);
	} else {
		if (fd_sink < 3 || fd_sink > 20)
			die("--fd-sink must be between 3 and 20");
		if (fcntl(fd_sink, F_GETFD) < 0)
			die("--fd-sink %ld is not open", fd_sink);
	}

	if ((width != 0) != (height != 0))
		die("--width and --height must be given together");
	if (width && (width < 16 || width > 8192 || height < 16 || height > 8192))
		die("--width/--height out of range");

	/* ── assemble the pipeline ────────────────────────────────────── */

	const char *gst = first_existing(GST_LAUNCH_PATHS);
	if (!gst)
		die("gst-launch-1.0 not found; install gstreamer1.0-tools");

	char *escaped = escape_backslashes(camera);
	snprintf(camera_arg, sizeof(camera_arg), "camera-name=%s", escaped);

	gst_argv[n++] = (char *)gst;
	gst_argv[n++] = "-e";
	gst_argv[n++] = "libcamerasrc";
	gst_argv[n++] = camera_arg;
	gst_argv[n++] = "!";
	gst_argv[n++] = "queue";
	gst_argv[n++] = "max-size-buffers=3";
	gst_argv[n++] = "leaky=downstream";
	gst_argv[n++] = "!";
	gst_argv[n++] = "videoconvert";

	if (color_filter && *color_filter)
		n = append_color_filter(gst_argv, n, color_filter);

	if (width)
		snprintf(caps, sizeof(caps),
			 "video/x-raw,format=YUY2,width=%ld,height=%ld", width, height);
	else
		snprintf(caps, sizeof(caps), "video/x-raw,format=YUY2");
	gst_argv[n++] = "!";
	gst_argv[n++] = caps;

	gst_argv[n++] = "!";
	if (v4l2_sink) {
		snprintf(sink_arg, sizeof(sink_arg), "device=%s", v4l2_sink);
		gst_argv[n++] = "v4l2sink";
		gst_argv[n++] = sink_arg;
		gst_argv[n++] = "io-mode=mmap";
	} else {
		snprintf(sink_arg, sizeof(sink_arg), "fd=%ld", fd_sink);
		gst_argv[n++] = "fdsink";
		gst_argv[n++] = sink_arg;
	}
	gst_argv[n++] = "sync=false";
	gst_argv[n] = NULL;

	execve(gst, gst_argv,
	       build_environment(gst_plugin_path, ipa_path, softisp_mode, egl_vendor));
	die("execve %s: %s", gst, strerror(errno));
	return 1;
}
