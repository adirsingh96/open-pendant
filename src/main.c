#include <errno.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/dt-bindings/adc/nrf-saadc.h>
#include <hal/nrf_power.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>

#define MAX_SAMPLE_RATE  16000
#define SAMPLE_BIT_WIDTH 16
#define BLOCK_SIZE       1024

#define DEVICE_NAME     CONFIG_BT_DEVICE_NAME
#define DEVICE_NAME_LEN (sizeof(DEVICE_NAME) - 1)

/* Custom GATT UUIDs (also listed in project_context.md) */
#define PENDANT_SVC_UUID_VAL \
	BT_UUID_128_ENCODE(0x70301101, 0x4a1b, 0x4c8d, 0x9e0f, 0xa1b2c3d4e5f6)
#define PENDANT_PCM_UUID_VAL \
	BT_UUID_128_ENCODE(0x70301102, 0x4a1b, 0x4c8d, 0x9e0f, 0xa1b2c3d4e5f6)
#define PENDANT_STATUS_UUID_VAL \
	BT_UUID_128_ENCODE(0x70301103, 0x4a1b, 0x4c8d, 0x9e0f, 0xa1b2c3d4e5f6)

#define PCM_HDR_SIZE 4

K_MEM_SLAB_DEFINE_STATIC(rx_mem_slab, BLOCK_SIZE, 4, 4);

const struct device *mic_dev = DEVICE_DT_GET(DT_NODELABEL(dmic_dev));
const struct device *imu_dev = DEVICE_DT_GET(DT_NODELABEL(lsm6ds3tr_c));
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
static const struct gpio_dt_spec led_green =
	GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios);
static const struct gpio_dt_spec led_blue =
	GPIO_DT_SPEC_GET(DT_ALIAS(led2), gpios);
static const struct gpio_dt_spec user_btn =
	GPIO_DT_SPEC_GET(DT_NODELABEL(user_btn), gpios);

static const struct bt_uuid_128 pendant_svc_uuid = BT_UUID_INIT_128(PENDANT_SVC_UUID_VAL);
static const struct bt_uuid_128 pendant_pcm_uuid = BT_UUID_INIT_128(PENDANT_PCM_UUID_VAL);
static const struct bt_uuid_128 pendant_status_uuid = BT_UUID_INIT_128(PENDANT_STATUS_UUID_VAL);

/* Name in the primary packet so macOS CoreBluetooth sees it (31-byte ADV
 * cannot hold both a complete name and a 128-bit UUID). UUID is in the
 * scan response.
 */
static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA(BT_DATA_NAME_COMPLETE, DEVICE_NAME, DEVICE_NAME_LEN),
};

static const struct bt_data sd[] = {
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, PENDANT_SVC_UUID_VAL),
};

static volatile bool ble_ok;
static volatile bool pcm_notify_enabled;
static volatile bool imu_sleep;
static volatile bool status_notify_enabled;
static uint8_t status_buf[8];
static int last_volume;
static void led_set(const struct gpio_dt_spec *l, int on)
{
	if (gpio_is_ready_dt(l)) {
		gpio_pin_set_dt(l, on);
	}
}

static void note_led(bool on)
{
	led_set(&led_blue, on ? 1 : 0);
}

static void status_notify(int volume);
static void mic_set_run(bool on);
static struct bt_conn *current_conn;
static uint16_t pcm_seq;
static bool mic_running;

#define BTN_EV_NONE     0
#define BTN_EV_SINGLE   1
#define BTN_EV_DOUBLE   2
#define BTN_EV_LONG     3
#define BTN_EV_LONG_UP  4
#define BTN_STABLE_TICKS 3
#define BTN_LONG_MS      700
#define BTN_DOUBLE_MS    400

static uint8_t btn_event;
static uint8_t btn_seq;
static bool btn_ok;
static bool btn_raw;
static bool btn_pressed;
static uint8_t btn_same;
static uint8_t btn_clicks;
static bool btn_long_done;
static bool btn_note_held;
static int64_t btn_press_ms;
static int64_t btn_release_ms;

