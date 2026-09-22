/*
 * MiSTer-Pet spike: prove out the MiSTer framebuffer path.
 *
 * No SDL, no deps beyond libc. Three jobs:
 *   1. report what /dev/fb0 actually is once Main has switched to it,
 *   2. draw an unambiguous colour test pattern so we can nail channel order,
 *   3. reproduce the Menu core's B&W static and bounce a sprite over it.
 *
 * The static is ported from Menu_MiSTer/menu.sv (LFSR noise subtracted from a
 * scrolling cosine gradient). See docs/mister-framebuffer.md.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <linux/fb.h>
#include <linux/kd.h>
#include <linux/vt.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#define MISTER_CMD "/dev/MiSTer_cmd"

typedef struct {
	int w, h;
	int stride;            /* bytes per row of the mapped framebuffer */
	uint32_t rsh, gsh, bsh; /* channel shifts, taken from the fb itself */
	uint32_t amask;
	uint8_t *map;          /* NULL when running offscreen (--fake) */
	size_t maplen;
	int fd;
	uint32_t *back;        /* w*h, already in the fb's packed layout */
} target_t;

static volatile sig_atomic_t g_quit = 0;
static void on_signal(int sig) { (void)sig; g_quit = 1; }

static inline uint32_t pack(const target_t *t, uint8_t r, uint8_t g, uint8_t b)
{
	return ((uint32_t)r << t->rsh) | ((uint32_t)g << t->gsh) |
	       ((uint32_t)b << t->bsh) | t->amask;
}

static inline uint32_t gray(const target_t *t, uint8_t v) { return pack(t, v, v, v); }

/* ---------------------------------------------------------------- MiSTer ---*/

static int mister_cmd(const char *cmd)
{
	int fd = open(MISTER_CMD, O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s (is Main running?)\n", MISTER_CMD, strerror(errno));
		return -1;
	}
	size_t len = strlen(cmd);
	ssize_t n = write(fd, cmd, len);
	close(fd);
	if (n != (ssize_t)len) {
		fprintf(stderr, "write %s: %s\n", MISTER_CMD, strerror(errno));
		return -1;
	}
	printf("sent: %s", cmd);
	return 0;
}

/* -------------------------------------------------------------------- VT ---*/

static int g_vt_fd = -1;
static long g_vt_prev = KD_TEXT;

static void vt_enter(int vt)
{
	char path[32];
	int fd0 = open("/dev/tty0", O_RDWR | O_CLOEXEC);
	if (fd0 >= 0) {
		if (ioctl(fd0, VT_ACTIVATE, vt) || ioctl(fd0, VT_WAITACTIVE, vt))
			fprintf(stderr, "VT_ACTIVATE %d: %s\n", vt, strerror(errno));
		close(fd0);
	} else {
		fprintf(stderr, "open /dev/tty0: %s\n", strerror(errno));
	}

	snprintf(path, sizeof(path), "/dev/tty%d", vt);
	g_vt_fd = open(path, O_RDWR | O_CLOEXEC);
	if (g_vt_fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return;
	}
	ioctl(g_vt_fd, KDGETMODE, &g_vt_prev);
	if (ioctl(g_vt_fd, KDSETMODE, KD_GRAPHICS))
		fprintf(stderr, "KDSETMODE: %s\n", strerror(errno));
	printf("vt: switched to %s, KD_GRAPHICS\n", path);
}

static void vt_leave(void)
{
	if (g_vt_fd < 0) return;
	ioctl(g_vt_fd, KDSETMODE, g_vt_prev);
	close(g_vt_fd);
	g_vt_fd = -1;
}

/* ------------------------------------------------------------ fb target ---*/

static void describe(const struct fb_var_screeninfo *v, const struct fb_fix_screeninfo *f)
{
	printf("fb: id=\"%s\" %ux%u (virtual %ux%u) %u bpp\n",
	       f->id, v->xres, v->yres, v->xres_virtual, v->yres_virtual, v->bits_per_pixel);
	printf("fb: line_length=%u smem_len=%u smem_start=0x%lx type=%u visual=%u\n",
	       f->line_length, f->smem_len, (unsigned long)f->smem_start, f->type, f->visual);
	printf("fb: R off=%u len=%u  G off=%u len=%u  B off=%u len=%u  A off=%u len=%u\n",
	       v->red.offset, v->red.length, v->green.offset, v->green.length,
	       v->blue.offset, v->blue.length, v->transp.offset, v->transp.length);
}

