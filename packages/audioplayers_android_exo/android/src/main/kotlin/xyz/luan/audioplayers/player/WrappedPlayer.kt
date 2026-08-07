package xyz.luan.audioplayers.player

import android.content.Context
import android.media.AudioManager
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.ReleaseMode
import xyz.luan.audioplayers.source.Source
import kotlin.math.min

class WrappedPlayer internal constructor(
    private val ref: AudioplayersPlugin,
    val eventHandler: EventHandler,
    var context: AudioContextAndroid,
) {
    private var player: PlayerWrapper? = null

    init {
        createPlayer().also {
            player = it
        }
    }
    var source: Source? = null
        set(value) {
            if (field != value) {
                field = value
                prepared = false
                if (value != null) {
                    released = false
                    player?.setSource(value)
                    player?.configAndPrepare()
                } else {
                    released = true
                    playing = false
                    player?.release()
                }
            } else {
                ref.handlePrepared(this, true)
            }
        }

    var volume = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(value, balance)
                }
            }
        }

    var balance = 0.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setVolumeAndBalance(volume, value)
                }
            }
        }

    var rate = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (playing) {
                    player?.setRate(value)
                }
            }
        }

    var pitchShift = 1.0f
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setPitchShift(value)
                }
            }
        }

    var clickTrack: ClickTrackConfig? = null
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setClickTrack(value)
                }
            }
        }

    var loopRegion: LoopRegion? = null
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setLoopRegion(value)
                }
            }
        }

    var releaseMode = ReleaseMode.RELEASE
        set(value) {
            if (field != value) {
                field = value
                if (!released) {
                    player?.setLooping(isLooping)
                }
            }
        }

    val isLooping: Boolean
        get() = releaseMode == ReleaseMode.LOOP

    var released = true

    var prepared: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                ref.handlePrepared(this, value)
            }
        }

    var playing = false
    var shouldSeekTo = -1

    private val focusManager = FocusManager.create(
        this,
        onGranted = {
            // Check if in playing state, as the focus can also be gained e.g. after a phone call, even if not playing.
            if (playing) {
                player?.start()
            }
        },
        onLoss = { isTransient ->
            if (isTransient) {
                // Do not check or set playing state, as the state should be recovered after granting focus again.
                player?.pause()
            } else {
                // Audio focus won't be recovered
                pause()
            }
        },
    )

    fun updateAudioContext(audioContext: AudioContextAndroid) {
        if (context == audioContext) {
            return
        }
        if (context.audioFocus != AudioManager.AUDIOFOCUS_NONE &&
            audioContext.audioFocus == AudioManager.AUDIOFOCUS_NONE
        ) {
            focusManager.handleStop()
        }
        this.context = audioContext.copy()

        // AudioManager values are set globally
        audioManager.mode = context.audioMode
        audioManager.isSpeakerphoneOn = context.isSpeakerphoneOn

        player?.let { p ->
            p.stop()
            prepared = false
            // Context is only applied, once the player.reset() was called
            p.updateContext(context)
            source?.let {
                p.setSource(it)
                p.configAndPrepare()
            }
        }
    }

    // Getters

    /**
     * Returns the duration of the media in milliseconds, if available.
     */
    fun getDuration(): Int? {
        return if (prepared) player?.getDuration() else null
    }

    /**
     * Returns the current position of the playback in milliseconds, if available.
     */
    fun getCurrentPosition(): Int? {
        return if (prepared) player?.getCurrentPosition() else null
    }

    val applicationContext: Context
        get() = ref.getApplicationContext()

    val audioManager: AudioManager
        get() = ref.getAudioManager()

    /**
     * Playback handling methods
     */
    fun resume() {
        if (!playing && !released) {
            playing = true
            if (prepared) {
                requestFocusAndStart()
            }
        }
    }

    // Try to get audio focus and then start.
    private fun requestFocusAndStart() {
        focusManager.maybeRequestAudioFocus()
    }

    fun stop() {
        focusManager.handleStop()
        if (released) {
            return
        }
        if (releaseMode != ReleaseMode.RELEASE) {
            pause()
            if (prepared) {
                player?.stop()
            }
        } else {
            release()
        }
    }

    fun release() {
        focusManager.handleStop()
        if (released) {
            return
        }
        // Releasing abandons any seek deferred while unprepared; resolve it
        // so the Dart future doesn't dangle.
        resolveDeferredSeek()
        if (playing) {
            player?.stop()
        }

        // Setting source to null will reset released, prepared and playing
        // and also calls player.release()
        source = null
    }

    fun pause() {
        if (playing) {
            playing = false
            if (prepared) {
                player?.pause()
            }
        }
    }

    // seek operations cannot be called until after
    // the player is ready.
    fun seek(position: Int) {
        shouldSeekTo = if (prepared) {
            player?.seekTo(position)
            -1
        } else {
            position
        }
    }

    /**
     * Resolves a seek that was deferred while unprepared ([seek] stores it
     * in [shouldSeekTo]; [onPrepared] normally flushes it). Must be called
     * on every path that abandons the pending seek — a playback/load error
     * or a release — because the Dart `seek()` future waits for the
     * seek-complete event and otherwise dangles until its 30 s timeout,
     * freezing every operation queued behind it (pause, stop, loop wraps).
     */
    private fun resolveDeferredSeek() {
        if (shouldSeekTo >= 0) {
            shouldSeekTo = -1
            ref.handleSeekComplete(this)
        }
    }

    /**
     * Player callbacks
     */
    fun onPrepared() {
        prepared = true
        ref.handleDuration(this)
        if (playing) {
            requestFocusAndStart()
        }
        if (shouldSeekTo >= 0) {
            player?.seekTo(shouldSeekTo)
        }
    }

    fun onCompletion() {
        if (releaseMode != ReleaseMode.LOOP) {
            stop()
        }
        ref.handleComplete(this)
    }

    @Suppress("UNUSED_PARAMETER")
    fun onBuffering(percent: Int) {
        // TODO(luan): expose this as a stream
    }

    fun onSeekComplete() {
        ref.handleSeekComplete(this)
    }

    fun onLoopWrap(positionMs: Int) {
        ref.handleLoopWrap(this, positionMs)
    }

    fun handleLog(message: String) {
        ref.handleLog(this, message)
    }

    fun handleError(errorCode: String?, errorMessage: String?, errorDetails: Any?) {
        // A failed load never reaches onPrepared, so a deferred seek would
        // otherwise wait forever (RL: "song just stops" — one hung seek
        // froze the app's whole seek queue for 30 s and silently halted
        // loop restarts).
        resolveDeferredSeek()
        ref.handleError(this, errorCode, errorMessage, errorDetails)
    }

    /**
     * Internal logic. Private methods
     */

    /**
     * Create new player
     */
    private fun createPlayer(): PlayerWrapper {
        return ExoPlayerWrapper(this, ref.getApplicationContext())
    }

    private fun PlayerWrapper.configAndPrepare() {
        setVolumeAndBalance(volume, balance)
        setLooping(isLooping)
        setPitchShift(pitchShift)
        setClickTrack(clickTrack)
        setLoopRegion(loopRegion)
        prepare()
    }

    private fun PlayerWrapper.setVolumeAndBalance(volume: Float, balance: Float) {
        val leftVolume = min(1f, 1f - balance) * volume
        val rightVolume = min(1f, 1f + balance) * volume
        setVolume(leftVolume, rightVolume)
    }

    fun dispose() {
        release()
        player?.dispose()
        player = null
        eventHandler.dispose()
    }
}
