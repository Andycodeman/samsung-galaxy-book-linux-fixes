/*
 * camera-relay-v4l2-io-mc — udev IMPORT helper: is this node MC-centric?
 *
 * The IPU6/IPU7 ISYS drivers register one V4L2 capture node per possible
 * stream — 48 of them on a Galaxy Book4. None is a usable standalone
 * camera: they only produce frames after userspace configures the media
 * graph. The kernel says so via V4L2_CAP_IO_MC ("there is only one input
 * and/or output ... configured by userspace via the Media Controller").
 *
 * Nothing propagates that bit to udev. systemd's v4l_id derives
 * ID_V4L_CAPABILITIES from V4L2_CAP_VIDEO_CAPTURE alone and never looks at
 * V4L2_CAP_IO_MC, so all 48 advertise themselves as cameras and show up in
 * every application's device picker.
 *
 * This exports the missing bit so rules can key off the kernel's own
 * discriminator instead of matching driver-specific card names.
 *
 * Output (udev key=value on stdout):
 *   ID_V4L_IO_MC=1  — MC-centric, not a standalone camera
 *   ID_V4L_IO_MC=0  — ordinary video-node-centric device
 *
 * Exits non-zero without printing when the device cannot be queried, so a
 * failed probe leaves any value already in the udev database untouched
 * rather than downgrading the node.
 *
 * Build:  gcc -O2 -Wall -o camera-relay-v4l2-io-mc v4l2-io-mc.c
 * Usage:  camera-relay-v4l2-io-mc /dev/video0
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Added in Linux 5.9; define for builds against older UAPI headers. */
#ifndef V4L2_CAP_IO_MC
#define V4L2_CAP_IO_MC 0x20000000
#endif

int main(int argc, char *argv[])
{
	struct v4l2_capability cap;
	unsigned int caps;
	int fd, ret;

	if (argc != 2) {
		fprintf(stderr, "usage: %s DEVNODE\n", argv[0]);
		return 1;
	}

	/* O_NONBLOCK so a device that would block on open cannot stall udev. */
	fd = open(argv[1], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "%s: open: %s\n", argv[1], strerror(errno));
		return 1;
	}

	do {
		ret = ioctl(fd, VIDIOC_QUERYCAP, &cap);
	} while (ret < 0 && errno == EINTR);

	if (ret < 0) {
		fprintf(stderr, "%s: VIDIOC_QUERYCAP: %s\n", argv[1], strerror(errno));
		close(fd);
		return 1;
	}
	close(fd);

	/* device_caps describes this node; capabilities describes the whole
	 * device. Same precedence systemd's v4l_id uses. */
	caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps
							 : cap.capabilities;

	printf("ID_V4L_IO_MC=%d\n", (caps & V4L2_CAP_IO_MC) ? 1 : 0);
	return 0;
}
