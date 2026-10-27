/*
 * Offline microSD PCM recorder and BLE sync for OpenPendant.
 */
#include "sd_offline.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ff.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/crc.h>
#include <zephyr/sys/printk.h>

#define SD_DISK_NAME "SD"
#define SD_MOUNT_PT  "/SD:"
#define SD_OP_DIR    "/SD:/op"
#define SD_MIN_FREE  (1U * 1024U * 1024U)
#define SD_ROTATE_B  (28U * 16000U * 2U) /* ~28 s of s16le mono */
#define SD_WBUF_SZ   4096
#define SD_MAX_PENDING 48
#define SD_PATH_MAX  96
#define SD_SESS_MAX  24

struct pending_entry {
	uint8_t id[8];
	uint8_t kind;
	uint16_t seq;
	uint32_t size;
	char path[SD_PATH_MAX];
	char session[SD_SESS_MAX];
};

static FATFS sd_fat;
static struct fs_mount_t sd_mnt = {
	.type = FS_FATFS,
	.fs_data = &sd_fat,
	.mnt_point = SD_MOUNT_PT,
};
static bool sd_mounted;
static struct k_mutex sd_lock;

static bool meeting_on;
static bool note_on;
static struct fs_file_t rec_file;
static bool rec_open;
static char rec_path[SD_PATH_MAX];
static char meeting_session[SD_SESS_MAX];
static uint32_t meeting_id;
static uint16_t meeting_seq;
static uint32_t file_bytes;
static uint8_t wbuf[SD_WBUF_SZ];
static size_t wbuf_len;

static struct pending_entry pending[SD_MAX_PENDING];
static uint16_t pending_n;
static uint16_t list_idx;

static uint8_t open_id[8];
static bool open_valid;
static char open_path[SD_PATH_MAX];
static uint32_t open_size;

static void close_rec_file(void);
static void scan_unlocked(void);

static int sd_mount(void)
{
	int err;
	struct fs_statvfs st;

	if (sd_mounted) {
		/* Stale flag after another path deinited the disk? Remount. */
		if (fs_statvfs(SD_MOUNT_PT, &st) == 0) {
			return 0;
		}
		printk("SD mount stale — remounting\n");
		sd_mounted = false;
		(void)disk_access_ioctl(SD_DISK_NAME, DISK_IOCTL_CTRL_DEINIT,
					NULL);
	}
	err = disk_access_ioctl(SD_DISK_NAME, DISK_IOCTL_CTRL_INIT, NULL);
	if (err) {
		(void)disk_access_ioctl(SD_DISK_NAME, DISK_IOCTL_CTRL_DEINIT,
					NULL);
		k_msleep(20);
		err = disk_access_ioctl(SD_DISK_NAME, DISK_IOCTL_CTRL_INIT,
					NULL);
		if (err) {
			printk("SD disk init failed (%d)\n", err);
			return err;
		}
	}
	err = fs_mount(&sd_mnt);
	if (err == -EBUSY || err == -EEXIST) {
		/* Volume already mounted — reuse it. */
		sd_mounted = true;
		return 0;
	}
	if (err) {
		printk("SD fs_mount failed (%d)\n", err);
		(void)disk_access_ioctl(SD_DISK_NAME, DISK_IOCTL_CTRL_DEINIT,
					NULL);
		return err;
	}
	sd_mounted = true;
	return 0;
}

void sd_offline_unmount(void)
{
	k_mutex_lock(&sd_lock, K_FOREVER);
	if (rec_open) {
		close_rec_file();
	}
	meeting_on = false;
	note_on = false;
	if (sd_mounted) {
		fs_unmount(&sd_mnt);
		sd_mounted = false;
	}
	(void)disk_access_ioctl(SD_DISK_NAME, DISK_IOCTL_CTRL_DEINIT, NULL);
	k_mutex_unlock(&sd_lock);
}

/* Returns free bytes, or UINT64_MAX if unknown (do not treat as full). */
static uint64_t sd_free_bytes(void)
{
	struct fs_statvfs st;

	if (fs_statvfs(SD_MOUNT_PT, &st) != 0) {
		return UINT64_MAX;
	}
	if (st.f_frsize == 0) {
		return UINT64_MAX;
	}
	return (uint64_t)st.f_bfree * (uint64_t)st.f_frsize;
}

