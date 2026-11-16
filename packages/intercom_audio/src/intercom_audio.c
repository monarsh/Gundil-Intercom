#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "intercom_audio.h"

#include <stdio.h>
#include <string.h>

// One second of buffering in each direction is plenty; the Dart side keeps
// latency low by trimming the playback queue.
#define IA_RING_SECONDS 1

static ma_context g_context;
static int g_context_ready = 0;
static ma_uint32 g_sample_rate = 16000;

static ma_device g_capture;
static int g_capture_ready = 0;
static ma_pcm_rb g_capture_rb;

static ma_device g_playback;
static int g_playback_ready = 0;
static ma_pcm_rb g_playback_rb;
static volatile int g_clear_playback = 0;

static char g_error[256] = "";

// Device choice: [0] capture, [1] playback.
#define IA_MAX_DEVICES 32
static char g_selected[2][256] = {"", ""};
static int32_t g_android_device[2] = {0, 0};
static ma_device_info g_devices[2][IA_MAX_DEVICES];
static int32_t g_device_count[2] = {0, 0};

static void set_error(const char* what, ma_result r) {
  snprintf(g_error, sizeof(g_error), "%s: %s", what, ma_result_description(r));
}

static void capture_cb(ma_device* dev, void* out, const void* in,
                       ma_uint32 frame_count) {
  (void)dev;
  (void)out;
  const ma_int16* src = (const ma_int16*)in;
  ma_uint32 remaining = frame_count;
  while (remaining > 0) {
    ma_uint32 n = remaining;
    void* dst;
    if (ma_pcm_rb_acquire_write(&g_capture_rb, &n, &dst) != MA_SUCCESS || n == 0)
      break;  // Consumer is behind: drop the rest of this block.
    memcpy(dst, src, n * sizeof(ma_int16));
    ma_pcm_rb_commit_write(&g_capture_rb, n);
    src += n;
    remaining -= n;
  }
}

static void playback_cb(ma_device* dev, void* out, const void* in,
                        ma_uint32 frame_count) {
  (void)dev;
  (void)in;
  ma_int16* dst = (ma_int16*)out;
  if (g_clear_playback) {
    // Consumer-side reset: skip everything currently readable.
    ma_uint32 avail = ma_pcm_rb_available_read(&g_playback_rb);
    ma_pcm_rb_seek_read(&g_playback_rb, avail);
    g_clear_playback = 0;
  }
  ma_uint32 remaining = frame_count;
  while (remaining > 0) {
    ma_uint32 n = remaining;
    void* src;
    if (ma_pcm_rb_acquire_read(&g_playback_rb, &n, &src) != MA_SUCCESS || n == 0)
      break;
    memcpy(dst, src, n * sizeof(ma_int16));
    ma_pcm_rb_commit_read(&g_playback_rb, n);
    dst += n;
    remaining -= n;
  }
  if (remaining > 0) memset(dst, 0, remaining * sizeof(ma_int16));  // underrun
}

int32_t ia_refresh_devices(void) {
  if (!g_context_ready) return -1;
  ma_device_info* playback;
  ma_device_info* capture;
  ma_uint32 playback_count, capture_count;
  ma_result r = ma_context_get_devices(&g_context, &playback, &playback_count,
                                       &capture, &capture_count);
  if (r != MA_SUCCESS) {
    set_error("list devices", r);
    return -2;
  }
  g_device_count[0] = 0;
  for (ma_uint32 i = 0; i < capture_count && i < IA_MAX_DEVICES; i++)
    g_devices[0][g_device_count[0]++] = capture[i];
  g_device_count[1] = 0;
  for (ma_uint32 i = 0; i < playback_count && i < IA_MAX_DEVICES; i++)
    g_devices[1][g_device_count[1]++] = playback[i];
  return 0;
}

int32_t ia_device_count(int32_t kind) {
  return (kind == 0 || kind == 1) ? g_device_count[kind] : 0;
}

const char* ia_device_name(int32_t kind, int32_t index) {
  if ((kind != 0 && kind != 1) || index < 0 || index >= g_device_count[kind])
    return "";
  return g_devices[kind][index].name;
}

