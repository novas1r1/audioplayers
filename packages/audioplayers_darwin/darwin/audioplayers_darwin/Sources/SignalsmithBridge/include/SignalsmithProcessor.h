#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C façade over the header-only Signalsmith Stretch C++ library,
/// exposing just the independent pitch-shift path used by the iOS audio tap.
/// The C++ type stays entirely inside the `.mm`, so this header is pure
/// Objective-C and can be imported by Swift in the same module.
///
/// This is the darwin analog of the Android `SignalsmithNative`/`signalsmith_jni`
/// wrapper, so pitch sounds identical across platforms (same DSP library, same
/// frequency-multiplier semantics: `1.0` = unchanged, `2.0` = +1 octave).
///
/// Real-time contract: `-processInterleaved:frames:` and `-processPlanar:frames:`
/// perform **no** heap allocation (all buffers are reserved in the initializer),
/// so they are safe to call from the `MTAudioProcessingTap` audio thread. Only
/// the initializer and `-reset` may be heavy; call those off the render path.
@interface SignalsmithProcessor : NSObject

/// Constant algorithmic latency in frames (`inputLatency + outputLatency`). The
/// pitched output lags the source by this many frames, so any time-aligned
/// mixing done downstream (e.g. the metronome click grid) must be shifted back
/// by this amount while pitch is active.
@property(nonatomic, readonly) int latencyFrames;

/// Configures a stretcher for the given format. `maxFrames` is the largest block
/// the audio callback will ever hand to `process…`; larger blocks are ignored.
- (instancetype)initWithSampleRate:(double)sampleRate
                          channels:(int)channels
                         maxFrames:(int)maxFrames NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Frequency multiplier (`1.0` = unchanged). Cheap and RT-safe; the caller
/// should still bypass `process…` entirely when the multiplier is exactly `1.0`.
- (void)setPitchMultiplier:(double)multiplier;

/// Clears internal analysis/synthesis state. Call on seek or source
/// discontinuity so stale audio does not bleed across the jump. RT-safe.
- (void)reset;

/// In-place pitch shift of `frames` frames of interleaved float32 PCM with the
/// configured channel count. RT-safe. No-op if `frames > maxFrames`.
- (void)processInterleaved:(float *)buffer frames:(int)frames;

/// In-place pitch shift of `frames` frames across `channels` planar float32
/// buffers (`buffers` must hold `channels` pointers). RT-safe.
- (void)processPlanar:(float *_Nullable const *_Nonnull)buffers frames:(int)frames;

@end

NS_ASSUME_NONNULL_END