static void id_from_path(const char *path, uint8_t kind, uint16_t seq,
			 uint8_t out[8])
{
	uint32_t c = crc32_ieee((const uint8_t *)path, strlen(path));

	sys_put_le32(c, &out[0]);
	sys_put_le16(seq, &out[4]);
	out[6] = kind;
	out[7] = (uint8_t)(c >> 24);
}

static int flush_wbuf(void)
{
	ssize_t n;

	if (!rec_open || wbuf_len == 0) {
		return 0;
	}
	n = fs_write(&rec_file, wbuf, wbuf_len);
	if (n < 0 || (size_t)n != wbuf_len) {
		return n < 0 ? (int)n : -EIO;
	}
	file_bytes += (uint32_t)wbuf_len;
	wbuf_len = 0;
	return 0;
}

static void close_rec_file(void)
{
	if (!rec_open) {
		return;
	}
	(void)flush_wbuf();
	fs_sync(&rec_file);
	fs_close(&rec_file);
	rec_open = false;
	wbuf_len = 0;
}

static bool name_is_pcm(const char *name)
{
	size_t n = strlen(name);

	if (n < 5) {
		return false;
	}
	return strcmp(&name[n - 4], ".pcm") == 0 ||
	       strcmp(&name[n - 4], ".PCM") == 0;
}

/* 8.3 names at the card root — same place the SD self-test writes
 * opentest.txt. Long names (m_xxxxxxxx_000.pcm) fail when LFN is off.
 * M + 5 hex id + 2 seq = 8 chars, e.g. M1A2B300.PCM
 */
static int open_meeting_chunk(void)
{
	int err;

	snprintk(rec_path, sizeof(rec_path), "%s/M%05X%02u.PCM", SD_MOUNT_PT,
		 (unsigned int)meeting_id, meeting_seq);
	fs_file_t_init(&rec_file);
	err = fs_open(&rec_file, rec_path, FS_O_CREATE | FS_O_WRITE | FS_O_TRUNC);
	if (err) {
		printk("SD meeting open failed (%d) %s\n", err, rec_path);
		return err;
	}
	rec_open = true;
	file_bytes = 0;
	wbuf_len = 0;
	printk("SD meeting chunk %s\n", rec_path);
	return 0;
}

static int start_meeting(void)
{
	int err;

	err = sd_mount();
	if (err) {
		printk("SD mount for meeting failed (%d)\n", err);
		return err;
	}
	{
		uint64_t free_b = sd_free_bytes();

		if (free_b != UINT64_MAX && free_b < SD_MIN_FREE) {
			printk("SD full (%llu B free) — refuse meeting\n",
			       (unsigned long long)free_b);
			return -ENOSPC;
		}
	}
	meeting_id = (k_uptime_get_32() >> 4) & 0xFFFFFU;
	meeting_seq = 0;
	snprintk(meeting_session, sizeof(meeting_session), "M%05X",
		 (unsigned int)meeting_id);
	err = open_meeting_chunk();
	if (err) {
		return err;
	}
	meeting_on = true;
	printk("SD meeting START %s\n", meeting_session);
	return 0;
}

static void stop_meeting(void)
{
	if (!meeting_on) {
		return;
	}
	close_rec_file();
	meeting_on = false;
	printk("SD meeting STOP\n");
	scan_unlocked();
}

static int start_note(void)
{
	uint32_t t = k_uptime_get_32() & 0xFFFFFFFU;
	char sess[SD_SESS_MAX];
	int err;

	err = sd_mount();
	if (err) {
		return err;
	}
	{
		uint64_t free_b = sd_free_bytes();

		if (free_b != UINT64_MAX && free_b < SD_MIN_FREE) {
			return -ENOSPC;
		}
	}
	if (meeting_on && rec_open) {
		close_rec_file();
		meeting_seq++;
	}
	snprintk(sess, sizeof(sess), "N%07X", (unsigned int)t);
	snprintk(rec_path, sizeof(rec_path), "%s/%s.PCM", SD_MOUNT_PT, sess);
	fs_file_t_init(&rec_file);
	err = fs_open(&rec_file, rec_path, FS_O_CREATE | FS_O_WRITE | FS_O_TRUNC);
	if (err) {
		printk("SD note open failed (%d) %s\n", err, rec_path);
		if (meeting_on) {
			(void)open_meeting_chunk();
		}
		return err;
	}
	rec_open = true;
	file_bytes = 0;
	wbuf_len = 0;
	note_on = true;
	printk("SD note START %s\n", sess);
	return 0;
}

