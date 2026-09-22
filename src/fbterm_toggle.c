/*
 * Toggle Main's Linux framebuffer by synthesising the keypress it listens for.
 *
 * Main_MiSTer/menu.cpp:1365 hands the scaler to /dev/fb0 on F9 (on the Menu
 * core; Ctrl+Alt+F9 inside a core), gated by fb_terminal in MiSTer.ini. There
 * is no command for it on /dev/MiSTer_cmd, so an unattended daemon has to press
 * the key itself. This creates a virtual keyboard via uinput, waits for Main to
 * notice the new device, taps the key, and tears the device down.
 *
 * It is a toggle: run it again to give the display back to the core.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <linux/uinput.h>
#include <sys/ioctl.h>

static bool verbose = false;

static void msleep(long ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

static int emit(int fd, uint16_t type, uint16_t code, int32_t value)
{
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = value;
	if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) {
		fprintf(stderr, "write uinput: %s\n", strerror(errno));
		return -1;
	}
	return 0;
}

static int tap(int fd, uint16_t key, long hold_ms)
{
	if (emit(fd, EV_KEY, key, 1) || emit(fd, EV_SYN, SYN_REPORT, 0)) return -1;
	msleep(hold_ms);
	if (emit(fd, EV_KEY, key, 0) || emit(fd, EV_SYN, SYN_REPORT, 0)) return -1;
	return 0;
}

static void usage(const char *argv0)
{
	printf("usage: %s [--settle MS] [--hold MS] [--ctrl-alt] [-v]\n"
	       "  --settle MS   wait after creating the device so Main picks it up (default 1500)\n"
	       "  --hold MS     how long the key stays down (default 80)\n"
	       "  --ctrl-alt    send Ctrl+Alt+F9, needed inside a core rather than the Menu\n",
	       argv0);
}

int main(int argc, char **argv)
{
	long settle = 1500, hold = 80;
	bool ctrl_alt = false;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--settle") && i + 1 < argc) settle = atol(argv[++i]);
		else if (!strcmp(argv[i], "--hold") && i + 1 < argc) hold = atol(argv[++i]);
		else if (!strcmp(argv[i], "--ctrl-alt")) ctrl_alt = true;
		else if (!strcmp(argv[i], "-v")) verbose = true;
		else { usage(argv[0]); return strcmp(argv[i], "--help") ? 2 : 0; }
	}

	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "open /dev/uinput: %s\n", strerror(errno));
		return 1;
	}

	if (ioctl(fd, UI_SET_EVBIT, EV_KEY) || ioctl(fd, UI_SET_EVBIT, EV_SYN) ||
	    ioctl(fd, UI_SET_KEYBIT, KEY_F9) ||
	    ioctl(fd, UI_SET_KEYBIT, KEY_LEFTCTRL) ||
	    ioctl(fd, UI_SET_KEYBIT, KEY_LEFTALT)) {
		fprintf(stderr, "UI_SET_*BIT: %s\n", strerror(errno));
		return 1;
	}

	struct uinput_setup us;
	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_USB;
	us.id.vendor = 0x1209;   /* pid.codes test range */
	us.id.product = 0x0001;
	us.id.version = 1;
	snprintf(us.name, sizeof(us.name), "MiSTer-Pet Virtual Keyboard");

	if (ioctl(fd, UI_DEV_SETUP, &us) || ioctl(fd, UI_DEV_CREATE)) {
		fprintf(stderr, "UI_DEV_SETUP/CREATE: %s\n", strerror(errno));
		return 1;
	}

	if (verbose) {
		char sysname[64] = {0};
		if (!ioctl(fd, UI_GET_SYSNAME(sizeof(sysname)), sysname))
			printf("created %s as \"%s\"\n", sysname, us.name);
	}

	/* Main rescans /dev/input on hotplug; give udev and Main time to catch up. */
	msleep(settle);

	int rc = 0;
	if (ctrl_alt) {
		rc |= emit(fd, EV_KEY, KEY_LEFTCTRL, 1);
		rc |= emit(fd, EV_KEY, KEY_LEFTALT, 1);
		rc |= emit(fd, EV_SYN, SYN_REPORT, 0);
	}

	rc |= tap(fd, KEY_F9, hold);

	if (ctrl_alt) {
		rc |= emit(fd, EV_KEY, KEY_LEFTALT, 0);
		rc |= emit(fd, EV_KEY, KEY_LEFTCTRL, 0);
		rc |= emit(fd, EV_SYN, SYN_REPORT, 0);
	}

	msleep(150); /* let Main drain the event before the device disappears */
	ioctl(fd, UI_DEV_DESTROY);
	close(fd);

	if (!rc) printf("sent %sF9\n", ctrl_alt ? "Ctrl+Alt+" : "");
	return rc ? 1 : 0;
}