/* Idle: 250 ms green every 2 s. Red is only for an active meeting. */
static void leds_update(void)
{
	if (pcm_notify_enabled || btn_note_held) {
		led_set(&led_green, 0);
		led_set(&led, pcm_notify_enabled ? 1 : 0);
		return;
	}
	led_set(&led, 0);
	led_set(&led_green, (k_uptime_get() % 2000) < 250 ? 1 : 0);
}

static void btn_emit(uint8_t ev)
{
	static const char *names[] = {
		"none", "single", "double", "long-down", "long-up",
	};

	btn_event = ev;
	btn_seq++;
	if (btn_seq == 0) {
		btn_seq = 1;
	}
	printk("BTN %s seq=%u\n",
	       ev < ARRAY_SIZE(names) ? names[ev] : "?", btn_seq);
	status_notify(last_volume);
}

static void btn_work_fn(struct k_work *work)
{
	bool raw;
	int64_t now;

	ARG_UNUSED(work);

	if (!btn_ok) {
		return;
	}

	raw = gpio_pin_get_dt(&user_btn) > 0;
	now = k_uptime_get();

	if (raw != btn_raw) {
		btn_raw = raw;
		btn_same = 1;
	} else if (btn_same < 255) {
		btn_same++;
	}

	if (btn_same == BTN_STABLE_TICKS && raw != btn_pressed) {
		btn_pressed = raw;
		if (btn_pressed) {
			btn_press_ms = now;
			btn_long_done = false;
			if (btn_clicks == 1 &&
			    (now - btn_release_ms) > BTN_DOUBLE_MS) {
				btn_clicks = 0;
			}
		} else if (!btn_long_done) {
			btn_release_ms = now;
			btn_clicks++;
			if (btn_clicks >= 2) {
				btn_emit(BTN_EV_DOUBLE);
				btn_clicks = 0;
			}
		} else {
			btn_clicks = 0;
			if (btn_note_held) {
				btn_note_held = false;
				note_led(false);
				leds_update();
				if (imu_sleep) {
					mic_set_run(false);
				}
				btn_emit(BTN_EV_LONG_UP);
			}
		}
	}

	if (btn_pressed && !btn_long_done &&
	    (now - btn_press_ms) >= BTN_LONG_MS) {
		btn_long_done = true;
		btn_clicks = 0;
		btn_note_held = true;
		mic_set_run(true);
		note_led(true);
		leds_update();
		btn_emit(BTN_EV_LONG);
	}

	if (!btn_pressed && btn_clicks == 1 &&
	    (now - btn_release_ms) >= BTN_DOUBLE_MS) {
		btn_clicks = 0;
		btn_emit(BTN_EV_SINGLE);
	}
}

static K_WORK_DEFINE(btn_work, btn_work_fn);

static void btn_timer_fn(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	k_work_submit(&btn_work);
}

static K_TIMER_DEFINE(btn_timer, btn_timer_fn, NULL);

static void btn_setup(void)
{
	int err;

	if (!gpio_is_ready_dt(&user_btn)) {
		printk("Button D10 (P1.15) not ready\n");
		return;
	}
	err = gpio_pin_configure_dt(&user_btn, GPIO_INPUT);
	if (err) {
		printk("Button D10 configure failed (%d)\n", err);
		return;
	}
	btn_ok = true;
	btn_raw = gpio_pin_get_dt(&user_btn) > 0;
	btn_pressed = btn_raw;
	btn_same = BTN_STABLE_TICKS;
	btn_press_ms = k_uptime_get();
	btn_long_done = btn_pressed;
	k_timer_start(&btn_timer, K_MSEC(10), K_MSEC(10));
	printk("Button D10 ready (NO→D10, COM→GND, internal pull-up)\n");
}

#define IMU_HIST 16
#define IMU_STILL_STD_MM 80   /* mm/s^2; table noise is small, walk is hundreds */
#define IMU_STILL_HITS 10     /* consecutive still polls before sleep (~10 s) */

static int32_t imu_hist[IMU_HIST];
static uint8_t imu_hist_n;
static uint8_t imu_hist_i;
static uint8_t imu_still_hits;
static bool imu_fetch_ok;

static void mic_set_run(bool on)
{
	if (on == mic_running) {
		return;
	}
	if (dmic_trigger(mic_dev, on ? DMIC_TRIGGER_START : DMIC_TRIGGER_STOP) == 0) {
		mic_running = on;
		printk("PDM mic %s\n", on ? "START" : "STOP");
	}
}