int32_t ia_device_is_default(int32_t kind, int32_t index) {
  if ((kind != 0 && kind != 1) || index < 0 || index >= g_device_count[kind])
    return 0;
  return g_devices[kind][index].isDefault ? 1 : 0;
}

void ia_select_device(int32_t kind, const char* name) {
  if (kind != 0 && kind != 1) return;
  snprintf(g_selected[kind], sizeof(g_selected[kind]), "%s", name ? name : "");
}

void ia_set_android_device(int32_t kind, int32_t device_id) {
  if (kind != 0 && kind != 1) return;
  g_android_device[kind] = device_id;
}

// The id of the device the user chose for `kind`, or NULL for the default.
static ma_device_id* chosen_device(int kind, ma_device_id* storage) {
#if defined(__ANDROID__)
  if (g_android_device[kind] > 0 && g_context.backend == ma_backend_aaudio) {
    memset(storage, 0, sizeof(*storage));
    storage->aaudio = g_android_device[kind];
    return storage;
  }
#endif
  if (g_selected[kind][0] == '\0') return NULL;
  if (ia_refresh_devices() != 0) return NULL;
  for (int32_t i = 0; i < g_device_count[kind]; i++) {
    if (strcmp(g_devices[kind][i].name, g_selected[kind]) == 0) {
      *storage = g_devices[kind][i].id;
      return storage;
    }
  }
  return NULL;  // Unplugged: fall back to the default.
}

int32_t ia_init(int32_t sample_rate) {
  if (g_context_ready) return 0;
  g_sample_rate = (ma_uint32)sample_rate;
  ma_context_config ctx_cfg = ma_context_config_init();
#if defined(__APPLE__)
  // iPhone: one session for talking and listening, on the loudspeaker
  // (not the earpiece), with Bluetooth headsets allowed. Ignored on macOS.
  ctx_cfg.coreaudio.sessionCategory = ma_ios_session_category_play_and_record;
  ctx_cfg.coreaudio.sessionCategoryOptions =
      ma_ios_session_category_option_default_to_speaker |
      ma_ios_session_category_option_allow_bluetooth;
#endif
  ma_result r = ma_context_init(NULL, 0, &ctx_cfg, &g_context);
  if (r != MA_SUCCESS) {
    set_error("context init", r);
    return -1;
  }
  ma_uint32 cap = g_sample_rate * IA_RING_SECONDS;
  r = ma_pcm_rb_init(ma_format_s16, 1, cap, NULL, NULL, &g_capture_rb);
  if (r == MA_SUCCESS)
    r = ma_pcm_rb_init(ma_format_s16, 1, cap, NULL, NULL, &g_playback_rb);
  if (r != MA_SUCCESS) {
    set_error("ring buffer init", r);
    ma_context_uninit(&g_context);
    return -2;
  }
  g_context_ready = 1;
  return 0;
}

void ia_shutdown(void) {
  ia_stop_capture();
  ia_stop_playback();
  if (!g_context_ready) return;
  ma_pcm_rb_uninit(&g_capture_rb);
  ma_pcm_rb_uninit(&g_playback_rb);
  ma_context_uninit(&g_context);
  g_context_ready = 0;
}

int32_t ia_start_capture(void) {
  if (!g_context_ready) {
    snprintf(g_error, sizeof(g_error), "audio not initialised");
    return -1;
  }
  if (g_capture_ready) return 0;
  ma_pcm_rb_reset(&g_capture_rb);
  ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
  cfg.capture.format = ma_format_s16;
  cfg.capture.channels = 1;
  cfg.sampleRate = g_sample_rate;
  cfg.periodSizeInMilliseconds = 20;
  cfg.dataCallback = capture_cb;
#if defined(__ANDROID__)
  // Two-way audio: the voice-communication path enables the phone's
  // acoustic echo canceller and noise suppression.
  cfg.aaudio.inputPreset = ma_aaudio_input_preset_voice_communication;
  cfg.opensl.recordingPreset = ma_opensl_recording_preset_voice_communication;
#endif
  ma_device_id chosen;
  cfg.capture.pDeviceID = chosen_device(0, &chosen);
  ma_result r = ma_device_init(&g_context, &cfg, &g_capture);
  if (r != MA_SUCCESS && cfg.capture.pDeviceID != NULL) {
    // The chosen microphone can't be opened (just unplugged?): default.
    cfg.capture.pDeviceID = NULL;
    r = ma_device_init(&g_context, &cfg, &g_capture);
  }
  if (r != MA_SUCCESS) {
    set_error("capture init", r);
    return -2;
  }
  r = ma_device_start(&g_capture);
  if (r != MA_SUCCESS) {
    set_error("capture start", r);
    ma_device_uninit(&g_capture);
    return -3;
  }
  g_capture_ready = 1;
  return 0;
}

