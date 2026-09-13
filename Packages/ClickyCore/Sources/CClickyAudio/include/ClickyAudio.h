#ifndef CLICKY_AUDIO_H
#define CLICKY_AUDIO_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CAMixer CAMixer;
enum { CA_MAX_VOICES = 96, CA_QUEUE_CAPACITY = 1024, CA_MAX_SAMPLES = 2048 };
typedef struct {
    uint32_t sample;
    float gain;
    float pan;   /* -1 (left) ... 1 (right) */
    float pitch; /* playback speed, 1 = original */
    float tone;  /* -1 (warm low-pass) ... 1 (bright high shelf) */
    bool audition; /* Explicit previews bypass the global capture enable switch. */
} CATrigger;
typedef struct {
    uint64_t renderedFrames;
    uint64_t acceptedTriggers;
    uint64_t droppedTriggers;
    uint64_t stolenVoices;
    uint32_t activeVoices;
    uint32_t sampleCount;
    uint32_t lastRenderFrames;
} CAStats;

CAMixer *ca_mixer_create(double outputSampleRate);
/* Caller must stop rendering and enqueueing before destroying. */
void ca_mixer_destroy(CAMixer *mixer);
/* Copies mono PCM data; producer only. Samples remain valid until destruction. */
int32_t ca_mixer_add_sample(CAMixer *mixer, const float *frames, uint32_t count, double sampleRate);
/* Exactly one serialized producer; bounded, allocation-free and nonblocking. */
bool ca_mixer_enqueue(CAMixer *mixer, CATrigger trigger);
void ca_mixer_set_gain(CAMixer *mixer, float gain);
void ca_mixer_set_enabled(CAMixer *mixer, bool enabled);
/* Call only while the render callback is stopped. */
void ca_mixer_set_sample_rate(CAMixer *mixer, double rate);
void ca_mixer_clear(CAMixer *mixer);
/* Single render consumer; no allocation, locks, Objective-C or Swift ARC. */
void ca_mixer_render(CAMixer *mixer, float *left, float *right, uint32_t frames, uint32_t stride);
CAStats ca_mixer_stats(const CAMixer *mixer);
void ca_pan_gains(float pan, float *left, float *right);
float ca_limit(float sample);

#ifdef __cplusplus
}
#endif
#endif