static int32_t imu_mag_mm(void)
{
	struct sensor_value x, y, z;
	int32_t ax, ay, az;

	if (!device_is_ready(imu_dev)) {
		imu_fetch_ok = false;
		return -1;
	}
	if (sensor_sample_fetch_chan(imu_dev, SENSOR_CHAN_ACCEL_XYZ) < 0) {
		imu_fetch_ok = false;
		return -1;
	}
	if (sensor_channel_get(imu_dev, SENSOR_CHAN_ACCEL_X, &x) < 0 ||
	    sensor_channel_get(imu_dev, SENSOR_CHAN_ACCEL_Y, &y) < 0 ||
	    sensor_channel_get(imu_dev, SENSOR_CHAN_ACCEL_Z, &z) < 0) {
		imu_fetch_ok = false;
		return -1;
	}
	imu_fetch_ok = true;
	ax = sensor_value_to_milli(&x);
	ay = sensor_value_to_milli(&y);
	az = sensor_value_to_milli(&z);
	if (ax < 0) {
		ax = -ax;
	}
	if (ay < 0) {
		ay = -ay;
	}
	if (az < 0) {
		az = -az;
	}
	return ax + ay + az;
}

static int32_t imu_var_mm(void)
{
	int64_t sum = 0, var = 0;
	int n = imu_hist_n;
	int32_t mean;
	int i;

	if (n < 4) {
		return 1000000;
	}
	for (i = 0; i < n; i++) {
		sum += imu_hist[i];
	}
	mean = (int32_t)(sum / n);
	for (i = 0; i < n; i++) {
		int32_t d = imu_hist[i] - mean;

		var += (int64_t)d * d;
	}
	return (int32_t)(var / n);
}

static void imu_poll(int volume)
{
	int32_t mag = imu_mag_mm();
	int32_t var;
	bool still;

	if (mag < 0) {
		return;
	}
	imu_hist[imu_hist_i] = mag;
	imu_hist_i = (imu_hist_i + 1) % IMU_HIST;
	if (imu_hist_n < IMU_HIST) {
		imu_hist_n++;
	}
	var = imu_var_mm();
	still = (var < (IMU_STILL_STD_MM * IMU_STILL_STD_MM));

	if (!still) {
		imu_still_hits = 0;
		if (imu_sleep) {
			imu_sleep = false;
			mic_set_run(true);
			printk("IMU wake (var=%d)\n", var);
			status_notify(volume);
		}
		return;
	}

	if (imu_still_hits < 255) {
		imu_still_hits++;
	}
	if (pcm_notify_enabled) {
		return;
	}
	if (!imu_sleep && imu_still_hits >= IMU_STILL_HITS) {
		if (btn_note_held) {
			return;
		}
		imu_sleep = true;
		mic_set_run(false);
		printk("IMU sleep (still var=%d)\n", var);
		status_notify(0);
	}
}

/* 1 MΩ / 510 kΩ divider on XIAO Sense. Gain 1/6, 0.6 V ref → 3.6 V at P0.31. */
#define BAT_DIV_FULL_OHM 1510000
#define BAT_DIV_OUT_OHM  510000

static const struct device *adc_dev = DEVICE_DT_GET(DT_NODELABEL(adc));
static int16_t bat_raw;
static uint16_t battery_mv;
static bool battery_ok;

static int battery_setup(void)
{
	int err;
	struct adc_channel_cfg cfg = {
		.gain = ADC_GAIN_1_6,
		.reference = ADC_REF_INTERNAL,
		.acquisition_time = ADC_ACQ_TIME_DEFAULT,
		.channel_id = 7,
		.differential = 0,
		.input_positive = NRF_SAADC_AIN7,
	};

	if (!device_is_ready(adc_dev)) {
		printk("ADC not ready — no battery SoC\n");
		return -ENODEV;
	}
	err = adc_channel_setup(adc_dev, &cfg);
	if (err) {
		printk("ADC channel 7 setup failed (%d)\n", err);
		return err;
	}
	battery_ok = true;
	printk("Battery ADC ready (AIN7, P0.14 held low)\n");
	return 0;
}

