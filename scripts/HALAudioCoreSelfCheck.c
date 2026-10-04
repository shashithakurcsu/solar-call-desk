#include "HALAudioCore.h"
#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>

// Actual production callbacks, synthetic AudioBufferLists and timestamps only.
// No AudioComponentInstanceNew/Initialize/Start or network calls occur in these tests.
typedef struct { float before, values[16], after; } Plane;
typedef struct { SBHALCore *core; AudioBufferList *list; Plane planes[16]; unsigned channels; } Fixture;
static Fixture *fixture(unsigned inputs, unsigned outputs, unsigned margin) {
    Fixture *f = calloc(1, sizeof(*f)); assert(f);
    f->core = SBHALCreate(inputs, outputs, 8, margin); assert(f->core); f->channels = outputs;
    f->list = calloc(1, offsetof(AudioBufferList, mBuffers) + outputs * sizeof(AudioBuffer)); assert(f->list);
    f->list->mNumberBuffers = outputs;
    for (unsigned i = 0; i < outputs; ++i) {
        f->planes[i].before = 1234; f->planes[i].after = 5678;
        f->list->mBuffers[i] = (AudioBuffer){ .mNumberChannels = 1, .mDataByteSize = 8 * sizeof(float), .mData = f->planes[i].values };
    }
    return f;
}
static void destroy(Fixture *f) { SBHALClose(f->core); assert(SBHALDestroy(f->core)); free(f->list); free(f); }
static OSStatus output(Fixture *f, double time, unsigned frames, AudioUnitRenderActionFlags *flags) {
    AudioTimeStamp stamp = { .mSampleTime = time, .mFlags = kAudioTimeStampSampleTimeValid };
    return SBHALOutputCallback(f->core, flags, &stamp, 0, frames, f->list);
}
static bool enqueue(SBHALCore *core, const int16_t *samples, unsigned frames, uint64_t generation) {
    return SBHALEnqueuePCM16(core, (const uint8_t *)samples, frames * 2, generation);
}
static void near(float a, float b) { assert(fabsf(a - b) < 0.00001f); }
static OSStatus syntheticRender(void *reference, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                UInt32 bus, UInt32 frames, AudioBufferList *list) {
    (void)flags; (void)time; assert(bus == 1); float *values = reference;
    for (UInt32 c = 0; c < list->mNumberBuffers; ++c) for (UInt32 i = 0; i < frames; ++i) ((float *)list->mBuffers[c].mData)[i] = values[c];
    return noErr;
}
static void capture(Fixture *f, unsigned frames) {
    AudioTimeStamp time = { .mSampleTime = 0, .mFlags = kAudioTimeStampSampleTimeValid }; AudioUnitRenderActionFlags flags = 0;
    assert(SBHALCaptureCallback(f->core, &flags, &time, 1, frames, NULL) == noErr);
}
static void testFirstPairCaptureAndRingWrap(void) {
    Fixture *f = fixture(16, 16, 0); float values[16]; for (unsigned i = 0; i < 16; ++i) values[i] = 0.9f;
    values[0] = 0.4f; values[1] = 0.2f; SBHALSetCaptureRenderer(f->core, syntheticRender, values);
    float drained[8];
    for (unsigned i = 0; i < 12001; ++i) { capture(f, 8); assert(SBHALReadCapture(f->core, drained, 8) == 8); for (unsigned j = 0; j < 8; ++j) near(drained[j], 0.3f); }
    assert(SBHALFailure(f->core) == 0); destroy(f);
}
static void testOutputPairSilenceInterpolationAndPresentation(void) {
    Fixture *f = fixture(2, 16, 4); int16_t samples[] = {16384, -16384}; uint64_t generation = SBHALGeneration(f->core);
    assert(enqueue(f->core, samples, 2, generation)); AudioUnitRenderActionFlags flags = 0;
    assert(output(f, 0, 4, &flags) == 0); assert(!(flags & kAudioUnitRenderAction_OutputIsSilence));
    float expected[] = {0.25f, 0.5f, 0, -0.5f};
    for (unsigned i = 0; i < 4; ++i) { near(f->planes[0].values[i], expected[i]); near(f->planes[1].values[i], expected[i]); }
    for (unsigned c = 2; c < 16; ++c) for (unsigned i = 0; i < 4; ++i) near(f->planes[c].values[i], 0);
    assert(SBHALCompletedWireFrames(f->core, generation) == 0);
    assert(output(f, 4, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, generation) == 0);
    assert(output(f, 8, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, generation) == 2);
    assert(output(f, 12, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, generation) == 2);
    assert(flags & kAudioUnitRenderAction_OutputIsSilence); destroy(f);
}
static void testStreamingChunkContinuityAndMarkerWrap(void) {
    Fixture *f = fixture(2, 2, 0); int16_t sample = 16384; uint64_t generation = SBHALGeneration(f->core); AudioUnitRenderActionFlags flags = 0;
    for (unsigned i = 0; i < 1000; ++i) {
        assert(enqueue(f->core, &sample, 1, generation)); assert(output(f, i * 4, 2, &flags) == 0);
        near(f->planes[0].values[0], i ? 0.5f : 0.25f); near(f->planes[0].values[1], 0.5f);
        assert(output(f, i * 4 + 2, 2, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, generation) == i + 1);
    }
    destroy(f);
}
static void testInterruptDropsPartialOldChunkAndResetsInterpolation(void) {
    Fixture *f = fixture(2, 2, 0); int16_t old[] = {16384,16384,16384,16384}, fresh[] = {-16384,-16384};
    uint64_t oldGeneration = SBHALGeneration(f->core); assert(enqueue(f->core, old, 4, oldGeneration)); AudioUnitRenderActionFlags flags = 0;
    assert(output(f, 0, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, oldGeneration) == 0);
    uint64_t newGeneration = SBHALInterrupt(f->core); assert(enqueue(f->core, fresh, 2, newGeneration));
    assert(output(f, 4, 4, &flags) == 0); near(f->planes[0].values[0], -0.25f); near(f->planes[0].values[3], -0.5f);
    assert(output(f, 8, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, newGeneration) == 2);
    assert(SBHALCompletedWireFrames(f->core, oldGeneration) == 0); destroy(f);
}
static void interruptBetweenSnapshotReads(void *reference) {
    SBHALCore *core = reference; uint64_t generation = SBHALInterrupt(core); int16_t fresh[] = {-16384, -16384};
    assert(enqueue(core, fresh, 2, generation));
}
static void testInterruptPublicationRaceCannotDiscardNewSpeech(void) {
    Fixture *f = fixture(2, 2, 0); int16_t old[] = {16384, 16384}; assert(enqueue(f->core, old, 2, SBHALGeneration(f->core)));
    SBHALSetSnapshotHook(f->core, interruptBetweenSnapshotReads, f->core); AudioUnitRenderActionFlags flags = 0;
    assert(output(f, 0, 4, &flags) == 0); // New work published between reads is outside this bounded snapshot.
    assert(output(f, 4, 4, &flags) == 0); near(f->planes[0].values[0], -0.25f); near(f->planes[0].values[3], -0.5f);
    assert(output(f, 8, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, SBHALGeneration(f->core)) == 2);
    assert(SBHALFailure(f->core) == 0); destroy(f);
}
static void testBadTopologyAndSizeDoNotTouchUnprovenStorage(void) {
    for (unsigned mode = 0; mode < 3; ++mode) {
        Fixture *f = fixture(2, 2, 0); f->planes[0].values[0] = 42;
        if (mode == 0) f->list->mNumberBuffers = UINT32_MAX;
        if (mode == 1) f->list->mBuffers[0].mDataByteSize = UINT32_MAX;
        if (mode == 2) f->list->mBuffers[0].mDataByteSize = 1;
        AudioUnitRenderActionFlags flags = 0; assert(output(f, 0, 4, &flags) != 0);
        near(f->planes[0].values[0], 42); near(f->planes[0].before, 1234); near(f->planes[0].after, 5678);
        assert(SBHALFailure(f->core) == -70001); destroy(f);
    }
}
static void testInvalidTimestampsFailWithExactCategory(void) {
    Fixture *f = fixture(2, 2, 0); AudioUnitRenderActionFlags flags = 0; AudioTimeStamp time = {0};
    assert(SBHALOutputCallback(f->core, &flags, &time, 0, 4, f->list) == 0);
    SBHALTimelineEvent event; assert(SBHALGetTimelineFault(f->core, &event));
    assert(event.reason == SBHALClockMissingSampleFlag && event.callbackOrdinal == 1 && !event.hasPrevious);
    assert(SBHALFailure(f->core) == -70003); destroy(f);
    double invalid[] = {NAN, INFINITY, -INFINITY};
    for (unsigned i = 0; i < 3; ++i) {
        f = fixture(2, 2, 0); assert(output(f, invalid[i], 4, &flags) == 0);
        assert(SBHALGetTimelineFault(f->core, &event)); assert(event.reason == SBHALClockNonfinite);
        assert(SBHALFailure(f->core) == -70003 && SBHALRecoveredIdleDiscontinuities(f->core) == 0); destroy(f);
    }
}
static void testIdleClockGapsReanchorWithImmutableEvidence(void) {
    Fixture *f = fixture(2, 2, 0); AudioUnitRenderActionFlags flags = 0; SBHALTimelineEvent event, first;
    assert(!SBHALGetTimelineFault(f->core, &event) && !SBHALGetFirstIdleRecovery(f->core, &event));
    assert(output(f, 0, 4, &flags) == 0); assert(output(f, 100, 4, &flags) == 0);
    assert(SBHALGetFirstIdleRecovery(f->core, &first));
    assert(first.reason == SBHALClockForwardGap && first.callbackOrdinal == 2 && first.expectedSampleTime == 4);
    assert(first.actualSampleTime == 100 && first.delta == 96 && first.previousSliceWasSilent);
    assert(!first.emittedUnconfirmedNativeFrames && !first.pendingMarkers);
    assert(output(f, -10, 4, &flags) == 0); assert(output(f, -8, 4, &flags) == 0); // Reset, then overlapping slice.
    assert(SBHALRecoveredIdleDiscontinuities(f->core) == 3 && SBHALFailure(f->core) == 0);
    assert(SBHALGetFirstIdleRecovery(f->core, &event)); assert(memcmp(&event, &first, sizeof(event)) == 0);
    assert(!SBHALGetTimelineFault(f->core, &event)); destroy(f);
}
static void testWhollyQueuedSpeechReanchorsAndPreservesCompletedPrefix(void) {
    Fixture *f = fixture(2, 2, 0); AudioUnitRenderActionFlags flags = 0; int16_t samples[] = {16384,16384}; uint64_t g = SBHALGeneration(f->core);
    assert(output(f, 0, 4, &flags) == 0); assert(enqueue(f->core, samples, 2, g));
    assert(output(f, 100, 4, &flags) == 0); near(f->planes[0].values[0], 0.25f);
    assert(output(f, 104, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, g) == 2);
    assert(enqueue(f->core, samples, 2, g)); assert(output(f, -20, 4, &flags) == 0);
    assert(SBHALCompletedWireFrames(f->core, g) == 2); assert(output(f, -16, 4, &flags) == 0);
    assert(SBHALCompletedWireFrames(f->core, g) == 4 && SBHALRecoveredIdleDiscontinuities(f->core) == 2);
    SBHALTimelineEvent event; assert(SBHALGetFirstIdleRecovery(f->core, &event));
    assert(event.queuedNativeFrames == 4 && event.pendingMarkers == 1 && !event.emittedUnconfirmedNativeFrames);
    destroy(f);
}
static void testPartialSpeechClockGapFailsWithoutCredit(void) {
    Fixture *f = fixture(2, 2, 0); int16_t samples[] = {16384,16384,16384,16384}; uint64_t g = SBHALGeneration(f->core);
    assert(enqueue(f->core, samples, 4, g)); AudioUnitRenderActionFlags flags = 0;
    assert(output(f, 0, 4, &flags) == 0); assert(output(f, 100, 4, &flags) == 0);
    SBHALTimelineEvent event; assert(SBHALGetTimelineFault(f->core, &event));
    assert(event.reason == SBHALClockForwardGap && event.emittedUnconfirmedNativeFrames == 4);
    assert(event.partialNativeFrames == 4 && event.queuedNativeFrames == 4 && event.heldMarkers == 0);
    assert(event.expectedSampleTime == 4 && event.delta == 96 && !event.previousSliceWasSilent);
    assert(SBHALCompletedWireFrames(f->core, g) == 0 && SBHALFailure(f->core) == -70003);
    assert(flags & kAudioUnitRenderAction_OutputIsSilence); near(f->planes[0].values[0], 0); destroy(f);
}
static void testHeldSpeechRejectsForwardBackwardAndOverlappingClock(void) {
    double discontinuities[] = {100,-10,0}; unsigned reasons[] = {SBHALClockForwardGap,SBHALClockBackwardReset,SBHALClockOverlappingSlice};
    for (unsigned i = 0; i < 3; ++i) {
        Fixture *f = fixture(2, 2, 4); int16_t samples[] = {16384,16384}; uint64_t g = SBHALGeneration(f->core);
        assert(enqueue(f->core, samples, 2, g)); AudioUnitRenderActionFlags flags = 0;
        assert(output(f, 0, 4, &flags) == 0); assert(output(f, discontinuities[i], 4, &flags) == 0);
        SBHALTimelineEvent event; assert(SBHALGetTimelineFault(f->core, &event));
        assert(event.reason == reasons[i] && event.heldMarkers == 1 && event.emittedUnconfirmedNativeFrames == 4);
        assert(!event.partialNativeFrames && !event.queuedNativeFrames);
        assert(SBHALCompletedWireFrames(f->core, g) == 0 && SBHALRecoveredIdleDiscontinuities(f->core) == 0);
        destroy(f);
    }
}
static void testInterruptedHeldSpeechCannotPoisonNewClockOrNewWork(void) {
    for (unsigned hooked = 0; hooked < 2; ++hooked) {
        Fixture *f = fixture(2, 2, 4); int16_t samples[] = {16384,16384}; uint64_t old = SBHALGeneration(f->core);
        assert(enqueue(f->core, samples, 2, old)); AudioUnitRenderActionFlags flags = 0; assert(output(f, 0, 4, &flags) == 0);
        if (hooked) SBHALSetSnapshotHook(f->core, interruptBetweenSnapshotReads, f->core);
        else interruptBetweenSnapshotReads(f->core);
        assert(output(f, 100, 4, &flags) == 0); uint64_t fresh = SBHALGeneration(f->core);
        if (hooked) { assert(flags & kAudioUnitRenderAction_OutputIsSilence); assert(output(f, 104, 4, &flags) == 0); }
        near(f->planes[0].values[0], -0.25f);
        assert(output(f, hooked ? 108 : 104, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, fresh) == 0);
        assert(output(f, hooked ? 112 : 108, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, fresh) == 2);
        assert(SBHALCompletedWireFrames(f->core, old) == 0 && SBHALFailure(f->core) == 0);
        assert(SBHALRecoveredIdleDiscontinuities(f->core) == 1); destroy(f);
    }
}
static void testVariableSlicesAndBurstyLongIdlePlayback(void) {
    Fixture *f = fixture(2, 2, 4); AudioUnitRenderActionFlags flags = 0; int16_t samples[] = {16384,16384}; uint64_t g = SBHALGeneration(f->core);
    assert(output(f, 0, 2, &flags) == 0); assert(output(f, 2, 6, &flags) == 0); assert(output(f, 8, 4, &flags) == 0);
    assert(SBHALRecoveredIdleDiscontinuities(f->core) == 0); double clock = 12;
    for (unsigned i = 0; i < 100; ++i) {
        assert(enqueue(f->core, samples, 2, g)); clock += 48000;
        assert(output(f, clock, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, g) == i * 2);
        assert(output(f, clock + 4, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, g) == i * 2);
        assert(output(f, clock + 8, 4, &flags) == 0); assert(SBHALCompletedWireFrames(f->core, g) == (i + 1) * 2);
        clock += 12;
    }
    assert(SBHALRecoveredIdleDiscontinuities(f->core) == 100 && SBHALFailure(f->core) == 0); destroy(f);
}
typedef struct { Fixture *fixture; _Atomic bool done; } PublicationTest;
static void *publishFaultOffThread(void *reference) {
    PublicationTest *test = reference; AudioUnitRenderActionFlags flags = 0;
    assert(output(test->fixture, NAN, 4, &flags) == 0);
    for (unsigned i = 0; i < 100; ++i) assert(output(test->fixture, 100 + i * 4, 4, &flags) == 0);
    atomic_store_explicit(&test->done, true, memory_order_release); return NULL;
}
static void testImmutableFaultPublicationAcrossThreads(void) {
    Fixture *f = fixture(2, 2, 0); PublicationTest test = {.fixture = f}; atomic_init(&test.done, false);
    pthread_t thread; assert(pthread_create(&thread, NULL, publishFaultOffThread, &test) == 0); SBHALTimelineEvent event;
    do {
        if (SBHALGetTimelineFault(f->core, &event)) {
            assert(event.reason == SBHALClockNonfinite && event.callbackOrdinal == 1 && isnan(event.actualSampleTime));
            assert(event.frames == 4 && !event.hasPrevious && !event.pendingMarkers);
        }
        sched_yield();
    } while (!atomic_load_explicit(&test.done, memory_order_acquire));
    assert(pthread_join(thread, NULL) == 0); assert(SBHALGetTimelineFault(f->core, &event));
    assert(event.callbackOrdinal == 1 && event.reason == SBHALClockNonfinite); destroy(f);
}
static void testCaptureOverflowAndNonfiniteSamplesFail(void) {
    Fixture *f = fixture(2, 2, 0); float values[] = {0.1f,0.1f}; SBHALSetCaptureRenderer(f->core, syntheticRender, values);
    for (unsigned i = 0; i < 12001; ++i) capture(f, 8);
    assert(SBHALFailure(f->core) == -70002); destroy(f);
    f = fixture(2, 2, 0); values[0] = NAN; SBHALSetCaptureRenderer(f->core, syntheticRender, values); capture(f, 8);
    assert(SBHALFailure(f->core) == -70001); destroy(f);
}
static void testSpeechAndMarkerBudgetsFailClosed(void) {
    Fixture *f = fixture(2, 2, 0); uint8_t *bytes = calloc(1, 480000); assert(bytes);
    assert(SBHALEnqueuePCM16(f->core, bytes, 480000, 1)); assert(!SBHALEnqueuePCM16(f->core, bytes, 2, 1));
    assert(SBHALFailure(f->core) == -70002); free(bytes); destroy(f);
    f = fixture(2, 2, 0); int16_t value = 1;
    for (unsigned i = 0; i < 128; ++i) assert(enqueue(f->core, &value, 1, 1));
    assert(!enqueue(f->core, &value, 1, 1)); assert(SBHALFailure(f->core) == -70002); destroy(f);
}
static OSStatus failRender(void *reference, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *list) {
    (void)reference; (void)flags; (void)time; (void)bus; (void)frames; (void)list; return -50;
}
static void testRenderFailureRetainsOriginalStatus(void) {
    Fixture *f = fixture(2, 2, 0); SBHALSetCaptureRenderer(f->core, failRender, f); capture(f, 8); assert(SBHALFailure(f->core) == -50); destroy(f);
}
static OSStatus inFlightRender(void *reference, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *list) {
    Fixture *f = reference; assert(!SBHALDestroy(f->core)); float values[] = {0.2f, 0.2f}; return syntheticRender(values, flags, time, bus, frames, list);
}
static void testInFlightCallbackStorageCannotBeDestroyed(void) {
    Fixture *f = fixture(2, 2, 0); SBHALSetCaptureRenderer(f->core, inFlightRender, f); capture(f, 8); assert(SBHALFailure(f->core) == 0); destroy(f);
}
static void testClosedCallbacksAreSilentAndStopCapture(void) {
    Fixture *f = fixture(2, 2, 0); float values[] = {0.1f,0.1f}; SBHALSetCaptureRenderer(f->core, syntheticRender, values); SBHALClose(f->core);
    capture(f, 8); float captured[8]; assert(SBHALReadCapture(f->core, captured, 8) == 0); int16_t value = 1; assert(!enqueue(f->core, &value, 1, 1));
    f->planes[0].values[0] = 1; AudioUnitRenderActionFlags flags = 0; assert(output(f, 0, 8, &flags) == 0);
    assert(flags & kAudioUnitRenderAction_OutputIsSilence); near(f->planes[0].values[0], 0); destroy(f);
}
static void testAllocationBounds(void) {
    assert(!SBHALCreate(1, 2, 8, 0)); assert(!SBHALCreate(2, 65, 8, 0)); assert(!SBHALCreate(2, 2, 8193, 0)); assert(!SBHALCreate(2, 2, 8, 48001));
}
int main(void) {
    testFirstPairCaptureAndRingWrap(); testOutputPairSilenceInterpolationAndPresentation(); testStreamingChunkContinuityAndMarkerWrap();
    testInterruptDropsPartialOldChunkAndResetsInterpolation(); testInterruptPublicationRaceCannotDiscardNewSpeech();
    testBadTopologyAndSizeDoNotTouchUnprovenStorage(); testInvalidTimestampsFailWithExactCategory();
    testIdleClockGapsReanchorWithImmutableEvidence(); testWhollyQueuedSpeechReanchorsAndPreservesCompletedPrefix();
    testPartialSpeechClockGapFailsWithoutCredit(); testHeldSpeechRejectsForwardBackwardAndOverlappingClock();
    testInterruptedHeldSpeechCannotPoisonNewClockOrNewWork(); testVariableSlicesAndBurstyLongIdlePlayback(); testImmutableFaultPublicationAcrossThreads(); testCaptureOverflowAndNonfiniteSamplesFail();
    testSpeechAndMarkerBudgetsFailClosed(); testRenderFailureRetainsOriginalStatus(); testInFlightCallbackStorageCannotBeDestroyed();
    testClosedCallbacksAreSilentAndStopCapture(); testAllocationBounds();
    puts("PASS: 20 HAL callback checks; actual C callbacks, synthetic buffers only, no audio units started.");
}
