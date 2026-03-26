/*
 * camera-relay-monitor — v4l2loopback frame relay & client monitor
 *
 * Holds the v4l2loopback device open for writing at all times, writing
 * black frames to keep ready_for_capture=1. When a capture client
 * connects, forks a GStreamer pipeline subprocess that outputs raw
 * YUY2 frames to a pipe. The monitor reads from the pipe and writes
 * to the device, seamlessly replacing black frames with real camera
 * data.
 *
 * Because the monitor NEVER releases the writer fd, there is no gap
 * in device availability during pipeline startup. Clients can STREAMON
 * at any time and will see black frames until the camera initializes
 * (typically 2-3 seconds), then real frames appear automatically.
 *
 * Events emitted on stdout (line-buffered):
 *   READY  — device open, watching for clients
 *   START  — client detected, pipeline starting
 *   STOP   — clients gone, pipeline stopped
 *
 * Build:  gcc -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
 * Usage:  camera-relay-monitor /dev/video0 1920 1080 -- gst-launch-1.0 ...
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>

/* Event IDs for v4l2loopback versions */
#define V4L2_EVENT_CLIENT_USAGE_OLD  (V4L2_EVENT_PRIVATE_START)
#define V4L2_EVENT_CLIENT_USAGE_NEW  (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)

static volatile sig_atomic_t running = 1;

static void handle_signal(int sig)
{
	(void)sig;
	running = 0;
}

static int xioctl(int fd, unsigned long request, void *arg)
{
	int r;
	do {
		r = ioctl(fd, request, arg);
	} while (r == -1 && errno == EINTR && running);
	return r;
}

/* Count processes (other than ours and our children) that have this
 * device open. Skips our PID and the pipeline child PID.
 *
 * Uses stat() + dev_t comparison on fd symlinks — this is path-
 * independent and works regardless of how the device was opened
 * (symlink, /dev/v4l/by-id, etc.). UID filtering skips system
 * processes for efficiency.
 */
static int count_other_openers(dev_t dev_id, pid_t our_pid,
			       pid_t child_pid)
{
	DIR *proc_dir;
	struct dirent *proc_entry;
	int count = 0;
	uid_t our_uid = getuid();

	proc_dir = opendir("/proc");
	if (!proc_dir)
		return 0;

	while ((proc_entry = readdir(proc_dir)) != NULL) {
		/* Fast reject: PID directories start with a digit */
		if (proc_entry->d_name[0] < '1' ||
		    proc_entry->d_name[0] > '9')
			continue;

		char *endp;
		long pid = strtol(proc_entry->d_name, &endp, 10);
		if (*endp != '\0' || pid <= 0)
			continue;
		if ((pid_t)pid == our_pid)
			continue;
		if (child_pid > 0 && (pid_t)pid == child_pid)
			continue;

		/* Skip processes not owned by us — avoids ~450
		 * EACCES failures on system processes. */
		char proc_path[64];
		struct stat proc_st;
		snprintf(proc_path, sizeof(proc_path),
			 "/proc/%ld", pid);
		if (stat(proc_path, &proc_st) < 0 ||
		    proc_st.st_uid != our_uid)
			continue;

		char fd_dir_path[128];
		snprintf(fd_dir_path, sizeof(fd_dir_path),
			 "/proc/%ld/fd", pid);

		DIR *fd_dir = opendir(fd_dir_path);
		if (!fd_dir)
			continue;

		struct dirent *fd_entry;
		int found = 0;
		while ((fd_entry = readdir(fd_dir)) != NULL) {
			if (fd_entry->d_name[0] == '.')
				continue;

			char link_path[384];
			struct stat st;

			snprintf(link_path, sizeof(link_path),
				 "%s/%s", fd_dir_path, fd_entry->d_name);

			if (stat(link_path, &st) == 0 &&
			    S_ISCHR(st.st_mode) &&
			    st.st_rdev == dev_id) {
				found = 1;
				break;
			}
		}
		closedir(fd_dir);
		if (found)
			count++;
	}
	closedir(proc_dir);
	return count;
}