static uint16_t battery_sample_mv(void)
{
	int err;
	int32_t pin_mv;
	struct adc_sequence seq = {
		.channels = BIT(7),
		.buffer = &bat_raw,
		.buffer_size = sizeof(bat_raw),
		.resolution = 12,
	};

	if (!battery_ok) {
		return 0;
	}
	err = adc_read(adc_dev, &seq);
	if (err) {
		return battery_mv;
	}
	pin_mv = bat_raw;
	err = adc_raw_to_millivolts(adc_ref_internal(adc_dev), ADC_GAIN_1_6, 12,
				    &pin_mv);
	if (err || pin_mv < 0) {
		return battery_mv;
	}
	battery_mv = (uint16_t)((pin_mv * (uint64_t)BAT_DIV_FULL_OHM) /
				BAT_DIV_OUT_OHM);
	return battery_mv;
}

static void status_fill(int volume)
{
	int v = volume;

	if (v < 0) {
		v = 0;
	}
	if (v > 65535) {
		v = 65535;
	}
	last_volume = v;
	status_buf[0] = (imu_sleep ? 1 : 0) | (mic_running ? 2 : 0) |
			(device_is_ready(imu_dev) ? 4 : 0) |
			(imu_fetch_ok ? 8 : 0) |
			(nrf_power_usbregstatus_vbusdet_get(NRF_POWER) ? 16 : 0) |
			(btn_note_held ? 32 : 0);
	sys_put_le16((uint16_t)v, &status_buf[1]);
	status_buf[3] = imu_still_hits;
	sys_put_le16(battery_sample_mv(), &status_buf[4]);
	status_buf[6] = btn_event;
	status_buf[7] = btn_seq;
}

static ssize_t status_read(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			   void *buf, uint16_t len, uint16_t offset)
{
	status_fill(0);
	return bt_gatt_attr_read(conn, attr, buf, len, offset, status_buf,
				 sizeof(status_buf));
}

static void status_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	status_notify_enabled = (value == BT_GATT_CCC_NOTIFY);
	printk("Status notify %s\n", status_notify_enabled ? "ON" : "OFF");
	status_notify(0);
}

static void pcm_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	pcm_notify_enabled = (value == BT_GATT_CCC_NOTIFY);
	printk("PCM notify %s\n", pcm_notify_enabled ? "ON" : "OFF");
	if (pcm_notify_enabled) {
		imu_sleep = false;
		imu_still_hits = 0;
		mic_set_run(true);
	}
	leds_update();
}