static int target_open_fb(target_t *t, const char *dev, const char *pack_override)
{
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;

	t->fd = open(dev, O_RDWR | O_CLOEXEC);
	if (t->fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		return -1;
	}
	if (ioctl(t->fd, FBIOGET_VSCREENINFO, &vinfo) || ioctl(t->fd, FBIOGET_FSCREENINFO, &finfo)) {
		fprintf(stderr, "FBIOGET_*SCREENINFO: %s\n", strerror(errno));
		return -1;
	}
	describe(&vinfo, &finfo);

	if (vinfo.bits_per_pixel != 32) {
		fprintf(stderr, "need 32bpp, got %u -- try --fbcmd W H (format 8888)\n",
		        vinfo.bits_per_pixel);
		return -1;
	}

	t->w = (int)vinfo.xres;
	t->h = (int)vinfo.yres;
	t->stride = (int)finfo.line_length;
	t->rsh = vinfo.red.offset;
	t->gsh = vinfo.green.offset;
	t->bsh = vinfo.blue.offset;
	t->amask = vinfo.transp.length ? (0xffu << vinfo.transp.offset) : 0;

	if (pack_override) {
		/* escape hatch if MiSTer_fb misreports the channel offsets */
		if (!strcmp(pack_override, "argb"))      { t->rsh = 16; t->gsh = 8; t->bsh = 0;  t->amask = 0xff000000u; }
		else if (!strcmp(pack_override, "abgr")) { t->rsh = 0;  t->gsh = 8; t->bsh = 16; t->amask = 0xff000000u; }
		else if (!strcmp(pack_override, "rgba")) { t->rsh = 24; t->gsh = 16; t->bsh = 8; t->amask = 0xffu; }
		else if (!strcmp(pack_override, "bgra")) { t->rsh = 8;  t->gsh = 16; t->bsh = 24; t->amask = 0xffu; }
		else { fprintf(stderr, "unknown --pack %s\n", pack_override); return -1; }
		printf("pack: forced %s\n", pack_override);
	}
	printf("pack: r<<%u g<<%u b<<%u amask=0x%08x\n", t->rsh, t->gsh, t->bsh, t->amask);

	t->maplen = finfo.smem_len ? finfo.smem_len : (size_t)t->stride * t->h;
	t->map = mmap(NULL, t->maplen, PROT_READ | PROT_WRITE, MAP_SHARED, t->fd, 0);
	if (t->map == MAP_FAILED) {
		fprintf(stderr, "mmap %s: %s\n", dev, strerror(errno));
		t->map = NULL;
		return -1;
	}

	t->back = calloc((size_t)t->w * t->h, sizeof(uint32_t));
	return t->back ? 0 : -1;
}

static int target_open_fake(target_t *t, int w, int h)
{
	t->fd = -1;
	t->map = NULL;
	t->w = w;
	t->h = h;
	t->stride = w * 4;
	t->rsh = 16; t->gsh = 8; t->bsh = 0; t->amask = 0xff000000u;
	t->back = calloc((size_t)w * h, sizeof(uint32_t));
	printf("fake target: %dx%d, argb\n", w, h);
	return t->back ? 0 : -1;
}

static void target_present(const target_t *t)
{
	if (!t->map) return;
	for (int y = 0; y < t->h; y++)
		memcpy(t->map + (size_t)y * t->stride, t->back + (size_t)y * t->w,
		       (size_t)t->w * 4);
}

static void target_close(target_t *t)
{
	if (t->map) munmap(t->map, t->maplen);
	if (t->fd >= 0) close(t->fd);
	free(t->back);
}

static int dump_ppm(const target_t *t, const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f) { fprintf(stderr, "fopen %s: %s\n", path, strerror(errno)); return -1; }
	fprintf(f, "P6\n%d %d\n255\n", t->w, t->h);
	for (int i = 0; i < t->w * t->h; i++) {
		uint32_t p = t->back[i];
		uint8_t rgb[3] = { (uint8_t)(p >> t->rsh), (uint8_t)(p >> t->gsh), (uint8_t)(p >> t->bsh) };
		fwrite(rgb, 1, 3, f);
	}
	fclose(f);
	printf("wrote %s\n", path);
	return 0;
}

/* ---------------------------------------------------------------- static ---*/

/* Quarter cosine table, same shape as Menu_MiSTer/rtl/cos.sv */
static uint8_t qcos[256];

static void cos_init(void)
{
	for (int i = 0; i < 256; i++) {
		double v = 127.5 * cos((M_PI / 2.0) * (double)i / 256.0);
		int q = (int)(v + 0.5);
		qcos[i] = (uint8_t)(q > 127 ? 127 : q);
	}
}

/* cos.sv: ival = x[9]^x[8]; y = qcos[x[7:0] ^ {8{x[8]}}] ^ {~ival,{7{ival}}} */
static inline uint8_t cos8(uint32_t x)
{
	x &= 1023;
	int ival = ((x >> 9) ^ (x >> 8)) & 1;
	uint8_t idx = (uint8_t)(x & 255);
	if (x & 256) idx = (uint8_t)~idx;
	return qcos[idx] ^ (ival ? 0x7f : 0x80);
}