/* Open device for writing, set format, write initial black frame.
 * Returns fd on success, -1 on failure. */
static int open_writer(const char *device, int width, int height,
		       int frame_size, const char *black_frame)
{
	int fd = open(device, O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "[monitor] Cannot open %s: %s\n",
			device, strerror(errno));
		return -1;
	}

	struct v4l2_format fmt;
	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fmt.fmt.pix.width = width;
	fmt.fmt.pix.height = height;
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	fmt.fmt.pix.sizeimage = frame_size;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;

	if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0)
		fprintf(stderr, "[monitor] S_FMT warning: %s\n",
			strerror(errno));

	if (write(fd, black_frame, frame_size) != frame_size)
		fprintf(stderr, "[monitor] Initial write warning: %s\n",
			strerror(errno));

	return fd;
}

/* Try to subscribe to v4l2loopback client events.
 * Returns the event type on success, 0 on failure. */
static __u32 try_subscribe_events(int fd)
{
	struct v4l2_event_subscription sub;

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2_EVENT_CLIENT_USAGE_OLD;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
		fprintf(stderr,
			"[monitor] Using v4l2loopback 0.12.x event API\n");
		return V4L2_EVENT_CLIENT_USAGE_OLD;
	}

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2_EVENT_CLIENT_USAGE_NEW;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
		fprintf(stderr,
			"[monitor] Using v4l2loopback 0.13+ event API\n");
		return V4L2_EVENT_CLIENT_USAGE_NEW;
	}

	return 0;
}

/* Read exactly n bytes from fd. Returns n on success, <n on EOF/error. */
static int read_full(int fd, char *buf, int n)
{
	int total = 0;
	while (total < n) {
		int r = read(fd, buf + total, n - total);
		if (r <= 0) {
			if (r == -1 && errno == EINTR)
				continue;
			return total;  /* EOF or error */
		}
		total += r;
	}
	return total;
}

/* Start pipeline subprocess. Stdout goes to a pipe.
 * Returns pipe read fd on success, -1 on failure. Sets *child_pid. */
static int start_pipeline(char **cmd, pid_t *child_pid)
{
	/* Log the pipeline command for debugging */
	fprintf(stderr, "[monitor] Pipeline:");
	for (int i = 0; cmd[i]; i++)
		fprintf(stderr, " %s", cmd[i]);
	fprintf(stderr, "\n");

	int pipefd[2];
	if (pipe(pipefd) < 0) {
		fprintf(stderr, "[monitor] pipe() failed: %s\n",
			strerror(errno));
		return -1;
	}

	/* Pipe buffer must be >= frame size to avoid stalls.
	 * YUY2 1920x1080 = ~4MB per frame. With a 1MB pipe,
	 * each frame needs multiple fill/drain cycles causing lag.
	 * Request 8MB (2 frames) so a full frame can be written
	 * without blocking on the reader. */
	fcntl(pipefd[0], F_SETPIPE_SZ, 8388608);

	pid_t pid = fork();
	if (pid < 0) {
		fprintf(stderr, "[monitor] fork() failed: %s\n",
			strerror(errno));
		close(pipefd[0]);
		close(pipefd[1]);
		return -1;
	}

	if (pid == 0) {
		/* Child: pipe write end → fd 3 for fdsink.
		 * Redirect stdout to /dev/null so gst-launch's
		 * status messages don't corrupt the frame stream. */
		close(pipefd[0]);
		dup2(pipefd[1], 3);
		close(pipefd[1]);
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, STDOUT_FILENO);
			close(devnull);
		}
		execvp(cmd[0], cmd);
		fprintf(stderr, "[monitor] exec failed: %s\n",
			strerror(errno));
		_exit(127);
	}

	/* Parent: close write end, return read end */
	close(pipefd[1]);
	*child_pid = pid;
	return pipefd[0];
}