BT_GATT_SERVICE_DEFINE(pendant_svc,
	BT_GATT_PRIMARY_SERVICE(&pendant_svc_uuid),
	BT_GATT_CHARACTERISTIC(&pendant_pcm_uuid.uuid,
			       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE,
			       NULL, NULL, NULL),
	BT_GATT_CCC(pcm_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&pendant_status_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ,
			       status_read, NULL, NULL),
	BT_GATT_CCC(status_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

static void status_notify(int volume)
{
	status_fill(volume);
	if (!status_notify_enabled || current_conn == NULL) {
		return;
	}
	bt_gatt_notify(current_conn, &pendant_svc.attrs[5], status_buf,
		       sizeof(status_buf));
}

static void mtu_updated(struct bt_conn *conn, uint16_t tx, uint16_t rx)
{
	printk("ATT MTU updated: TX %u RX %u\n", tx, rx);
}

static struct bt_gatt_cb gatt_callbacks = {
	.att_mtu_updated = mtu_updated,
};

static int pcm_notify_chunk(const uint8_t *pcm, size_t pcm_len)
{
	uint8_t pkt[244];
	uint16_t mtu;
	uint16_t payload_max;
	uint8_t frag_count;
	uint8_t frag;
	size_t offset = 0;
	int err = 0;

	if (!pcm_notify_enabled || current_conn == NULL) {
		return 0;
	}
	if (imu_sleep && !btn_note_held) {
		return 0;
	}

	mtu = bt_gatt_get_mtu(current_conn);
	if (mtu < (3 + PCM_HDR_SIZE + 1)) {
		return -EINVAL;
	}

	payload_max = mtu - 3 - PCM_HDR_SIZE;
	if (payload_max > sizeof(pkt) - PCM_HDR_SIZE) {
		payload_max = sizeof(pkt) - PCM_HDR_SIZE;
	}

	frag_count = (uint8_t)((pcm_len + payload_max - 1) / payload_max);

	for (frag = 0; frag < frag_count; frag++) {
		size_t n = pcm_len - offset;

		if (n > payload_max) {
			n = payload_max;
		}

		sys_put_le16(pcm_seq, &pkt[0]);
		pkt[2] = frag;
		pkt[3] = frag_count;
		memcpy(&pkt[PCM_HDR_SIZE], pcm + offset, n);

		err = bt_gatt_notify(current_conn, &pendant_svc.attrs[2], pkt,
				     PCM_HDR_SIZE + n);
		if (err) {
			return err;
		}

		offset += n;
	}

	pcm_seq++;
	return 0;
}

static void adv_restart_fn(struct k_work *work);

static K_WORK_DELAYABLE_DEFINE(adv_restart_work, adv_restart_fn);
static uint8_t adv_restart_tries;

static void adv_restart_fn(struct k_work *work)
{
	int err;

	ARG_UNUSED(work);

	err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad),
			      sd, ARRAY_SIZE(sd));
	if (err == 0 || err == -EALREADY) {
		adv_restart_tries = 0;
		printk("Advertising restarted as \"%s\"\n", DEVICE_NAME);
		return;
	}
	if (adv_restart_tries < 8) {
		adv_restart_tries++;
		printk("Advertising restart err %d, retry %u\n", err,
		       adv_restart_tries);
		k_work_schedule(&adv_restart_work, K_MSEC(250));
	} else {
		printk("Advertising failed to restart (err %d)\n", err);
	}
}

static void schedule_adv_restart(void)
{
	adv_restart_tries = 0;
	k_work_schedule(&adv_restart_work, K_MSEC(50));
}

static void connected(struct bt_conn *conn, uint8_t err)
{
	struct bt_le_conn_param conn_param = {
		.interval_min = 6,
		.interval_max = 12,
		.latency = 0,
		.timeout = 200, /* 2 s: recover if the host app vanishes */
	};

	if (err) {
		printk("BLE connection failed (err 0x%02x)\n", err);
		schedule_adv_restart();
		return;
	}

	k_work_cancel_delayable(&adv_restart_work);

	if (current_conn) {
		bt_conn_unref(current_conn);
	}
	current_conn = bt_conn_ref(conn);
	printk("BLE connected\n");

	bt_conn_le_param_update(conn, &conn_param);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	ARG_UNUSED(conn);

	printk("BLE disconnected (reason 0x%02x)\n", reason);
	pcm_notify_enabled = false;
	status_notify_enabled = false;
	btn_note_held = false;
	note_led(false);
	led_set(&led, 0);
	led_set(&led_green, 0);

	if (current_conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
	}

	/* Controller may still be tearing the link down; retry from a work item. */
	schedule_adv_restart();
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
};

static int ble_start(void)
{
	int err;

	bt_gatt_cb_register(&gatt_callbacks);

	printk("Starting Bluetooth...\n");

	err = bt_enable(NULL);
	if (err) {
		printk("Bluetooth init failed (err %d)\n", err);
		return err;
	}

	printk("Bluetooth initialized\n");

	err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad),
			      sd, ARRAY_SIZE(sd));
	if (err) {
		printk("Advertising failed to start (err %d)\n", err);
		return err;
	}

	ble_ok = true;
	printk("Advertising as \"%s\"\n", DEVICE_NAME);
	return 0;
}

static void ble_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);
	ble_start();
}

K_THREAD_STACK_DEFINE(ble_stack, 4096);
static struct k_thread ble_thread_data;

static int imu_bringup(void)
{
	int err;
	int tries;

	if (device_is_ready(imu_dev)) {
		return 0;
	}

	for (tries = 0; tries < 4; tries++) {
		k_msleep(20);
		err = device_init(imu_dev);
		printk("IMU init try %d: err=%d ready=%d\n", tries + 1, err,
		       (int)device_is_ready(imu_dev));
		if (device_is_ready(imu_dev)) {
			return 0;
		}
	}
	return err;
}

