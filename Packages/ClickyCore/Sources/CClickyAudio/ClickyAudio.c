#include "ClickyAudio.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>

typedef struct { float *data; uint32_t count; double rate; } CASample;
typedef struct {
    const CASample *sample;
    double position, step;
    float left, right, filter, coefficient, brightness;
    uint64_t age;
    uint32_t elapsed;
    bool active, audition;
} CAVoice;
struct CAMixer {
    CASample samples[CA_MAX_SAMPLES];
    CAVoice voices[CA_MAX_VOICES];
    CATrigger queue[CA_QUEUE_CAPACITY];
    _Atomic uint32_t readIndex, writeIndex, sampleCount, gainBits, activeVoices, enabled, lastRenderFrames;
    _Atomic uint64_t renderedFrames, acceptedTriggers, droppedTriggers, stolenVoices;
    double rate;
    float currentGain, currentEnabled;
    uint64_t voiceAge;
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Clicky requires lock-free 32-bit atomics");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Clicky requires lock-free 64-bit atomics");
static float clampf(float x, float lo, float hi) { return fmaxf(lo, fminf(hi, x)); }
static uint32_t bits(float value) { uint32_t out; memcpy(&out, &value, 4); return out; }
static float unbits(uint32_t value) { float out; memcpy(&out, &value, 4); return out; }

