#import "SignalsmithProcessor.h"

#include <cstring>
#include <vector>

#include "signalsmith-stretch/signalsmith-stretch.h"

/// Pitch-only use of Signalsmith Stretch: we always feed `n` input frames and
/// request `n` output frames, so the inferred time ratio is 1.0 (no tempo
/// change) and the transpose factor alone shifts pitch. The library carries its
/// own constant internal latency, so the output stream stays frame-for-frame
/// aligned with the input count — no external ring buffer is needed here.
@implementation SignalsmithProcessor {
  signalsmith::stretch::SignalsmithStretch<float> _stretch;
  int _channels;
  int _maxFrames;
  int _latency;
  // Per-channel scratch, reserved once so the render path never allocates.
  std::vector<std::vector<float>> _inScratch;
  std::vector<std::vector<float>> _outScratch;
  std::vector<const float *> _inPtrs;
  std::vector<float *> _outPtrs;
}

- (instancetype)initWithSampleRate:(double)sampleRate
                          channels:(int)channels
                         maxFrames:(int)maxFrames {
  self = [super init];
  if (self) {
    _channels = channels > 0 ? channels : 1;
    _maxFrames = maxFrames > 0 ? maxFrames : 1;

    // Same preset the Android JNI wrapper uses (presetDefault), so the two
    // platforms share block/latency characteristics.
    _stretch.presetDefault(_channels, (float)sampleRate);
    _stretch.setTransposeFactor(1.0f);
    _latency = _stretch.inputLatency() + _stretch.outputLatency();

    _inScratch.resize(_channels);
    _outScratch.resize(_channels);
    _inPtrs.resize(_channels);
    _outPtrs.resize(_channels);
    for (int c = 0; c < _channels; ++c) {
      _inScratch[c].assign((size_t)_maxFrames, 0.0f);
      _outScratch[c].assign((size_t)_maxFrames, 0.0f);
    }

    _stretch.reset();
  }
  return self;
}

- (int)latencyFrames {
  return _latency;
}

- (void)setPitchMultiplier:(double)multiplier {
  // Cheap: sets a scalar and derived tonality limit, no allocation.
  _stretch.setTransposeFactor((float)multiplier);
}

- (void)reset {
  _stretch.reset();
}

- (void)processPlanar:(float *const *)buffers frames:(int)frames {
  if (frames <= 0 || frames > _maxFrames) {
    return;
  }
  for (int c = 0; c < _channels; ++c) {
    // Copy input out first: `buffers[c]` is both source and destination.
    std::memcpy(_inScratch[c].data(), buffers[c], sizeof(float) * (size_t)frames);
    _inPtrs[c] = _inScratch[c].data();
    _outPtrs[c] = _outScratch[c].data();
  }
  _stretch.process(_inPtrs.data(), frames, _outPtrs.data(), frames);
  for (int c = 0; c < _channels; ++c) {
    std::memcpy(buffers[c], _outScratch[c].data(), sizeof(float) * (size_t)frames);
  }
}

- (void)processInterleaved:(float *)buffer frames:(int)frames {
  if (frames <= 0 || frames > _maxFrames) {
    return;
  }
  const int ch = _channels;
  for (int c = 0; c < ch; ++c) {
    float *dst = _inScratch[c].data();
    for (int i = 0; i < frames; ++i) {
      dst[i] = buffer[i * ch + c];
    }
    _inPtrs[c] = _inScratch[c].data();
    _outPtrs[c] = _outScratch[c].data();
  }
  _stretch.process(_inPtrs.data(), frames, _outPtrs.data(), frames);
  for (int c = 0; c < ch; ++c) {
    const float *src = _outScratch[c].data();
    for (int i = 0; i < frames; ++i) {
      buffer[i * ch + c] = src[i];
    }
  }
}

@end
