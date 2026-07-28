package xyz.luan.audioplayers.player

/**
 * Native gapless loop region, mirrored from the Dart side via the
 * `setLoopRegion` method channel call.
 *
 * Bounds are in *media time* ms (the song's own timeline, independent of
 * playback speed). While a region is set, the engine wraps the playhead from
 * [endMs] back to [startMs] on the playback side — no Dart round trip — and
 * reports each wrap through the `audio.onLoopWrap` event.
 */
data class LoopRegion(
    val startMs: Int,
    val endMs: Int,
)
