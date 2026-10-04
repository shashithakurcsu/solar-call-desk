#include "HALAudioCore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <math.h>

enum { CaptureCapacity = 96000, OutputCapacity = 480000, MarkerCapacity = 128 };
enum { BadBuffer = -70001, Overflow = -70002, BadTimeline = -70003, Closed = -70004 };
typedef struct {
    uint64_t end, wireFrames, generation;
    double eligibleTime;
    bool rendered;
} Marker;

struct SBHALCore {
    UInt32 inputChannels, outputChannels, maximumFrames, presentationFrames;
    AudioUnit captureUnit;
    AudioBufferList *captureList;
    float *capturePlanes, *captureRing, *outputRing;
    SBHALRenderFunction render;
    void *renderReference;
    _Atomic uint64_t captureWrite, captureRead, outputWrite, outputRead, markerWrite, markerRead;
    _Atomic uint64_t generation, completionSequence, completedGeneration, completedFrames;
    _Atomic unsigned callbacks;
    _Atomic bool closed;
    _Atomic bool timelineFaultReady, firstRecoveryReady;
    _Atomic uint64_t recoveredIdleDiscontinuities;
    _Atomic OSStatus failure;
    // Written once by the output callback, immutable after the release ready flag.
    SBHALTimelineEvent timelineFault, firstRecovery;
    Marker markers[MarkerCapacity];
    // Output callback alone owns these fields. The producer alone owns previousSample.
    uint64_t renderMarker, consumerGeneration, consumerCompleted;
    double nextSampleTime;
    bool hasTimeline;
    double previousSampleTime;
    UInt32 previousFrames, previousWrittenFrames;
    uint64_t outputCallbackOrdinal;
    float previousSample;
#ifdef SB_HAL_TEST
    SBHALSnapshotHook snapshotHook;
    void *snapshotReference;
#endif
};

static void fail(SBHALCore *c, OSStatus error) {
    OSStatus expected = noErr;
    atomic_compare_exchange_strong(&c->failure, &expected, error);
}
static OSStatus renderUnit(void *reference, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                           UInt32 bus, UInt32 frames, AudioBufferList *list) {
    return AudioUnitRender((AudioUnit)reference, flags, time, bus, frames, list);
}
static void publishCompletion(SBHALCore *c) {
    atomic_fetch_add_explicit(&c->completionSequence, 1, memory_order_acq_rel);
    atomic_store_explicit(&c->completedGeneration, c->consumerGeneration, memory_order_relaxed);
    atomic_store_explicit(&c->completedFrames, c->consumerCompleted, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->completionSequence, 1, memory_order_release);
}

SBHALCore *SBHALCreate(UInt32 inputs, UInt32 outputs, UInt32 frames, UInt32 margin) {
    if (inputs < 2 || inputs > 64 || outputs < 2 || outputs > 64 || frames == 0 || frames > 8192 || margin > 48000) return NULL;
    SBHALCore *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    atomic_init(&c->captureWrite, 0); atomic_init(&c->captureRead, 0);
    atomic_init(&c->outputWrite, 0); atomic_init(&c->outputRead, 0);
    atomic_init(&c->markerWrite, 0); atomic_init(&c->markerRead, 0);
    atomic_init(&c->generation, 1); atomic_init(&c->completionSequence, 0);
    atomic_init(&c->completedGeneration, 0); atomic_init(&c->completedFrames, 0);
    atomic_init(&c->callbacks, 0); atomic_init(&c->closed, false); atomic_init(&c->failure, noErr);
    atomic_init(&c->timelineFaultReady, false); atomic_init(&c->firstRecoveryReady, false);
    atomic_init(&c->recoveredIdleDiscontinuities, 0);
    c->inputChannels = inputs; c->outputChannels = outputs; c->maximumFrames = frames; c->presentationFrames = margin;
    c->captureList = calloc(1, offsetof(AudioBufferList, mBuffers) + inputs * sizeof(AudioBuffer));
    c->capturePlanes = calloc((size_t)inputs * frames, sizeof(float));
    c->captureRing = calloc(CaptureCapacity, sizeof(float));
    c->outputRing = calloc(OutputCapacity, sizeof(float));
    if (!c->captureList || !c->capturePlanes || !c->captureRing || !c->outputRing) { SBHALDestroy(c); return NULL; }
    // These atomics must be lock-free on the deployed architecture: no library locks on RT threads.
    if (!atomic_is_lock_free(&c->captureWrite) || !atomic_is_lock_free(&c->failure) || !atomic_is_lock_free(&c->closed)) { SBHALDestroy(c); return NULL; }
    atomic_store(&c->generation, 1);
    c->captureList->mNumberBuffers = inputs;
    for (UInt32 i = 0; i < inputs; ++i) {
        c->captureList->mBuffers[i].mNumberChannels = 1;
        c->captureList->mBuffers[i].mData = c->capturePlanes + (size_t)i * frames;
        c->captureList->mBuffers[i].mDataByteSize = frames * sizeof(float);
    }
    return c;
}
void SBHALSetCaptureUnit(SBHALCore *c, AudioUnit unit) { c->captureUnit = unit; c->render = renderUnit; c->renderReference = unit; }
void SBHALSetCaptureRenderer(SBHALCore *c, SBHALRenderFunction render, void *reference) { c->render = render; c->renderReference = reference; }

