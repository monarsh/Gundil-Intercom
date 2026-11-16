// Minimal cross-platform audio I/O for the P2P intercom.
//
// Built on miniaudio, which picks the native backend at runtime:
//   Linux   -> PulseAudio / PipeWire-Pulse / ALSA
//   Windows -> WASAPI
//   Android -> AAudio / OpenSL ES
//
// Audio format is fixed to signed 16-bit mono PCM at the sample rate passed to
// ia_init(). Capture and playback each run on their own device with a lock-free
// single-producer/single-consumer ring buffer, so every call below is
// non-blocking and safe to make from the Dart main isolate.
#ifndef INTERCOM_AUDIO_H
#define INTERCOM_AUDIO_H

#include <stdint.h>

#if defined(_WIN32)
#define IA_EXPORT __declspec(dllexport)
#else
#define IA_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Initialises the audio context. Returns 0 on success.
IA_EXPORT int32_t ia_init(int32_t sample_rate);
IA_EXPORT void ia_shutdown(void);

IA_EXPORT int32_t ia_start_capture(void);
IA_EXPORT void ia_stop_capture(void);
IA_EXPORT int32_t ia_start_playback(void);
IA_EXPORT void ia_stop_playback(void);

// Copies up to max_frames captured samples into out. Returns frames copied.
IA_EXPORT int32_t ia_read_capture(int16_t* out, int32_t max_frames);
// Queues frames for playback. Returns frames accepted (may be < frames if full).
IA_EXPORT int32_t ia_write_playback(const int16_t* in, int32_t frames);
// Frames currently waiting in the playback queue.
IA_EXPORT int32_t ia_playback_queued(void);
// Drops everything waiting in the playback queue.
IA_EXPORT void ia_clear_playback(void);

// --- Choosing devices -------------------------------------------------------
// `kind`: 0 = capture (microphone), 1 = playback (speaker).

// Reads the list of devices from the system (needs ia_init). Returns 0 on
// success. The list is what ia_device_count/name/is_default then describe.
IA_EXPORT int32_t ia_refresh_devices(void);
IA_EXPORT int32_t ia_device_count(int32_t kind);
// Name of device `index` ("" if out of range).
IA_EXPORT const char* ia_device_name(int32_t kind, int32_t index);
IA_EXPORT int32_t ia_device_is_default(int32_t kind, int32_t index);
// Uses the device with this name from the next ia_start_* on ("" or NULL =
// the system default). If it's gone by then, the default is used.
IA_EXPORT void ia_select_device(int32_t kind, const char* name);
// Android: uses the device with this AudioDeviceInfo id from the next
// ia_start_* on (0 = let Android choose). Ignored on other platforms.
IA_EXPORT void ia_set_android_device(int32_t kind, int32_t device_id);

// Human readable description of the last error (never NULL).
IA_EXPORT const char* ia_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