void ia_stop_capture(void) {
  if (!g_capture_ready) return;
  ma_device_uninit(&g_capture);
  g_capture_ready = 0;
}

int32_t ia_start_playback(void) {
  if (!g_context_ready) {
    snprintf(g_error, sizeof(g_error), "audio not initialised");
    return -1;
  }
  if (g_playback_ready) return 0;
  ma_pcm_rb_reset(&g_playback_rb);
  g_clear_playback = 0;
  ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
  cfg.playback.format = ma_format_s16;
  cfg.playback.channels = 1;
  cfg.sampleRate = g_sample_rate;
  cfg.periodSizeInMilliseconds = 20;
  cfg.dataCallback = playback_cb;
#if defined(__ANDROID__)
  // Must be on the voice-call path for the echo canceller to see what we
  // play. Loudspeaker vs. earpiece is chosen in MainActivity/GundilApp.
  cfg.aaudio.usage = ma_aaudio_usage_voice_communication;
  cfg.aaudio.contentType = ma_aaudio_content_type_speech;
  cfg.opensl.streamType = ma_opensl_stream_type_voice;
#endif
  ma_device_id chosen;
  cfg.playback.pDeviceID = chosen_device(1, &chosen);
  ma_result r = ma_device_init(&g_context, &cfg, &g_playback);
  if (r != MA_SUCCESS && cfg.playback.pDeviceID != NULL) {
    cfg.playback.pDeviceID = NULL;
    r = ma_device_init(&g_context, &cfg, &g_playback);
  }
  if (r != MA_SUCCESS) {
    set_error("playback init", r);
    return -2;
  }
  r = ma_device_start(&g_playback);
  if (r != MA_SUCCESS) {
    set_error("playback start", r);
    ma_device_uninit(&g_playback);
    return -3;
  }
  g_playback_ready = 1;
  return 0;
}

void ia_stop_playback(void) {
  if (!g_playback_ready) return;
  ma_device_uninit(&g_playback);
  g_playback_ready = 0;
}

int32_t ia_read_capture(int16_t* out, int32_t max_frames) {
  if (!g_context_ready || max_frames <= 0) return 0;
  int32_t total = 0;
  while (total < max_frames) {
    ma_uint32 n = (ma_uint32)(max_frames - total);
    void* src;
    if (ma_pcm_rb_acquire_read(&g_capture_rb, &n, &src) != MA_SUCCESS || n == 0)
      break;
    memcpy(out + total, src, n * sizeof(int16_t));
    ma_pcm_rb_commit_read(&g_capture_rb, n);
    total += (int32_t)n;
  }
  return total;
}

int32_t ia_write_playback(const int16_t* in, int32_t frames) {
  if (!g_context_ready || frames <= 0) return 0;
  int32_t total = 0;
  while (total < frames) {
    ma_uint32 n = (ma_uint32)(frames - total);
    void* dst;
    if (ma_pcm_rb_acquire_write(&g_playback_rb, &n, &dst) != MA_SUCCESS || n == 0)
      break;
    memcpy(dst, in + total, n * sizeof(int16_t));
    ma_pcm_rb_commit_write(&g_playback_rb, n);
    total += (int32_t)n;
  }
  return total;
}

int32_t ia_playback_queued(void) {
  if (!g_context_ready) return 0;
  return (int32_t)ma_pcm_rb_available_read(&g_playback_rb);
}

void ia_clear_playback(void) { g_clear_playback = 1; }

const char* ia_last_error(void) { return g_error; }