OSStatus SBHALCaptureCallback(void *reference, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                              UInt32 bus, UInt32 frames, AudioBufferList *unused) {
    (void)bus; (void)unused;
    SBHALCore *c = reference;
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_acq_rel);
    if (atomic_load(&c->closed) || atomic_load(&c->failure)) goto done;
    if (!frames || frames > c->maximumFrames || !c->render || !time || !flags) { fail(c, BadBuffer); goto done; }
    for (UInt32 i = 0; i < c->inputChannels; ++i) {
        c->captureList->mBuffers[i].mData = c->capturePlanes + (size_t)i * c->maximumFrames;
        c->captureList->mBuffers[i].mDataByteSize = frames * sizeof(float);
    }
    OSStatus status = c->render(c->renderReference, flags, time, 1, frames, c->captureList);
    if (status) { fail(c, status); goto done; }
    if (c->captureList->mNumberBuffers != c->inputChannels) { fail(c, BadBuffer); goto done; }
    for (UInt32 i = 0; i < c->inputChannels; ++i) {
        AudioBuffer *b = &c->captureList->mBuffers[i];
        if (b->mNumberChannels != 1 || b->mData != c->capturePlanes + (size_t)i * c->maximumFrames || b->mDataByteSize < frames * sizeof(float)) { fail(c, BadBuffer); goto done; }
    }
    uint64_t write = atomic_load_explicit(&c->captureWrite, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&c->captureRead, memory_order_acquire);
    if (write - read + frames > CaptureCapacity) { fail(c, Overflow); goto done; }
    float *left = c->captureList->mBuffers[0].mData, *right = c->captureList->mBuffers[1].mData;
    for (UInt32 i = 0; i < frames; ++i) {
        float sample = (left[i] + right[i]) * 0.5f;
        if (!isfinite(sample)) { fail(c, BadBuffer); goto done; }
        c->captureRing[(write + i) % CaptureCapacity] = sample;
    }
    atomic_store_explicit(&c->captureWrite, write + frames, memory_order_release);
