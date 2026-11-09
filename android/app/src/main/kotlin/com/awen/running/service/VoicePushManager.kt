package com.awen.running.service

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import androidx.core.content.ContextCompat
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 实时语音推流（麦克风 → AAC → FLV → RTMP）。
 *
 * 推流地址由用户填写，例如 rtmp://host/live/<streamKey>?auth_key=...；
 * 不在代码里内置任何域名、流名或鉴权参数。
 */
object VoicePushManager {
    private const val TAG = "VoicePush"
    private const val SAMPLE_RATE = 48_000
    private const val CHANNELS = 1
    private const val BITRATE = 192_000

    @Volatile
    var isPushing: Boolean = false
        private set

    @Volatile
    var errorMessage: String? = null
        private set

    private var pushThread: Thread? = null
    @Volatile
    private var starting = false
    private val shouldStop = AtomicBoolean(false)
    @Volatile
    private var recorderRef: AudioRecord? = null
    @Volatile
    private var encoderRef: MediaCodec? = null
    @Volatile
    private var publisherRef: RtmpPublisher? = null

    fun start(context: Context, pushUrl: String): Boolean {
        if (isPushing || starting) return true
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            errorMessage = "缺少录音权限，无法开启语音"
            return false
        }
        val target = runCatching { parseRtmpUrl(pushUrl) }.getOrNull()
        if (target == null) {
            errorMessage = "推流地址无效，需要 rtmp://host/app/stream 格式"
            return false
        }
        starting = true
        shouldStop.set(false)
        errorMessage = null
        pushThread = Thread({
            try {
                pushLoop(target)
            } finally {
                starting = false
            }
        }, "voice-rtmp").apply { start() }
        return true
    }

    fun stop() {
        shouldStop.set(true)
        try { recorderRef?.stop() } catch (_: Exception) {}
        try { publisherRef?.close() } catch (_: Exception) {}
        starting = false
        pushThread?.join(3_000)
        pushThread = null
        recorderRef = null
        encoderRef = null
        publisherRef = null
        isPushing = false
    }

    private fun pushLoop(target: RtmpTarget) {
        errorMessage = null
        var recorder: AudioRecord? = null
        var encoder: MediaCodec? = null
        val publisher = RtmpPublisher(target.host, target.port, target.app)
        publisherRef = publisher
        try {
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            recorder = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2,
            )
            try {
                if (NoiseSuppressor.isAvailable()) {
                    NoiseSuppressor.create(recorder.audioSessionId)?.enabled = true
                }
            } catch (e: Exception) {
                Log.w(TAG, "开启降噪失败", e)
            }
            recorderRef = recorder

            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                SAMPLE_RATE,
                CHANNELS,
            )
            format.setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            format.setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, minBuf * 2)
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            encoderRef = encoder

            val streamId = publisher.connect(target.streamKey)
            sendAacSequenceHeader(publisher, streamId, byteArrayOf(0x11, 0x88.toByte()))

            recorder.startRecording()
            isPushing = true
            Log.i(TAG, "语音推流开始")

            val pcmBuf = ByteArray(minBuf)
            val startNs = System.nanoTime()
            val bufferInfo = MediaCodec.BufferInfo()
            var flvTimestampMs = 0
            val frameTimestampMs = 1024 * 1000 / SAMPLE_RATE

            while (!shouldStop.get()) {
                val read = recorder.read(pcmBuf, 0, pcmBuf.size)
                if (read <= 0) continue
                val inputPtsUs = (System.nanoTime() - startNs) / 1000

                val inputIndex = encoder.dequeueInputBuffer(10_000)
                if (inputIndex >= 0) {
                    val inputBuffer = encoder.getInputBuffer(inputIndex) ?: continue
                    inputBuffer.clear()
                    inputBuffer.put(pcmBuf, 0, read)
                    encoder.queueInputBuffer(inputIndex, 0, read, inputPtsUs, 0)
                }

                while (!shouldStop.get()) {
                    val outputIndex = encoder.dequeueOutputBuffer(bufferInfo, 0)
                    if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) continue
                    if (outputIndex < 0) break
                    val outputBuffer = encoder.getOutputBuffer(outputIndex) ?: run {
                        encoder.releaseOutputBuffer(outputIndex, false)
                        continue
                    }
                    if (bufferInfo.size > 0 &&
                        bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                    ) {
                        val data = ByteArray(bufferInfo.size)
                        outputBuffer.get(data)
                        sendFlvAudio(publisher, streamId, flvTimestampMs, data)
                        flvTimestampMs += frameTimestampMs
                    }
                    encoder.releaseOutputBuffer(outputIndex, false)
                }
            }
            Log.i(TAG, "语音推流结束")
        } catch (e: Exception) {
            Log.e(TAG, "语音推流失败", e)
            errorMessage = "语音推流失败: ${e.message}"
        } finally {
            try { recorder?.stop() } catch (_: Exception) {}
            recorder?.release()
            try { encoder?.stop() } catch (_: Exception) {}
            encoder?.release()
            publisher.close()
            publisherRef = null
            isPushing = false
        }
    }

    private fun sendAacSequenceHeader(
        publisher: RtmpPublisher,
        streamId: Int,
        config: ByteArray,
    ) {
        val tag = ByteArray(2 + config.size)
        tag[0] = 0xAF.toByte()
        tag[1] = 0x00
        System.arraycopy(config, 0, tag, 2, config.size)
        publisher.sendFlvTag(streamId, 0, 8, tag)
    }

    private fun sendFlvAudio(
        publisher: RtmpPublisher,
        streamId: Int,
        timestamp: Int,
        data: ByteArray,
    ) {
        val tag = ByteArray(2 + data.size)
        tag[0] = 0xAF.toByte()
        tag[1] = 0x01
        System.arraycopy(data, 0, tag, 2, data.size)
        publisher.sendFlvTag(streamId, timestamp, 8, tag)
    }

    private data class RtmpTarget(
        val host: String,
        val port: Int,
        val app: String,
        val streamKey: String,
    )

    private fun parseRtmpUrl(raw: String): RtmpTarget? {
        val uri = URI(raw.trim())
        if (!uri.scheme.equals("rtmp", ignoreCase = true)) return null
        val host = uri.host?.takeIf { it.isNotBlank() } ?: return null
        val port = if (uri.port > 0) uri.port else 1935
        val path = uri.rawPath?.trim('/')?.takeIf { it.isNotBlank() } ?: return null
        val slash = path.indexOf('/')
        if (slash <= 0 || slash >= path.lastIndex) return null
        val app = path.substring(0, slash)
        val stream = path.substring(slash + 1)
        val streamKey = if (uri.rawQuery.isNullOrBlank()) {
            stream
        } else {
            "$stream?${uri.rawQuery}"
        }
        return RtmpTarget(host, port, app, streamKey)
    }
}
