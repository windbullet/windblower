#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define PT_MAX_BANDS 32
#define PT_CORE_VERSION "0.3.0-tpt64-4"
typedef enum { PT_BELL, PT_LOW_SHELF, PT_HIGH_SHELF, PT_LOW_PASS, PT_HIGH_PASS, PT_BAND_PASS, PT_NOTCH } PTFilterType;
typedef struct { int32_t type, enabled; double frequency, q, gainDB; } PTBand;
typedef struct { int32_t enabled, count; double preampDB; PTBand bands[PT_MAX_BANDS]; } PTEQ;
typedef struct { double sampleRate, duration; int32_t channels, bitsPerSample; uint64_t frames; } PTFileInfo;
typedef struct { double samplePeak, truePeak, inputPeak, effectivePreampDB, safetyDB; uint64_t frames; } PTAnalysis;
typedef struct PTDSP PTDSP;
typedef struct PTDecoder PTDecoder;
typedef struct PTPlayer PTPlayer;
typedef struct PTPreparedTrack PTPreparedTrack;
typedef struct {
    void *context;
    int64_t (*read)(void *context, uint64_t offset, void *buffer, size_t bytes);
    uint64_t length;
} PTByteSource;
PTEQ pt_eq_default(void);
int pt_eq_validate(const PTEQ *eq, double rate);
PTDSP *pt_dsp_create(double rate, int channels, const PTEQ *eq);
void pt_dsp_destroy(PTDSP *dsp);
void pt_dsp_reset(PTDSP *dsp);
int pt_dsp_process(PTDSP *dsp, const double *input, double *output, size_t frames);
double pt_eq_response_db(const PTEQ *eq, double rate, double frequency);
double pt_eq_l1_bound(const PTEQ *eq, double rate);
const char *pt_last_error(void);
PTDecoder *pt_decoder_open(const char *path);
void pt_decoder_close(PTDecoder *decoder);
PTFileInfo pt_decoder_info(PTDecoder *decoder);
int pt_source_info(PTByteSource source, const char *extension, PTFileInfo *info);
int64_t pt_decoder_read(PTDecoder *decoder, double *interleaved, size_t frames);
int pt_decoder_seek(PTDecoder *decoder, uint64_t frame);
/* Full source -> optional SRC -> EQ -> 8x true-peak analysis. Cancel may be null. */
int pt_analyze(const char *path, double outputRate, const PTEQ *eq, PTAnalysis *result);
int pt_analyze_cancelable(const char *path, double outputRate, const PTEQ *eq, PTAnalysis *result, void *context, int (*cancelled)(void *));
/* Ordered, same-format sequence with continuous SRC and filter state across boundaries. */
int pt_analyze_sequence_cancelable(const char *const *paths, size_t count, double outputRate, const PTEQ *eq, PTAnalysis *result, void *context, int (*cancelled)(void *));
/* Measure both filtered and gain-matched dry paths; shared static gain protects A/B. */
int pt_analyze_comparison_sequence_cancelable(const char *const *paths, size_t count, double outputRate, const PTEQ *eq, PTAnalysis *result, void *context, int (*cancelled)(void *));
PTPlayer *pt_player_create(const char *path, double outputRate, const PTEQ *eq, double effectivePreampDB);
/* Source callbacks run on the decode worker, never on the audio callback. */
PTPlayer *pt_player_create_source(PTByteSource source, const char *extension, double outputRate, const PTEQ *eq);
void pt_player_destroy(PTPlayer *player);
void pt_player_pause(PTPlayer *player, int paused);
/* Control calls must be serialized; render may run concurrently. */
int pt_player_set_eq(PTPlayer *player, const PTEQ *eq, double effectivePreampDB);
uint64_t pt_player_set_eq_revision(PTPlayer *player, const PTEQ *eq, double effectivePreampDB);
/* Reconstructs the exact full-source filter/SRC history off the render/decode threads before fading in. */
uint64_t pt_player_set_verified_eq_revision(PTPlayer *player, const PTEQ *eq, double effectivePreampDB);
void pt_player_cancel_eq_update(PTPlayer *player);
/* Retains the running wet state. No file reads, reanalysis or gain recalibration on A/B. */
uint64_t pt_player_set_bypass(PTPlayer *player, int bypassed, int preserveGain);
uint64_t pt_player_bypass_revision(PTPlayer *player);
/* Thread-safe diagnostic copy; render never acquires this lock. */
const char *pt_player_error(PTPlayer *player);
int pt_player_seek(PTPlayer *player, double seconds);
/* Same-format predecoded next track; preserves DSP state at the boundary. */
int pt_player_enqueue(PTPlayer *player, const char *path);
PTPreparedTrack *pt_prepare_track(const char *path, double outputRate);
void pt_prepared_track_destroy(PTPreparedTrack *track);
int pt_player_enqueue_prepared(PTPlayer *player, PTPreparedTrack *track); /* consumes track on success */
void pt_player_clear_next(PTPlayer *player);
size_t pt_player_render(PTPlayer *player, float *interleaved, size_t frames);
double pt_player_position(PTPlayer *player);
uint64_t pt_player_track_index(PTPlayer *player);
int pt_player_state(PTPlayer *player); /* 0 buffering, 1 ready, 2 ended, -1 fault */
uint64_t pt_player_underruns(PTPlayer *player);
uint64_t pt_player_eq_revision(PTPlayer *player);
void pt_set_error(const char *message);
#ifdef __cplusplus
}
#endif