/* Stop pipeline subprocess and reap it. */
static void stop_pipeline(pid_t pid, int pipe_fd)
{
	if (pipe_fd >= 0)
		close(pipe_fd);

	kill(pid, SIGTERM);

	/* Wait up to 3 seconds for graceful exit */
	for (int i = 0; i < 30; i++) {
		int status;
		if (waitpid(pid, &status, WNOHANG) != 0)
			return;
		usleep(100000);
	}

	/* Force kill */
	kill(pid, SIGKILL);
	waitpid(pid, NULL, 0);
}

int main(int argc, char *argv[])
{
	const char *device;
	int width = 1920, height = 1080;
	int frame_size;

	if (argc < 4) {
		fprintf(stderr,
			"Usage: %s <device> <width> <height>"
			" -- <pipeline command...>\n", argv[0]);
		return 1;
	}

	device = argv[1];
	width = atoi(argv[2]);
	height = atoi(argv[3]);
	frame_size = width * height * 2;  /* YUY2: 2 bytes/pixel */

	/* Find pipeline command after "--" */
	char **pipeline_cmd = NULL;
	for (int i = 4; i < argc; i++) {
		if (strcmp(argv[i], "--") == 0 && i + 1 < argc) {
			pipeline_cmd = &argv[i + 1];
			break;
		}
	}
	if (!pipeline_cmd) {
		fprintf(stderr, "ERROR: No pipeline command given after --\n");
		return 1;
	}

	setvbuf(stdout, NULL, _IOLBF, 0);

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);
	signal(SIGPIPE, SIG_IGN);

	/* Allocate YUY2 black frame (BT.601: Y=0x10, U=V=0x80) */
	char *black_frame = malloc(frame_size);
	if (!black_frame) {
		fprintf(stderr, "ERROR: Cannot allocate frame buffer\n");
		return 1;
	}
	for (int i = 0; i < frame_size; i += 4) {
		black_frame[i + 0] = 0x10;
		black_frame[i + 1] = 0x80;
		black_frame[i + 2] = 0x10;
		black_frame[i + 3] = 0x80;
	}

	/* Allocate relay frame buffer */
	char *frame_buf = malloc(frame_size);
	if (!frame_buf) {
		fprintf(stderr, "ERROR: Cannot allocate relay buffer\n");
		free(black_frame);
		return 1;
	}

	/* Get device stat for /proc polling (dev_t comparison) */
	struct stat dev_stat;
	if (stat(device, &dev_stat) < 0) {
		fprintf(stderr, "ERROR: Cannot stat %s: %s\n",
			device, strerror(errno));
		free(black_frame);
		free(frame_buf);
		return 1;
	}
	pid_t our_pid = getpid();

	/* Open writer and set up device */
	int fd = open_writer(device, width, height, frame_size, black_frame);
	if (fd < 0) {
		free(black_frame);
		free(frame_buf);
		return 1;
	}

	/* Try event-based client detection */
	__u32 event_type = try_subscribe_events(fd);
	int use_events = (event_type != 0);

	if (use_events)
		fprintf(stderr,
			"[monitor] Using events + /proc fallback\n");
	else
		fprintf(stderr,
			"[monitor] No event support, using /proc polling\n");

	fprintf(stderr, "[monitor] Watching %s (%dx%d) dev=%u:%u\n",
		device, width, height,
		major(dev_stat.st_rdev), minor(dev_stat.st_rdev));
	printf("READY\n");

	/*
	 * Main loop: IDLE and RELAY states.
	 *
	 * IDLE: write black frames at ~1fps, watch for client connections.
	 *       Writer fd is always held — ready_for_capture never drops.
	 *       Uses v4l2loopback events when available (zero CPU), with
	 *       /proc verification to filter PipeWire false starts.
	 *       Falls back to /proc polling if no event support.
	 *
	 * RELAY: pipeline subprocess is running, outputting frames to a
	 *        pipe. Read frames from pipe, write to device. Black
	 *        frames are written during pipeline startup (before first
	 *        real frame arrives). Monitor /proc for client disconnect.
	 *
	 * After each pipeline stop, the device fd is closed and re-opened
	 * to reset v4l2loopback's event queue (0.12.7 events break
	 * permanently after the first pipeline cycle otherwise).
	 */
	int relay_active = 0;
	int prev_clients = 0;
	pid_t child_pid = 0;
	int pipe_fd = -1;
	int rapid_fails = 0;  /* pipeline failures without success */

	if (use_events) {
		/* Drain initial event (non-blocking — may not exist) */
		struct pollfd pfd = { .fd = fd, .events = POLLPRI };
		if (poll(&pfd, 1, 200) > 0) {
			struct v4l2_event ev;
			memset(&ev, 0, sizeof(ev));
			xioctl(fd, VIDIOC_DQEVENT, &ev);
		}
	}

	int idle_polls = 0;  /* count poll timeouts for /proc fallback */

	while (running) {
		if (!relay_active) {
			/*
			 * IDLE state: write black frame, watch for clients.
			 * The write keeps ready_for_capture=1 so clients
			 * can STREAMON at any time.
			 */
			(void)!write(fd, black_frame, frame_size);

			int client_detected = 0;

			if (use_events) {
				/*
				 * Wait for v4l2loopback event (zero CPU).
				 * Use 2s timeout. On timeout, fall back to
				 * /proc check — events may be broken after
				 * a pipeline cycle on some v4l2loopback
				 * versions.
				 */
				struct pollfd pfd = {
					.fd = fd, .events = POLLPRI
				};
				int ret = poll(&pfd, 1, 2000);

				if (ret > 0 && (pfd.revents & POLLPRI)) {
					struct v4l2_event ev;
					memset(&ev, 0, sizeof(ev));
					if (xioctl(fd, VIDIOC_DQEVENT,
						   &ev) == 0) {
						/*
						 * Verify via /proc — PipeWire
						 * briefly opens the device
						 * during scanning, causing
						 * false events.
						 */
						usleep(100000);
						int clients =
							count_other_openers(
							dev_stat.st_rdev,
							our_pid, 0);
						fprintf(stderr,
							"[monitor] Event"
							" fired, /proc"
							" clients=%d\n",
							clients);
						if (clients > 0)
							client_detected = 1;
					}
					idle_polls = 0;
				} else {
					/*
					 * Event timeout — check /proc as
					 * fallback. Events may be broken
					 * after fd re-open on some versions.
					 */
					idle_polls++;
					int clients = count_other_openers(
						dev_stat.st_rdev,
						our_pid, 0);
					if (clients > 0) {
						fprintf(stderr,
							"[monitor] /proc"
							" fallback:"
							" clients=%d\n",
							clients);
						client_detected = 1;
					}
				}
			} else {
				/*
				 * No event support — poll /proc every 2s.
				 */
				int clients = count_other_openers(
					dev_stat.st_rdev, our_pid, 0);
				if (clients > 0 && prev_clients == 0)
					client_detected = 1;
				prev_clients = clients;
				if (!client_detected)
					sleep(2);
			}

			if (client_detected) {
				fprintf(stderr,
					"[monitor] Client connected"
					" — starting pipeline\n");
				pipe_fd = start_pipeline(pipeline_cmd,
							 &child_pid);
				if (pipe_fd < 0) {
					fprintf(stderr,
						"[monitor] Failed to"
						" start pipeline\n");
					continue;
				}
				relay_active = 1;
				prev_clients = 0;
				printf("START\n");
			}
		} else {
			/*
			 * RELAY state: read frames from pipeline pipe,
			 * write to device. During pipeline startup
			 * (before first frame), write black frames to
			 * keep the device active for clients.
			 */
			int need_stop = 0;

			/*
			 * Tight blocking read — no poll().
			 * read_full blocks until a full frame arrives,
			 * then we write immediately. This is critical
			 * for low latency — poll() between frames
			 * causes periodic stutter.
			 *
			 * During pipeline startup (~2-3s), read_full
			 * blocks until the first frame arrives. The
			 * last black frame written in IDLE state keeps
			 * the device active for clients during this
			 * time. If the pipeline dies, read_full returns
			 * short and we handle it below.
			 */
			int n = read_full(pipe_fd, frame_buf,
					  frame_size);
			if (n == frame_size) {
				(void)!write(fd, frame_buf,
					     frame_size);
				rapid_fails = 0;
			} else {
				fprintf(stderr,
					"[monitor] Pipeline"
					" EOF/error (read=%d"
					" of %d)\n",
					n, frame_size);
				need_stop = 1;
			}

			/*
			 * Check client count via /proc every ~1 second.
			 * At ~30fps, check every 30th frame.
			 */
			static int check_tick = 0;
			static int idle_ticks = 0;
			static int had_clients = 0;

			if (!need_stop && ++check_tick % 30 == 0) {
				int clients = count_other_openers(
					dev_stat.st_rdev, our_pid,
					child_pid);

				if (clients > 0)
					had_clients = 1;

				if (clients <= 0)
					idle_ticks++;
				else
					idle_ticks = 0;

				/*
				 * Stop when:
				 * - Had clients and they're all gone
				 *   for 3+ seconds
				 * - Never saw any clients after 10
				 *   seconds (false start from scan)
				 */
				if ((had_clients && idle_ticks >= 2) ||
				    (!had_clients && idle_ticks >= 10))
					need_stop = 1;
			}

			if (need_stop) {
				int clients = count_other_openers(
					dev_stat.st_rdev, our_pid,
					child_pid);
				fprintf(stderr,
					"[monitor] Stopping pipeline"
					" (clients=%d)\n", clients);

				stop_pipeline(child_pid, pipe_fd);
				relay_active = 0;
				pipe_fd = -1;
				child_pid = 0;
				check_tick = 0;
				idle_ticks = 0;
				had_clients = 0;
				prev_clients = 0;
				printf("STOP\n");

				/*
				 * Re-open device to reset v4l2loopback
				 * event queue. Without this, events
				 * break permanently on 0.12.7 after the
				 * first pipeline cycle.
				 */
				if (use_events) {
					close(fd);
					fd = open_writer(device, width,
						height, frame_size,
						black_frame);
					if (fd < 0) {
						fprintf(stderr,
							"[monitor] "
							"Re-open "
							"failed!\n");
						running = 0;
						break;
					}
					event_type =
						try_subscribe_events(fd);
					if (event_type == 0) {
						fprintf(stderr,
							"[monitor] "
							"Event re-sub"
							" failed,"
							" using /proc"
							" polling\n");
						use_events = 0;
					} else {
						/* Drain initial event
						 * (non-blocking — may
						 * not exist on all
						 * v4l2loopback versions) */
						struct pollfd pfd = {
							.fd = fd,
							.events = POLLPRI
						};
						if (poll(&pfd, 1, 200)
						    > 0) {
							struct v4l2_event ev;
							memset(&ev, 0,
							       sizeof(ev));
							xioctl(fd,
							       VIDIOC_DQEVENT,
							       &ev);
						}
					}
				}

				/*
				 * Check if clients remain. The IDLE
				 * loop will catch them on the next
				 * iteration, but checking here avoids
				 * a brief gap.
				 *
				 * Stop retrying if the pipeline keeps
				 * failing rapidly (e.g. syntax error).
				 */
				rapid_fails++;
				int remaining = count_other_openers(
					dev_stat.st_rdev, our_pid, 0);
				if (remaining > 0 && rapid_fails < 3) {
					fprintf(stderr,
						"[monitor] %d client(s)"
						" still connected"
						" — restarting\n",
						remaining);
					pipe_fd = start_pipeline(
						pipeline_cmd,
						&child_pid);
					if (pipe_fd >= 0) {
						relay_active = 1;
						printf("START\n");
					}
				} else if (rapid_fails >= 3) {
					fprintf(stderr,
						"[monitor] Pipeline"
						" failed %d times,"
						" not retrying\n",
						rapid_fails);
					rapid_fails = 0;
				}
			}
		}
	}

	/* Cleanup */
	fprintf(stderr, "[monitor] Shutting down\n");
	if (relay_active)
		stop_pipeline(child_pid, pipe_fd);
	free(frame_buf);
	free(black_frame);
	if (fd >= 0)
		close(fd);
	return 0;
}