static uint32_t rng_state = 0x2545f491u;
static inline uint32_t rng_next(void)
{
	uint32_t x = rng_state;
	x ^= x << 13; x ^= x >> 17; x ^= x << 5;
	return rng_state = x;
}

/*
 * menu.sv: rnd_c = {rnd[0],rnd[1],rnd[2],rnd[2],rnd[2],rnd[2]}
 *          cos_g = cos_out[7:3] + 32
 *          pixel = (cos_g >= rnd_c) ? (cos_g - rnd_c) << 2 : 0
 * The core runs 240 visible lines and advances vvc by 6 per frame; scale the
 * line step so the gradient looks right at whatever height the fb gives us.
 */
static void draw_static(target_t *t, uint32_t vvc)
{
	for (int y = 0; y < t->h; y++) {
		uint32_t idx = vvc + (uint32_t)(((long)y * 960) / t->h);
		int cos_g = (cos8(idx) >> 3) + 32;
		uint32_t *row = t->back + (size_t)y * t->w;
		for (int x = 0; x < t->w; x++) {
			uint32_t r = rng_next();
			int rnd_c = (int)(((r & 1) << 5) | (((r >> 1) & 1) << 4) | (((r >> 2) & 1) ? 0x0f : 0));
			int v = (cos_g >= rnd_c) ? (cos_g - rnd_c) << 2 : 0;
			row[x] = gray(t, (uint8_t)v);
		}
	}
}

/* ---------------------------------------------------------------- sprite ---*/

#define PET_W 16
#define PET_H 16

static const char *const PET[PET_H] = {
	"................",
	"......@@@@......",
	"....@@####@@....",
	"...@########@...",
	"..@##########@..",
	"..@#@@#..#@@#@..",
	"..@#@@#..#@@#@..",
	"..@##########@..",
	"..@##########@..",
	"..@###@@@@###@..",
	"...@########@...",
	"....@@####@@....",
	"......@@@@......",
	"....@@....@@....",
	"...@##@..@##@...",
	"....@@....@@....",
};

static void draw_pet(target_t *t, int px, int py, int scale)
{
	const uint32_t body = gray(t, 235), line = gray(t, 20);
	for (int sy = 0; sy < PET_H; sy++) {
		for (int sx = 0; sx < PET_W; sx++) {
			char c = PET[sy][sx];
			if (c == '.') continue;
			uint32_t col = (c == '#') ? body : line;
			for (int dy = 0; dy < scale; dy++) {
				int y = py + sy * scale + dy;
				if (y < 0 || y >= t->h) continue;
				uint32_t *row = t->back + (size_t)y * t->w;
				for (int dx = 0; dx < scale; dx++) {
					int x = px + sx * scale + dx;
					if (x < 0 || x >= t->w) continue;
					row[x] = col;
				}
			}
		}
	}
}

/* --------------------------------------------------------------- pattern ---*/

static void draw_pattern(target_t *t)
{
	const struct { const char *name; uint8_t r, g, b; } bars[4] = {
		{ "RED",   255, 0,   0   },
		{ "GREEN", 0,   255, 0   },
		{ "BLUE",  0,   0,   255 },
		{ "WHITE", 255, 255, 255 },
	};

	for (int i = 0; i < 4; i++) {
		uint32_t v = pack(t, bars[i].r, bars[i].g, bars[i].b);
		int x0 = t->w * i / 4, x1 = t->w * (i + 1) / 4;
		for (int y = 0; y < t->h; y++)
			for (int x = x0; x < x1; x++)
				t->back[(size_t)y * t->w + x] = v;
		printf("bar %d (left to right) should read %-5s -- wrote 0x%08x\n",
		       i + 1, bars[i].name, v);
	}

	/* orientation marker: black square, top-left corner */
	int m = t->h / 8;
	for (int y = 0; y < m; y++)
		for (int x = 0; x < m; x++)
			t->back[(size_t)y * t->w + x] = pack(t, 0, 0, 0);
	printf("black square marks the TOP-LEFT corner\n");
}

