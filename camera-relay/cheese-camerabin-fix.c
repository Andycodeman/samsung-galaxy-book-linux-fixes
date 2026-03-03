/*
 * cheese-camerabin-fix.so — LD_PRELOAD fix for Cheese CameraBin crash
 *
 * PROBLEMS:
 * 1. On Ubuntu 24.04 with GStreamer 1.24.2, Cheese crashes with SIGSEGV
 *    in ORC-compiled pixel format conversion code. The crash is a buffer
 *    use-after-free: CameraBin's internal videoconvert elements read from
 *    source buffer memory that has already been recycled by the upstream
 *    source. This only happens in CameraBin's multi-branch pipeline; the
 *    same conversion works fine in standalone gst-launch pipelines.
 *
 * 2. CameraBin creates TWO pipewiresrc instances for the same camera —
 *    one for probing, one for capture. On IPU6 with libcamera, the camera
 *    is still locked when the second pipewiresrc tries to connect, causing
 *    "Device or resource busy" (-EBUSY). Cheese shows black screen.
 *
 * FIXES:
 * 1. Intercept gst_element_factory_make() and replace the CameraBin
 *    videoconvert elements (vfbin-csp, src-videoconvert) with a bin
 *    that forces a buffer copy through NV12, breaking the dependency
 *    on the source buffer's lifetime.
 *
 * 2. Intercept pipewiresrc creation and replace with v4l2src pointing
 *    at the camera relay loopback device (/dev/video0). The relay must
 *    be running (the wrapper script pre-starts it).
 *
 * BUILD:
 *   gcc -shared -fPIC -o cheese-camerabin-fix.so cheese-camerabin-fix.c -ldl
 *
 * USAGE:
 *   LD_PRELOAD=/usr/local/lib/cheese-camerabin-fix.so cheese
 *
 * Or create a wrapper script / .desktop override.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

typedef void GstElement;
typedef void GObject;
static GstElement* (*real_factory_make)(const char *, const char *);
static GstElement* (*parse_bin_fn)(const char *, int, void **);
static void (*g_object_set_fn)(GObject *, const char *, ...);

/* Thread-local recursion guard: our replacement bins create videoconvert
 * elements internally, so we must not intercept those recursive calls. */
static __thread int inside_fix = 0;

/* Find the v4l2loopback device for the camera relay */
static const char *find_loopback_device(void) {
    static char dev_path[32] = "";
    if (dev_path[0]) return dev_path;

    /* Check /dev/video0 through /dev/video9 for "Camera Relay" */
    for (int i = 0; i < 10; i++) {
        char name_path[64], name_buf[64];
        snprintf(name_path, sizeof(name_path),
                 "/sys/devices/virtual/video4linux/video%d/name", i);
        FILE *f = fopen(name_path, "r");
        if (!f) continue;
        if (fgets(name_buf, sizeof(name_buf), f)) {
            /* Strip newline */
            char *nl = strchr(name_buf, '\n');
            if (nl) *nl = '\0';
            if (strcmp(name_buf, "Camera Relay") == 0) {
                snprintf(dev_path, sizeof(dev_path), "/dev/video%d", i);
                fclose(f);
                return dev_path;
            }
        }
        fclose(f);
    }
    return NULL;
}

GstElement* gst_element_factory_make(const char *factoryname, const char *name) {
    if (!real_factory_make) {
        real_factory_make = dlsym(RTLD_NEXT, "gst_element_factory_make");
        parse_bin_fn = dlsym(RTLD_DEFAULT, "gst_parse_bin_from_description");
        g_object_set_fn = dlsym(RTLD_DEFAULT, "g_object_set");
    }

    /* Fix 1: Replace CameraBin videoconvert elements with NV12 copy bins.
     * Only intercept vfbin-csp and src-videoconvert — these touch the
     * source buffer that triggers the use-after-free crash. */
    if (!inside_fix && parse_bin_fn &&
        strcmp(factoryname, "videoconvert") == 0 &&
        name && (strcmp(name, "vfbin-csp") == 0 ||
                 strcmp(name, "src-videoconvert") == 0)) {

        inside_fix = 1;

        /* Two-stage conversion forces a buffer copy through NV12.
         * The first videoconvert allocates a new buffer for NV12 output,
         * so the second converter reads from safe, owned memory. */
        GstElement *bin = parse_bin_fn(
            "videoconvert ! video/x-raw,format=NV12 ! videoconvert",
            1 /* ghost_unlinked_pads */, NULL);

        inside_fix = 0;

        if (bin) {
            void (*set_name)(void *, const char *) =
                dlsym(RTLD_DEFAULT, "gst_object_set_name");
            if (set_name && name) set_name(bin, name);
            return bin;
        }
    }

    /* Fix 2: Replace pipewiresrc with v4l2src on the relay loopback.
     * CameraBin creates two pipewiresrc instances for the same camera,
     * and the second one fails with EBUSY on single-client cameras.
     * We use a bin with videoconvert because v4l2loopback serves YUYV
     * but CameraBin expects RGBA/BGRx. */
    if (!inside_fix && parse_bin_fn &&
        strcmp(factoryname, "pipewiresrc") == 0) {

        const char *loopback = find_loopback_device();
        if (loopback) {
            char pipeline[128];
            snprintf(pipeline, sizeof(pipeline),
                     "v4l2src device=%s ! videoconvert", loopback);

            inside_fix = 1;
            GstElement *bin = parse_bin_fn(pipeline,
                1 /* ghost_unlinked_pads */, NULL);
            inside_fix = 0;

            if (bin) {
                void (*set_name)(void *, const char *) =
                    dlsym(RTLD_DEFAULT, "gst_object_set_name");
                if (set_name && name) set_name(bin, name);
                return bin;
            }
        }
    }

    return real_factory_make(factoryname, name);
}