int main(void)
{
	void *buffer;
	size_t size;
	unsigned int chunk = 0;
	unsigned int sent = 0;
	unsigned int dropped = 0;

	if (gpio_is_ready_dt(&led)) {
		gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
	}
	if (gpio_is_ready_dt(&led_green)) {
		gpio_pin_configure_dt(&led_green, GPIO_OUTPUT_INACTIVE);
	}
	if (gpio_is_ready_dt(&led_blue)) {
		gpio_pin_configure_dt(&led_blue, GPIO_OUTPUT_INACTIVE);
	}
	btn_setup();

	printk("Booting OpenPendant (GATT PCM stream)...\n");

	if (battery_setup() == 0) {
		printk("VBAT ~%u mV\n", battery_sample_mv());
	}

	k_thread_create(&ble_thread_data, ble_stack,
			K_THREAD_STACK_SIZEOF(ble_stack), ble_thread,
			NULL, NULL, NULL, 5, 0, K_NO_WAIT);

	for (int i = 0; i < 50 && !ble_ok; i++) {
		k_sleep(K_MSEC(100));
	}

	if (!device_is_ready(mic_dev)) {
		printk("ERROR: PDM Microphone is not ready in Devicetree.\n");
		return 0;
	}

	struct pcm_stream_cfg stream = {
		.pcm_rate = MAX_SAMPLE_RATE,
		.pcm_width = SAMPLE_BIT_WIDTH,
		.block_size = BLOCK_SIZE,
		.mem_slab  = &rx_mem_slab,
	};

	struct dmic_cfg cfg = {
		.io = {
			.min_pdm_clk_freq = 1000000,
			.max_pdm_clk_freq = 3200000,
			.min_pdm_clk_dc   = 40,
			.max_pdm_clk_dc   = 60,
		},
		.streams = &stream,
		.channel = {
			.req_num_streams = 1,
			.req_num_chan    = 1,
			.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT),
		},
	};

	if (dmic_configure(mic_dev, &cfg) < 0) {
		printk("ERROR: Failed to configure DMIC\n");
		return 0;
	}

	if (imu_bringup() == 0) {
		printk("IMU ready (sleep when still, wake on motion).\n");
	} else {
		printk("IMU not ready — sleep stays host-side only.\n");
	}

	if (dmic_trigger(mic_dev, DMIC_TRIGGER_START) < 0) {
		printk("ERROR: Failed to start DMIC\n");
		return 0;
	}
	mic_running = true;

	printk("Microphone is active. Subscribe to PCM notify to record.\n");

	while (1) {
		leds_update();
		if (imu_sleep) {
			imu_poll(0);
			status_notify(0);
			k_sleep(K_MSEC(50));
			continue;
		}

		if (dmic_read(mic_dev, 0, &buffer, &size, 2000) != 0) {
			printk("PDM read timeout — restarting mic\n");
			dmic_trigger(mic_dev, DMIC_TRIGGER_STOP);
			k_msleep(20);
			dmic_trigger(mic_dev, DMIC_TRIGGER_START);
			mic_running = true;
			continue;
		}

		if (pcm_notify_chunk(buffer, size) == 0) {
			if (pcm_notify_enabled) {
				sent++;
			}
		} else {
			dropped++;
		}

		chunk++;
		if ((chunk % 32) == 0) {
			int16_t *pcm_data = (int16_t *)buffer;
			int samples = size / 2;
			int32_t sum = 0;
			int volume;
			int i;

			for (i = 0; i < samples; i++) {
				sum += (pcm_data[i] > 0 ? pcm_data[i] : -pcm_data[i]);
			}
			volume = samples ? (sum / samples) : 0;
			imu_poll(volume);
			status_notify(volume);

			printk("Vol: %4d | bat=%umV notify=%d imu_sleep=%d imu_ok=%d still=%u sent=%u drop=%u seq=%u\n",
			       volume, battery_mv, pcm_notify_enabled, imu_sleep, imu_fetch_ok,
			       imu_still_hits, sent, dropped, pcm_seq);
		}

		k_mem_slab_free(&rx_mem_slab, buffer);
	}

	return 0;
}