/* ------------------------------------------------------------------ main ---*/

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void usage(const char *argv0)
{
	printf(
	  "usage: %s [options]\n"
	  "  --dev PATH      framebuffer device (default /dev/fb0)\n"
	  "  --fbcmd W H     ask Main for a WxH 8888 framebuffer via " MISTER_CMD "\n"
	  "  --rb 0|1        red/blue swap flag passed to fb_cmd1 (default 1)\n"
	  "  --pack FMT      force channel order: argb|abgr|rgba|bgra\n"
	  "  --vt N          switch to VT N and set KD_GRAPHICS (default: leave VTs alone)\n"
	  "  --pattern       draw the colour test pattern instead of the pet\n"
	  "  --info          print framebuffer info and exit\n"
	  "  --seconds N     run time, 0 = until Ctrl-C (default 20)\n"
	  "  --fps N         target frame rate (default 30)\n"
	  "  --scale N       pet sprite scale (default 3)\n"
	  "  --keep          do not blank the framebuffer on exit\n"
	  "  --fake WxH      render offscreen instead of to a framebuffer\n"
	  "  --ppm PATH      dump the final frame as a PPM (works with --fake)\n",
	  argv0);
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/fb0";
	const char *pack_override = NULL;
	const char *ppm = NULL;
	int fb_w = 0, fb_h = 0, rb = 1, vt = 0, scale = 3, fps = 30;
	int fake_w = 0, fake_h = 0;
	double seconds = 20.0;
	bool pattern = false, info_only = false, keep = false;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "--dev") && i + 1 < argc)        dev = argv[++i];
		else if (!strcmp(a, "--pack") && i + 1 < argc)  pack_override = argv[++i];
		else if (!strcmp(a, "--ppm") && i + 1 < argc)   ppm = argv[++i];
		else if (!strcmp(a, "--fbcmd") && i + 2 < argc) { fb_w = atoi(argv[++i]); fb_h = atoi(argv[++i]); }
		else if (!strcmp(a, "--rb") && i + 1 < argc)    rb = atoi(argv[++i]);
		else if (!strcmp(a, "--vt") && i + 1 < argc)    vt = atoi(argv[++i]);
		else if (!strcmp(a, "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
		else if (!strcmp(a, "--fps") && i + 1 < argc)   fps = atoi(argv[++i]);
		else if (!strcmp(a, "--scale") && i + 1 < argc) scale = atoi(argv[++i]);
		else if (!strcmp(a, "--fake") && i + 1 < argc)  { if (sscanf(argv[++i], "%dx%d", &fake_w, &fake_h) != 2) { usage(argv[0]); return 2; } }
		else if (!strcmp(a, "--pattern")) pattern = true;
		else if (!strcmp(a, "--info"))    info_only = true;
		else if (!strcmp(a, "--keep"))    keep = true;
		else { usage(argv[0]); return strcmp(a, "--help") ? 2 : 0; }
	}

	if (fps < 1) fps = 1;
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGHUP, on_signal);
	cos_init();

	if (fb_w && fb_h) {
		char cmd[64];
		snprintf(cmd, sizeof(cmd), "fb_cmd1 8888 %d %d %d\n", rb ? 1 : 0, fb_w, fb_h);
		if (mister_cmd(cmd)) return 1;
		usleep(400 * 1000); /* let Main reprogram the scaler and MiSTer_fb */
	}

	target_t t;
	memset(&t, 0, sizeof(t));
	t.fd = -1;

	int rc = fake_w ? target_open_fake(&t, fake_w, fake_h)
	                : target_open_fb(&t, dev, pack_override);
	if (rc) return 1;

	if (info_only) { target_close(&t); return 0; }
	if (vt) vt_enter(vt);

	int px = t.w / 2 - (PET_W * scale) / 2;
	int py = t.h / 2 - (PET_H * scale) / 2;
	int vx = 1, vy = 1;
	uint32_t vvc = 0;
	long frames = 0;
	double start = now_s(), frame = 1.0 / fps;

	while (!g_quit) {
		double t0 = now_s();
		if (seconds > 0 && t0 - start >= seconds) break;

		if (pattern) {
			draw_pattern(&t);
			target_present(&t);
			frames++;
			if (ppm) dump_ppm(&t, ppm);
			/* nothing animates; hold the pattern until the timer or a signal */
			while (!g_quit && (seconds <= 0 || now_s() - start < seconds))
				usleep(100 * 1000);
			break;
		}

		draw_static(&t, vvc);
		vvc = (vvc + 6) & 1023;

		int bob = ((frames / 8) % 2) ? scale : 0;
		draw_pet(&t, px, py + bob, scale);

		px += vx; py += vy;
		if (px <= 0 || px + PET_W * scale >= t.w) vx = -vx;
		if (py <= 0 || py + PET_H * scale + scale >= t.h) vy = -vy;

		target_present(&t);
		frames++;

		double spent = now_s() - t0;
		if (spent < frame) usleep((useconds_t)((frame - spent) * 1e6));
	}

	double elapsed = now_s() - start;
	printf("%ld frames in %.2fs (%.1f fps)\n", frames, elapsed, elapsed > 0 ? frames / elapsed : 0);

	if (ppm && !pattern) dump_ppm(&t, ppm);
	if (!keep && t.map) {
		memset(t.back, 0, (size_t)t.w * t.h * 4);
		target_present(&t);
	}
	vt_leave();
	target_close(&t);
	return 0;
}