done:
    atomic_fetch_sub_explicit(&c->callbacks, 1, memory_order_release);
    return noErr;
}
UInt32 SBHALReadCapture(SBHALCore *c, float *destination, UInt32 capacity) {
    if (atomic_load(&c->closed) || !destination) return 0;
    uint64_t read = atomic_load_explicit(&c->captureRead, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&c->captureWrite, memory_order_acquire);
    UInt32 count = (UInt32)((write - read < capacity) ? write - read : capacity);
    for (UInt32 i = 0; i < count; ++i) destination[i] = c->captureRing[(read + i) % CaptureCapacity];
    atomic_store_explicit(&c->captureRead, read + count, memory_order_release);
    return count;
}
bool SBHALEnqueuePCM16(SBHALCore *c, const uint8_t *bytes, UInt32 count, uint64_t generation) {
    if (atomic_load(&c->closed) || atomic_load(&c->failure) || generation != atomic_load(&c->generation)) return false;
    if (!bytes || !count || count % 2 || count > 480000) { fail(c, BadBuffer); return false; }
    uint64_t write = atomic_load_explicit(&c->outputWrite, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&c->outputRead, memory_order_acquire);
    uint64_t markerWrite = atomic_load_explicit(&c->markerWrite, memory_order_relaxed);
    uint64_t markerRead = atomic_load_explicit(&c->markerRead, memory_order_acquire);
    // One wire sample is always two native samples: no converter prime/tail ambiguity.
    if (write - read + count > OutputCapacity || markerWrite - markerRead >= MarkerCapacity) { fail(c, Overflow); return false; }
    float previous = c->previousSample;
    for (UInt32 i = 0; i < count / 2; ++i) {
        int16_t sample = (int16_t)((uint16_t)bytes[2*i] | ((uint16_t)bytes[2*i+1] << 8));
        float current = (float)sample / 32768.0f;
        c->outputRing[(write + 2*i) % OutputCapacity] = (previous + current) * 0.5f;
        c->outputRing[(write + 2*i + 1) % OutputCapacity] = current;
        previous = current;
    }
    c->previousSample = previous;
    c->markers[markerWrite % MarkerCapacity] = (Marker){ .end = write + count, .wireFrames = count / 2, .generation = generation };
    atomic_store_explicit(&c->outputWrite, write + count, memory_order_release);
    atomic_store_explicit(&c->markerWrite, markerWrite + 1, memory_order_release);
    return true;
}

static SBHALTimelineEvent timelineEvent(SBHALCore *c, const AudioTimeStamp *time, UInt32 frames,
                                        AudioUnitRenderActionFlags actions, UInt32 reason,
                                        uint64_t markerWrite, uint64_t generation) {
    SBHALTimelineEvent event = {
        .callbackOrdinal = c->outputCallbackOrdinal, .generation = generation,
        .previousSampleTime = c->previousSampleTime, .expectedSampleTime = c->nextSampleTime,
        .actualSampleTime = time ? time->mSampleTime : NAN,
        .delta = time && c->hasTimeline ? time->mSampleTime - c->nextSampleTime : NAN,
        .reason = reason, .timestampFlags = time ? time->mFlags : 0, .actionFlags = actions,
        .previousFrames = c->previousFrames, .frames = frames, .hasPrevious = c->hasTimeline,
        .previousSliceWasSilent = c->previousWrittenFrames == 0
    };
    uint64_t markerRead = atomic_load_explicit(&c->markerRead, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&c->outputRead, memory_order_relaxed);
    // Only this callback consumes markers. Published entries cannot be reused until it
    // advances markerRead; inspect at most the bounded 128-entry work snapshot.
    for (uint64_t index = markerRead; index < markerWrite; ++index) {
        Marker *m = &c->markers[index % MarkerCapacity];
        if (m->generation != generation) continue; // Interrupted old speech cannot be credited.
        ++event.pendingMarkers;
        uint64_t length = m->wireFrames * 2, start = m->end - length;
        uint64_t emitted = m->rendered ? length : read > start ? (read < m->end ? read - start : length) : 0;
        event.emittedUnconfirmedNativeFrames += emitted;
        event.queuedNativeFrames += length - emitted;
        if (m->rendered) ++event.heldMarkers;
        else event.partialNativeFrames += emitted;
    }
    return event;
}
static void timelineFailure(SBHALCore *c, SBHALTimelineEvent event) {
    if (!atomic_load_explicit(&c->timelineFaultReady, memory_order_relaxed)) {
        c->timelineFault = event;
        atomic_store_explicit(&c->timelineFaultReady, true, memory_order_release);
    }
    fail(c, BadTimeline);
}
static void idleRecovery(SBHALCore *c, SBHALTimelineEvent event) {
    if (!atomic_load_explicit(&c->firstRecoveryReady, memory_order_relaxed)) {
        c->firstRecovery = event;
        atomic_store_explicit(&c->firstRecoveryReady, true, memory_order_release);
    }
    atomic_fetch_add_explicit(&c->recoveredIdleDiscontinuities, 1, memory_order_release);
}