static void stop_note(void)
{
	if (!note_on) {
		return;
	}
	close_rec_file();
	note_on = false;
	printk("SD note STOP\n");
	if (meeting_on) {
		(void)open_meeting_chunk();
	}
	scan_unlocked();
}

static int add_pending(const char *path, uint8_t kind, uint16_t seq,
		       const char *session, uint32_t size)
{
	struct pending_entry *e;

	if (pending_n >= SD_MAX_PENDING) {
		return -ENOMEM;
	}
	e = &pending[pending_n++];
	memset(e, 0, sizeof(*e));
	e->kind = kind;
	e->seq = seq;
	e->size = size;
	strncpy(e->path, path, sizeof(e->path) - 1);
	if (session) {
		strncpy(e->session, session, sizeof(e->session) - 1);
	}
	id_from_path(path, kind, seq, e->id);
	return 0;
}

static uint32_t file_size_path(const char *path)
{
	struct fs_dirent ent;

	if (fs_stat(path, &ent) != 0) {
		return 0;
	}
	return (uint32_t)ent.size;
}

static void add_pcm_from_name(const char *dir, const char *name)
{
	char path[SD_PATH_MAX];
	char stem[SD_SESS_MAX];
	size_t n;
	char kindc;
	uint16_t seq = 0;

	if (!name_is_pcm(name)) {
		return;
	}
	snprintk(path, sizeof(path), "%s/%s", dir, name);
	n = strlen(name);
	if (n < 5 || n - 4 >= sizeof(stem)) {
		return;
	}
	memcpy(stem, name, n - 4);
	stem[n - 4] = '\0';
	kindc = stem[0];
	if (kindc == 'n' || kindc == 'N') {
		(void)add_pending(path, SD_KIND_NOTE, 0, stem,
				  file_size_path(path));
		return;
	}
	if (kindc != 'm' && kindc != 'M') {
		return;
	}
	/* 8.3: MxxxxxSS  → session Mxxxxx, seq SS */
	if (strlen(stem) >= 8 && stem[1] != '_') {
		char sess[SD_SESS_MAX];

		memcpy(sess, stem, 6);
		sess[6] = '\0';
		seq = (uint16_t)strtoul(&stem[6], NULL, 10);
		(void)add_pending(path, SD_KIND_MEETING, seq, sess,
				  file_size_path(path));
		return;
	}
	if (stem[1] == '_') {
		char *last_us = strrchr(stem, '_');

		if (last_us && last_us != stem) {
			seq = (uint16_t)strtoul(last_us + 1, NULL, 10);
			*last_us = '\0';
		}
		(void)add_pending(path, SD_KIND_MEETING, seq, stem,
				  file_size_path(path));
	}
}

static void scan_dir(const char *dir)
{
	struct fs_dir_t d;
	struct fs_dirent ent;
	char path[SD_PATH_MAX];

	fs_dir_t_init(&d);
	if (fs_opendir(&d, dir) != 0) {
		return;
	}
	while (fs_readdir(&d, &ent) == 0 && ent.name[0] != '\0') {
		if (ent.type == FS_DIR_ENTRY_DIR) {
			if ((ent.name[0] == 'm' || ent.name[0] == 'M') &&
			    ent.name[1] == '_') {
				snprintk(path, sizeof(path), "%s/%s", dir,
					 ent.name);
				scan_dir(path);
			}
			continue;
		}
		add_pcm_from_name(dir, ent.name);
	}
	fs_closedir(&d);
}

static void scan_unlocked(void)
{
	pending_n = 0;
	list_idx = 0;
	if (sd_mount() != 0) {
		return;
	}
	scan_dir(SD_MOUNT_PT);
	scan_dir(SD_OP_DIR);
	printk("SD pending clips: %u\n", pending_n);
}

void sd_offline_scan(void)
{
	k_mutex_lock(&sd_lock, K_FOREVER);
	scan_unlocked();
	k_mutex_unlock(&sd_lock);
}

void sd_offline_init(void)
{
	k_mutex_init(&sd_lock);
	fs_file_t_init(&rec_file);
	/* Do not mount/scan here — SPI SD init can block for seconds (or hang
	 * with no card) and delays BLE advertising. Scan on first use.
	 */
	pending_n = 0;
	list_idx = 0;
}

bool sd_offline_recording(void)
{
	return meeting_on || note_on;
}

bool sd_offline_meeting_active(void)
{
	return meeting_on;
}

uint16_t sd_offline_pending_count(void)
{
	return pending_n;
}

