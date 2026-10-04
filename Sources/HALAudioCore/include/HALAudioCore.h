#ifndef HAL_AUDIO_CORE_H
#define HAL_AUDIO_CORE_H
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>
#pragma clang assume_nonnull begin

typedef struct SBHALCore SBHALCore;
enum {
    SBHALClockMissingTimestamp = 1, SBHALClockMissingSampleFlag = 2, SBHALClockNonfinite = 3,
    SBHALClockForwardGap = 4, SBHALClockBackwardReset = 5, SBHALClockOverlappingSlice = 6
};
typedef struct {
    uint64_t callbackOrdinal, generation;
    double previousSampleTime, expectedSampleTime, actualSampleTime, delta;
    uint64_t emittedUnconfirmedNativeFrames, queuedNativeFrames, partialNativeFrames;
    UInt32 reason, timestampFlags, actionFlags, previousFrames, frames;
    UInt32 pendingMarkers, heldMarkers, hasPrevious, previousSliceWasSilent;
} SBHALTimelineEvent;
// Setup/render injection precedes I/O. Enqueue+interrupt are serialized by one producer.
// Capture callback, capture drain worker, and output callback each have one owning executor.
// Every cross-executor field is atomic; callback storage is immutable until quiescent teardown.
typedef OSStatus (*SBHALRenderFunction)(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

// Fixed budgets: two seconds of native capture, ten seconds of wire speech, 128 chunks.
SBHALCore *_Nullable SBHALCreate(UInt32 inputChannels, UInt32 outputChannels, UInt32 maximumFrames, UInt32 presentationFrames);
void SBHALSetCaptureUnit(SBHALCore *, AudioUnit);
// Used by offline tests to exercise the same capture callback without an audio unit.
void SBHALSetCaptureRenderer(SBHALCore *, SBHALRenderFunction, void *);
OSStatus SBHALCaptureCallback(void *_Nonnull, AudioUnitRenderActionFlags *_Nonnull, const AudioTimeStamp *_Nonnull, UInt32, UInt32, AudioBufferList *_Nullable);
OSStatus SBHALOutputCallback(void *_Nonnull, AudioUnitRenderActionFlags *_Nonnull, const AudioTimeStamp *_Nonnull, UInt32, UInt32, AudioBufferList *_Nullable);
UInt32 SBHALReadCapture(SBHALCore *, float *, UInt32 capacity);
bool SBHALEnqueuePCM16(SBHALCore *, const uint8_t *, UInt32 byteCount, uint64_t generation);
uint64_t SBHALGeneration(SBHALCore *);
uint64_t SBHALInterrupt(SBHALCore *);
uint64_t SBHALCompletedWireFrames(SBHALCore *, uint64_t generation);
OSStatus SBHALFailure(SBHALCore *);
// Immutable first-event snapshots use release/acquire publication; safe off the audio thread.
bool SBHALGetTimelineFault(SBHALCore *, SBHALTimelineEvent *);
bool SBHALGetFirstIdleRecovery(SBHALCore *, SBHALTimelineEvent *);
uint64_t SBHALRecoveredIdleDiscontinuities(SBHALCore *);
void SBHALClose(SBHALCore *);
// Caller must stop/dispose both units and join the worker before destruction.
// A false result retains the allocation rather than freeing an in-flight callback's memory.
bool SBHALDestroy(SBHALCore *_Nullable);
#ifdef SB_HAL_TEST
// Offline-only deterministic race injection; absent from the shipped C target.
typedef void (*SBHALSnapshotHook)(void *_Nullable);
void SBHALSetSnapshotHook(SBHALCore *, SBHALSnapshotHook, void *_Nullable);
#endif
#pragma clang assume_nonnull end
#endif