OSStatus SBHALOutputCallback(void *reference, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                             UInt32 bus, UInt32 frames, AudioBufferList *list) {
    (void)bus;
    SBHALCore *c = reference;
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_acq_rel);
    ++c->outputCallbackOrdinal;
    AudioUnitRenderActionFlags originalActions = flags ? *flags : 0;
    bool valid = list && list->mNumberBuffers == c->outputChannels && frames && frames <= c->maximumFrames;
    if (flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    // A rejected topology cannot safely describe how many AudioBuffer entries exist.
    if (!valid) { fail(c, BadBuffer); atomic_fetch_sub_explicit(&c->callbacks, 1, memory_order_release); return BadBuffer; }
    for (UInt32 i = 0; i < c->outputChannels; ++i) {
        AudioBuffer *b = &list->mBuffers[i];
        if (b->mNumberChannels != 1 || !b->mData || b->mDataByteSize < frames * sizeof(float) ||
            b->mDataByteSize > c->maximumFrames * sizeof(float)) valid = false;
    }
    if (!valid) { fail(c, BadBuffer); atomic_fetch_sub_explicit(&c->callbacks, 1, memory_order_release); return BadBuffer; }
    for (UInt32 i = 0; i < c->outputChannels; ++i) memset(list->mBuffers[i].mData, 0, frames * sizeof(float));
    if (atomic_load(&c->closed) || atomic_load(&c->failure)) goto done;
    if (!valid || !flags) { fail(c, BadBuffer); goto done; }
    // Snapshot published work before generation: a concurrent interrupt/new enqueue must
    // never make a newer marker look stale relative to an older generation snapshot.
    uint64_t markerWrite = atomic_load_explicit(&c->markerWrite, memory_order_acquire);
#ifdef SB_HAL_TEST
    if (c->snapshotHook) {
        SBHALSnapshotHook hook = c->snapshotHook; c->snapshotHook = NULL;
        hook(c->snapshotReference);
    }
#endif
    uint64_t generation = atomic_load_explicit(&c->generation, memory_order_acquire);
    UInt32 clockReason = !time ? SBHALClockMissingTimestamp :
        !(time->mFlags & kAudioTimeStampSampleTimeValid) ? SBHALClockMissingSampleFlag :
        !isfinite(time->mSampleTime) ? SBHALClockNonfinite : 0;
    if (!clockReason && c->hasTimeline && fabs(time->mSampleTime - c->nextSampleTime) > 0.5) {
        clockReason = time->mSampleTime > c->nextSampleTime ? SBHALClockForwardGap :
            time->mSampleTime < c->previousSampleTime - 0.5 ? SBHALClockBackwardReset : SBHALClockOverlappingSlice;
    }
    if (clockReason) {
        SBHALTimelineEvent event = timelineEvent(c, time, frames, originalActions, clockReason, markerWrite, generation);
        if (clockReason <= SBHALClockNonfinite) { timelineFailure(c, event); goto done; }
        // Finite nonsequential stamps do not imply route loss. Re-anchor only if there is
        // no emitted current-generation speech whose presentation would become uncertain.
        if (event.emittedUnconfirmedNativeFrames) {
            uint64_t latestGeneration = atomic_load_explicit(&c->generation, memory_order_acquire);
            if (latestGeneration == generation) { timelineFailure(c, event); goto done; }
            // An interrupt canceled this snapshot while it was inspected. Defer rendering
            // one silent slice, preserving all newly published speech for the next callback.
            event = timelineEvent(c, time, frames, originalActions, clockReason, markerWrite, latestGeneration);
            idleRecovery(c, event);
            c->hasTimeline = true; c->previousSampleTime = time->mSampleTime;
            c->previousFrames = frames; c->previousWrittenFrames = 0;
            c->nextSampleTime = time->mSampleTime + frames;
            goto done;
        }
        idleRecovery(c, event);
    }
    c->hasTimeline = true; c->previousSampleTime = time->mSampleTime;
    c->previousFrames = frames; c->nextSampleTime = time->mSampleTime + frames;
    if (generation != c->consumerGeneration) {
        c->consumerGeneration = generation; c->consumerCompleted = 0; publishCompletion(c);
    }
    uint64_t markerRead = atomic_load_explicit(&c->markerRead, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&c->outputRead, memory_order_relaxed);
    while (markerRead < markerWrite) {
        Marker *m = &c->markers[markerRead % MarkerCapacity];
        if (m->generation != generation) {
            if (read < m->end) read = m->end;
            if (c->renderMarker <= markerRead) c->renderMarker = markerRead + 1;
        } else {
            if (!m->rendered || time->mSampleTime < m->eligibleTime) break;
            c->consumerCompleted += m->wireFrames;
        }
        ++markerRead;
    }
    atomic_store_explicit(&c->markerRead, markerRead, memory_order_release);
    publishCompletion(c);
    UInt32 written = 0;
    while (written < frames && c->renderMarker < markerWrite) {
        Marker *m = &c->markers[c->renderMarker % MarkerCapacity];
        if (m->generation != generation) { read = m->end; ++c->renderMarker; continue; }
        UInt32 amount = (UInt32)((m->end - read < frames - written) ? m->end - read : frames - written);
        float *left = list->mBuffers[0].mData, *right = list->mBuffers[1].mData;
        for (UInt32 i = 0; i < amount; ++i) {
            float value = c->outputRing[(read + i) % OutputCapacity];
            left[written + i] = value; right[written + i] = value;
        }
        read += amount; written += amount;
        if (read == m->end) {
            m->rendered = true;
            m->eligibleTime = time->mSampleTime + written + c->presentationFrames;
            ++c->renderMarker;
        }
    }
    atomic_store_explicit(&c->outputRead, read, memory_order_release);
    c->previousWrittenFrames = written;
    if (written) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
done:
    atomic_fetch_sub_explicit(&c->callbacks, 1, memory_order_release);
    return noErr;
}
uint64_t SBHALGeneration(SBHALCore *c) { return atomic_load_explicit(&c->generation, memory_order_acquire); }
uint64_t SBHALInterrupt(SBHALCore *c) { c->previousSample = 0; return atomic_fetch_add_explicit(&c->generation, 1, memory_order_acq_rel) + 1; }
uint64_t SBHALCompletedWireFrames(SBHALCore *c, uint64_t generation) {
    for (unsigned i = 0; i < 8; ++i) {
        uint64_t before = atomic_load_explicit(&c->completionSequence, memory_order_acquire);
        if (before & 1) continue;
        uint64_t g = atomic_load_explicit(&c->completedGeneration, memory_order_relaxed);
        uint64_t frames = atomic_load_explicit(&c->completedFrames, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        uint64_t after = atomic_load_explicit(&c->completionSequence, memory_order_acquire);
        if (before == after) return g == generation ? frames : 0;
    }
    return 0; // Conservative during a concurrent publication; never over-count.
}
OSStatus SBHALFailure(SBHALCore *c) { return atomic_load(&c->failure); }
bool SBHALGetTimelineFault(SBHALCore *c, SBHALTimelineEvent *event) {
    if (!atomic_load_explicit(&c->timelineFaultReady, memory_order_acquire)) return false;
    *event = c->timelineFault; return true;
}
bool SBHALGetFirstIdleRecovery(SBHALCore *c, SBHALTimelineEvent *event) {
    if (!atomic_load_explicit(&c->firstRecoveryReady, memory_order_acquire)) return false;
    *event = c->firstRecovery; return true;
}
uint64_t SBHALRecoveredIdleDiscontinuities(SBHALCore *c) { return atomic_load_explicit(&c->recoveredIdleDiscontinuities, memory_order_acquire); }
void SBHALClose(SBHALCore *c) { atomic_store(&c->closed, true); }
bool SBHALDestroy(SBHALCore *c) {
    if (!c) return true;
    if (atomic_load_explicit(&c->callbacks, memory_order_acquire)) return false;
    free(c->captureList); free(c->capturePlanes); free(c->captureRing); free(c->outputRing); free(c);
    return true;
}
#ifdef SB_HAL_TEST
void SBHALSetSnapshotHook(SBHALCore *c, SBHALSnapshotHook hook, void *reference) { c->snapshotHook = hook; c->snapshotReference = reference; }
#endif
