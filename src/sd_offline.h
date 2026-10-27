/*
 * Offline microSD capture + BLE sync helpers for OpenPendant.
 * SPI: CLK D9, MOSI D8, MISO D7, CS D6. Mount point /SD:
 */
#ifndef SD_OFFLINE_H_
#define SD_OFFLINE_H_

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#define SD_CTRL_LIST   0x10
#define SD_CTRL_OPEN   0x11
#define SD_CTRL_READ   0x12
#define SD_CTRL_DELETE 0x13

#define SD_KIND_MEETING 1
#define SD_KIND_NOTE    2

#define SD_MSG_LIST 0x10
#define SD_MSG_READ 0x12
#define SD_MSG_END  0x1F

typedef void (*sd_data_send_fn)(const uint8_t *data, uint16_t len);

void sd_offline_init(void);

bool sd_offline_recording(void);
bool sd_offline_meeting_active(void);
uint16_t sd_offline_pending_count(void);

/* Button-driven offline capture (only when live PCM notify is off). */
int sd_offline_meeting_toggle(void);
int sd_offline_note_start(void);
int sd_offline_note_stop(void);

/* Stop offline capture if the phone arms live PCM. */
void sd_offline_abort_for_live(void);

/* Flush/close any open offline files (e.g. on BLE connect before sync). */
void sd_offline_finalize(void);

/* Write one PDM block (typically 240 B). Safe no-op if idle. */
void sd_offline_write_pcm(const void *data, size_t len);

/* Sync control ops; may call send() with SD data notifies. */
int sd_offline_ctrl(const uint8_t *buf, uint16_t len, sd_data_send_fn send);

/* Rebuild pending catalog (after delete or boot). */
void sd_offline_scan(void);

/* Tear down mount (SD self-test). Stops any offline capture. */
void sd_offline_unmount(void);

#endif /* SD_OFFLINE_H_ */