int sd_offline_meeting_toggle(void)
{
	int err = 0;

	k_mutex_lock(&sd_lock, K_FOREVER);
	/* Don't block meetings on a stuck offline note. */
	if (note_on) {
		stop_note();
	}
	if (meeting_on) {
		stop_meeting();
	} else {
		err = start_meeting();
	}
	k_mutex_unlock(&sd_lock);
	return err;
}

int sd_offline_note_start(void)
{
	int err;

	k_mutex_lock(&sd_lock, K_FOREVER);
	err = start_note();
	k_mutex_unlock(&sd_lock);
	return err;
}

int sd_offline_note_stop(void)
{
	k_mutex_lock(&sd_lock, K_FOREVER);
	stop_note();
	k_mutex_unlock(&sd_lock);
	return 0;
}

void sd_offline_abort_for_live(void)
{
	k_mutex_lock(&sd_lock, K_FOREVER);
	if (note_on) {
		stop_note();
	}
	if (meeting_on) {
		stop_meeting();
	}
	k_mutex_unlock(&sd_lock);
}

void sd_offline_finalize(void)
{
	k_mutex_lock(&sd_lock, K_FOREVER);
	if (note_on) {
		stop_note();
	}
	if (meeting_on) {
		stop_meeting();
	}
	/* Refresh catalog after closing files (BLE connect / sync prep). */
	scan_unlocked();
	k_mutex_unlock(&sd_lock);
}

void sd_offline_write_pcm(const void *data, size_t len)
{
	const uint8_t *p = data;
	int err;

	if (!meeting_on && !note_on) {
		return;
	}
	k_mutex_lock(&sd_lock, K_FOREVER);
	if (!rec_open) {
		k_mutex_unlock(&sd_lock);
		return;
	}
	while (len > 0) {
		size_t space = SD_WBUF_SZ - wbuf_len;
		size_t n = len < space ? len : space;

		memcpy(&wbuf[wbuf_len], p, n);
		wbuf_len += n;
		p += n;
		len -= n;
		if (wbuf_len >= SD_WBUF_SZ) {
			err = flush_wbuf();
			if (err) {
				printk("SD write err %d — stop rec\n", err);
				close_rec_file();
				meeting_on = false;
				note_on = false;
				break;
			}
		}
	}
	if (meeting_on && !note_on && file_bytes + wbuf_len >= SD_ROTATE_B) {
		close_rec_file();
		meeting_seq++;
		{
			uint64_t free_b = sd_free_bytes();

			if ((free_b != UINT64_MAX && free_b < SD_MIN_FREE) ||
			    open_meeting_chunk() != 0) {
				printk("SD rotate failed — end meeting\n");
				meeting_on = false;
			}
		}
	}
	k_mutex_unlock(&sd_lock);
}

static struct pending_entry *find_pending(const uint8_t id[8])
{
	for (uint16_t i = 0; i < pending_n; i++) {
		if (memcmp(pending[i].id, id, 8) == 0) {
			return &pending[i];
		}
	}
	return NULL;
}

static void send_list_entry(const struct pending_entry *e, sd_data_send_fn send)
{
	uint8_t pkt[64];

	memset(pkt, 0, sizeof(pkt));
	pkt[0] = SD_MSG_LIST;
	pkt[1] = e->kind;
	memcpy(&pkt[2], e->id, 8);
	sys_put_le32(e->size, &pkt[10]);
	sys_put_le16(e->seq, &pkt[14]);
	strncpy((char *)&pkt[16], e->session, 32);
	send(pkt, 48);
}

static void send_list_end(sd_data_send_fn send)
{
	uint8_t pkt[16];

	memset(pkt, 0, sizeof(pkt));
	pkt[0] = SD_MSG_END;
	send(pkt, 16);
}

static int ctrl_list(sd_data_send_fn send)
{
	k_mutex_lock(&sd_lock, K_FOREVER);
	if (list_idx == 0) {
		scan_unlocked();
	}
	if (list_idx >= pending_n) {
		list_idx = 0;
		k_mutex_unlock(&sd_lock);
		send_list_end(send);
		return 0;
	}
	send_list_entry(&pending[list_idx], send);
	list_idx++;
	k_mutex_unlock(&sd_lock);
	return 0;
}