CAMixer *ca_mixer_create(double sampleRate) {
    CAMixer *m = calloc(1, sizeof(CAMixer));
    if (!m) return NULL;
    m->rate = sampleRate > 0 ? sampleRate : 48000;
    atomic_init(&m->readIndex, 0); atomic_init(&m->writeIndex, 0);
    atomic_init(&m->sampleCount, 0); atomic_init(&m->gainBits, bits(0.4f));
    atomic_init(&m->activeVoices, 0); atomic_init(&m->renderedFrames, 0);
    atomic_init(&m->acceptedTriggers, 0); atomic_init(&m->droppedTriggers, 0);
    atomic_init(&m->stolenVoices, 0);
    atomic_init(&m->enabled, 1);
    atomic_init(&m->lastRenderFrames, 0);
    m->currentGain = 0.4f;
    m->currentEnabled = 1;
    return m;
}
void ca_mixer_destroy(CAMixer *m) {
    if (!m) return;
    uint32_t count = atomic_load_explicit(&m->sampleCount, memory_order_acquire);
    for (uint32_t i = 0; i < count; ++i) free(m->samples[i].data);
    free(m);
}
int32_t ca_mixer_add_sample(CAMixer *m, const float *frames, uint32_t count, double rate) {
    if (!m || !frames || !count || !isfinite(rate) || rate <= 0) return -1;
    uint32_t index = atomic_load_explicit(&m->sampleCount, memory_order_relaxed);
    if (index >= CA_MAX_SAMPLES) return -1;
    float *copy = malloc((size_t)count * sizeof(float));
    if (!copy) return -1;
    for (uint32_t i = 0; i < count; ++i) copy[i] = isfinite(frames[i]) ? clampf(frames[i], -1, 1) : 0;
    m->samples[index] = (CASample){copy, count, rate};
    atomic_store_explicit(&m->sampleCount, index + 1, memory_order_release);
    return (int32_t)index;
}
bool ca_mixer_enqueue(CAMixer *m, CATrigger trigger) {
    if (!m || trigger.sample >= atomic_load_explicit(&m->sampleCount, memory_order_acquire)) return false;
    uint32_t write = atomic_load_explicit(&m->writeIndex, memory_order_relaxed);
    uint32_t next = (write + 1) % CA_QUEUE_CAPACITY;
    if (next == atomic_load_explicit(&m->readIndex, memory_order_acquire)) {
        atomic_fetch_add_explicit(&m->droppedTriggers, 1, memory_order_relaxed);
        return false;
    }
    if (!isfinite(trigger.gain) || !isfinite(trigger.pan) || !isfinite(trigger.pitch) || !isfinite(trigger.tone)) return false;
    trigger.gain = clampf(trigger.gain, 0, 4);
    trigger.pan = clampf(trigger.pan, -1, 1);
    trigger.pitch = clampf(trigger.pitch, 0.25f, 4);
    trigger.tone = clampf(trigger.tone, -1, 1);
    m->queue[write] = trigger;
    atomic_store_explicit(&m->writeIndex, next, memory_order_release);
    atomic_fetch_add_explicit(&m->acceptedTriggers, 1, memory_order_relaxed);
    return true;
}
void ca_mixer_set_gain(CAMixer *m, float gain) {
    if (m) atomic_store_explicit(&m->gainBits, bits(isfinite(gain) ? clampf(gain, 0, 1) : 0), memory_order_relaxed);
}
void ca_mixer_set_enabled(CAMixer *m, bool enabled) {
    if (m) atomic_store_explicit(&m->enabled, enabled ? 1 : 0, memory_order_relaxed);
}
void ca_mixer_set_sample_rate(CAMixer *m, double rate) { if (m && isfinite(rate) && rate > 0) { m->rate = rate; ca_mixer_clear(m); } }
void ca_mixer_clear(CAMixer *m) {
    if (!m) return;
    memset(m->voices, 0, sizeof(m->voices));
    atomic_store_explicit(&m->readIndex, atomic_load_explicit(&m->writeIndex, memory_order_acquire), memory_order_release);
    atomic_store_explicit(&m->activeVoices, 0, memory_order_relaxed);
}
void ca_pan_gains(float pan, float *left, float *right) {
    float angle = (clampf(pan, -1, 1) + 1) * 0.7853981633974483f;
    *left = cosf(angle); *right = sinf(angle);
}
float ca_limit(float sample) {
    /* Transparent below -3.1 dBFS; continuous soft knee approaches unity. */
    float magnitude = fabsf(sample);
    if (magnitude <= 0.7f) return sample;
    float limited = 0.7f + 0.3f * ((magnitude - 0.7f) / (magnitude - 0.4f));
    return copysignf(fminf(limited, 0.9999f), sample);
}
static void start_voice(CAMixer *m, CATrigger t) {
    unsigned selected = 0;
    uint64_t oldest = UINT64_MAX;
    for (unsigned i = 0; i < CA_MAX_VOICES; ++i) {
        if (!m->voices[i].active) { selected = i; oldest = UINT64_MAX; break; }
        if (m->voices[i].age < oldest) { oldest = m->voices[i].age; selected = i; }
    }
    if (oldest != UINT64_MAX) atomic_fetch_add_explicit(&m->stolenVoices, 1, memory_order_relaxed);
    CAVoice *v = &m->voices[selected];
    const CASample *s = &m->samples[t.sample];
    float l, r; ca_pan_gains(t.pan, &l, &r);
    /* A neutral setting bypasses filtering exactly. */
    float cutoff = t.tone < 0 ? 18000 * powf(0.06f, -t.tone) : 1800;
    float coefficient = 1 - expf(-6.28318530718f * fminf(cutoff, (float)m->rate * 0.45f) / (float)m->rate);
    *v = (CAVoice){ .sample = s, .position = 0, .step = s->rate / m->rate * t.pitch,
        .left = l * t.gain, .right = r * t.gain, .filter = 0, .coefficient = coefficient,
        .brightness = t.tone, .age = ++m->voiceAge, .elapsed = 0, .active = true, .audition = t.audition };
}
void ca_mixer_render(CAMixer *m, float *left, float *right, uint32_t frames, uint32_t stride) {
    if (!m || !left || !right || !stride) return;
    uint32_t read = atomic_load_explicit(&m->readIndex, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&m->writeIndex, memory_order_acquire);
    while (read != write) { start_voice(m, m->queue[read]); read = (read + 1) % CA_QUEUE_CAPACITY; }
    atomic_store_explicit(&m->readIndex, read, memory_order_release);
    float target = unbits(atomic_load_explicit(&m->gainBits, memory_order_relaxed));
    float targetEnabled = (float)atomic_load_explicit(&m->enabled, memory_order_relaxed);
    float slew = 1 - expf(-1 / (0.003f * (float)m->rate));
    float attackFrames = fmaxf(1, (float)m->rate * 0.0005f);
    float releaseFrames = fmaxf(1, (float)m->rate * 0.002f);
    uint32_t active = 0;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        m->currentEnabled += slew * (targetEnabled - m->currentEnabled);
        float l = 0, r = 0;
        for (unsigned i = 0; i < CA_MAX_VOICES; ++i) {
            CAVoice *v = &m->voices[i];
            if (!v->active) continue;
            const CASample *s = v->sample;
            uint32_t index = (uint32_t)v->position;
            if (index >= s->count) { v->active = false; continue; }
            float fraction = (float)(v->position - index);
            float a = s->data[index], b = index + 1 < s->count ? s->data[index + 1] : 0;
            float value = a + (b - a) * fraction;
            v->filter += v->coefficient * (value - v->filter);
            if (v->brightness < 0) value = v->filter;
            else if (v->brightness > 0) value += v->brightness * (value - v->filter) * 0.8f;
            float attack = fminf(1, (float)++v->elapsed / attackFrames);
            float remaining = (float)((s->count - v->position) / v->step);
            float release = fminf(1, remaining / releaseFrames);
            value *= attack * release * (v->audition ? 1 : m->currentEnabled);
            l += value * v->left; r += value * v->right;
            v->position += v->step;
        }
        m->currentGain += slew * (target - m->currentGain);
        left[frame * stride] = ca_limit(l * m->currentGain);
        right[frame * stride] = ca_limit(r * m->currentGain);
    }
    for (unsigned i = 0; i < CA_MAX_VOICES; ++i) active += m->voices[i].active;
    atomic_store_explicit(&m->activeVoices, active, memory_order_relaxed);
    atomic_store_explicit(&m->lastRenderFrames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->renderedFrames, frames, memory_order_relaxed);
}
CAStats ca_mixer_stats(const CAMixer *m) {
    if (!m) return (CAStats){0};
    return (CAStats){
        atomic_load_explicit(&m->renderedFrames, memory_order_relaxed),
        atomic_load_explicit(&m->acceptedTriggers, memory_order_relaxed),
        atomic_load_explicit(&m->droppedTriggers, memory_order_relaxed),
        atomic_load_explicit(&m->stolenVoices, memory_order_relaxed),
        atomic_load_explicit(&m->activeVoices, memory_order_relaxed),
        atomic_load_explicit(&m->sampleCount, memory_order_acquire),
        atomic_load_explicit(&m->lastRenderFrames, memory_order_relaxed)
    };
}