static int ctrl_open(const uint8_t id[8])
{
	struct pending_entry *e;

	k_mutex_lock(&sd_lock, K_FOREVER);
	e = find_pending(id);
	if (!e) {
		open_valid = false;
		k_mutex_unlock(&sd_lock);
		return -ENOENT;
	}
	memcpy(open_id, id, 8);
	strncpy(open_path, e->path, sizeof(open_path) - 1);
	open_size = e->size;
	open_valid = true;
	k_mutex_unlock(&sd_lock);
	printk("SD open %s (%u B)\n", open_path, open_size);
	return 0;
}

static int ctrl_read(uint32_t offset, uint16_t want, sd_data_send_fn send)
{
	struct fs_file_t f;
	uint8_t pkt[244];
	ssize_t n;
	int err;
	uint16_t max_payload = 220;

	if (!open_valid) {
		return -EINVAL;
	}
	if (want > max_payload) {
		want = max_payload;
	}
	if (offset >= open_size) {
		want = 0;
	} else if ((uint32_t)want > open_size - offset) {
		want = (uint16_t)(open_size - offset);
	}

	k_mutex_lock(&sd_lock, K_FOREVER);
	(void)sd_mount();
	fs_file_t_init(&f);
	err = fs_open(&f, open_path, FS_O_READ);
	if (err) {
		k_mutex_unlock(&sd_lock);
		return err;
	}
	if (offset > 0) {
		err = fs_seek(&f, offset, FS_SEEK_SET);
		if (err) {
			fs_close(&f);
			k_mutex_unlock(&sd_lock);
			return err;
		}
	}
	pkt[0] = SD_MSG_READ;
	memcpy(&pkt[1], open_id, 8);
	sys_put_le32(offset, &pkt[9]);
	n = want ? fs_read(&f, &pkt[15], want) : 0;
	fs_close(&f);
	k_mutex_unlock(&sd_lock);
	if (n < 0) {
		return (int)n;
	}
	sys_put_le16((uint16_t)n, &pkt[13]);
	send(pkt, (uint16_t)(15 + n));
	return 0;
}

static int unlink_path(const char *path)
{
	return fs_unlink(path);
}

static int ctrl_delete(const uint8_t id[8])
{
	struct pending_entry *e;
	char meta[SD_PATH_MAX];
	char dir[SD_PATH_MAX];
	const char *slash;
	int err;

	k_mutex_lock(&sd_lock, K_FOREVER);
	e = find_pending(id);
	if (!e) {
		k_mutex_unlock(&sd_lock);
		return -ENOENT;
	}
	(void)sd_mount();
	err = unlink_path(e->path);
	/* companion meta: foo.pcm → foo.meta.txt OR dir/000.meta.txt */
	if (e->kind == SD_KIND_NOTE) {
		snprintk(meta, sizeof(meta), "%s", e->path);
		size_t n = strlen(meta);

		if (n > 4) {
			memcpy(&meta[n - 4], ".meta.txt", 10);
			(void)unlink_path(meta);
		}
	} else {
		snprintk(meta, sizeof(meta), "%s", e->path);
		size_t n = strlen(meta);

		if (n > 4) {
			/* 000.pcm → 000.meta.txt */
			memcpy(&meta[n - 4], ".meta.txt", 10);
			(void)unlink_path(meta);
		}
		slash = strrchr(e->path, '/');
		if (slash) {
			size_t dlen = (size_t)(slash - e->path);

			if (dlen < sizeof(dir)) {
				memcpy(dir, e->path, dlen);
				dir[dlen] = '\0';
				/* try remove dir if empty */
				(void)fs_unlink(dir);
			}
		}
	}
	open_valid = false;
	scan_unlocked();
	k_mutex_unlock(&sd_lock);
	printk("SD delete id err=%d\n", err);
	return err;
}

int sd_offline_ctrl(const uint8_t *buf, uint16_t len, sd_data_send_fn send)
{
	if (len < 1 || send == NULL) {
		return -EINVAL;
	}
	switch (buf[0]) {
	case SD_CTRL_LIST:
		return ctrl_list(send);
	case SD_CTRL_OPEN:
		if (len < 9) {
			return -EINVAL;
		}
		return ctrl_open(&buf[1]);
	case SD_CTRL_READ: {
		uint32_t off;
		uint16_t want;

		if (len < 7) {
			return -EINVAL;
		}
		off = sys_get_le32(&buf[1]);
		want = sys_get_le16(&buf[5]);
		return ctrl_read(off, want, send);
	}
	case SD_CTRL_DELETE:
		if (len < 9) {
			return -EINVAL;
		}
		return ctrl_delete(&buf[1]);
	default:
		return -ENOTSUP;
	}
}
