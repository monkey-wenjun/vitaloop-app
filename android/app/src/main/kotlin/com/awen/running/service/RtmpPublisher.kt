package com.awen.running.service

import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.util.Random

/**
 * 轻量 RTMP 推流客户端（握手 + connect/publish + FLV 标签发送）。
 * 实时语音/视频推流共用，不依赖第三方库。
 *
 * 推流地址: rtmp://<host>:<port>/<app>/<streamKey>
 */
class RtmpPublisher(
    private val host: String,
    private val port: Int,
    private val app: String
) {

    private val chunkSize = 4096
    private var socket: Socket? = null
    private var output: BufferedOutputStream? = null
    // chunk 读取状态：服务器出向 chunk size（由 Set Chunk Size 消息更新）+ 各 csid 消息头
    private var serverChunkSize = 128
    private val chunkHeaders = HashMap<Int, ChunkHeader>()

    /** 连接并发布指定流，返回 RTMP stream id。 */
    fun connect(streamKey: String): Int {
        val s = Socket(host, port)
        s.tcpNoDelay = true
        s.soTimeout = 15000
        socket = s
        val input = s.getInputStream()
        output = BufferedOutputStream(s.getOutputStream(), 32768)

        rtmpHandshake(input, output!!)
        setChunkSize(output!!)
        val streamId = rtmpConnectAndPublish(input, output!!, streamKey)
        return streamId
    }

    fun close() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        output = null
    }

    // ==================== 握手 ====================

    private fun rtmpHandshake(input: InputStream, output: OutputStream) {
        output.write(0x03)
        val c1 = ByteArray(1536)
        Random().nextBytes(c1)
        output.write(c1)
        output.flush()

        // S0 + S1
        val s0s1 = ByteArray(1537)
        readFully(input, s0s1)
        // S2
        val s2 = ByteArray(1536)
        readFully(input, s2)
        // C2 = 回显 S1
        output.write(s2)
        output.flush()
    }

    private fun setChunkSize(output: OutputStream) {
        // 命令消息 type=1 (Set Chunk Size)，csid=2
        val payload = ByteBuffer.allocate(4).putInt(chunkSize).array()
        val body = ByteArrayOutputStream(16)
        body.write(0x02) // fmt0 csid2
        body.write(0)    // timestamp 0
        body.write(0)
        body.write(0)
        body.write((payload.size shr 16) and 0xFF)
        body.write((payload.size shr 8) and 0xFF)
        body.write(payload.size and 0xFF)
        body.write(0x01) // type Set Chunk Size
        body.write(0); body.write(0); body.write(0); body.write(0) // msg stream id 0
        body.write(payload)
        output.write(body.toByteArray())
        output.flush()
    }

    private fun rtmpConnectAndPublish(input: InputStream, output: OutputStream, streamKey: String): Int {
        // connect
        val connectBody = amf0Command(
            "connect",
            1.0,
            amf0Object(
                "app" to amf0String(app),
                "type" to amf0String("nonprivate"),
                "tcUrl" to amf0String("rtmp://$host/$app"),
                "fpad" to amf0Boolean(false),
                "capability" to amf0Number(15.0),
                "audioCodecs" to amf0Number(3191.0),
                "videoCodecs" to amf0Number(252.0)
            )
        )
        sendCommand(output, 0, connectBody, streamId = 0)
        readUntilResult(input, 1.0)

        // createStream
        sendCommand(output, 0, amf0Command("createStream", 2.0, amf0Null()), streamId = 0)
        val streamId = readCreateStreamResult(input, 2.0)

        // publish
        val publishBody = amf0Command(
            "publish",
            0.0,
            amf0Null(),
            amf0String(streamKey),
            amf0String("live")
        )
        sendCommand(output, 0, publishBody, streamId = 1)
        // 等待 onFCPublish / onStatus（读到任一命令即可，最多 3 条）
        readUntilStatus(input, 3)
        return streamId
    }

    /** 发送 FLV 标签（type 8=音频, 9=视频, 18=script data）。 */
    fun sendFlvTag(streamId: Int, timestamp: Int, type: Int, tag: ByteArray) {
        val out = output ?: throw IOException("RTMP 未连接")
        // 首个 chunk：fmt0 csid6 + 完整消息头
        val head = ByteArrayOutputStream(16)
        head.write(0x06)
        // RTMP 消息头时间戳为 3 字节大端序
        head.write((timestamp shr 16) and 0xFF)
        head.write((timestamp shr 8) and 0xFF)
        head.write(timestamp and 0xFF)
        writeUint24(head, tag.size)
        head.write(type)
        writeLittleInt32(head, streamId)
        // RTMP chunk size 限制的是每个 chunk 的 payload 字节数（含首块），
        // 与 ffmpeg/nginx-rtmp 一致：首块 = 消息头 + chunkSize 字节 payload，
        // 续块 = 1 字节 fmt3 头 + chunkSize 字节 payload。
        val first = minOf(tag.size, chunkSize)
        head.write(tag, 0, first)
        out.write(head.toByteArray())

        // 剩余 chunk：fmt3 csid6（无消息头）
        var off = first
        while (off < tag.size) {
            out.write(0xC6)
            val n = minOf(chunkSize, tag.size - off)
            out.write(tag, off, n)
            off += n
        }
        out.flush()
    }

    // ==================== RTMP 命令读取 ====================

    private fun readFully(input: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) throw IOException("RTMP 连接中断")
            off += n
        }
    }

    private fun readChunk(input: InputStream): RtmpMessage {
        val basic = input.read()
        if (basic < 0) throw IOException("连接中断")
        val fmt = (basic shr 6) and 0x03
        var csid = basic and 0x3F
        if (csid == 0) csid = input.read() + 64
        else if (csid == 1) csid = input.read() + input.read() * 256 + 64

        var length = 0
        var type = 0
        when (fmt) {
            0 -> {
                readUint24(input) // timestamp
                length = readUint24(input)
                type = input.read()
                readLittleInt32(input) // msg stream id
                chunkHeaders[csid] = ChunkHeader(length, type)
            }
            1 -> {
                readUint24(input)
                length = readUint24(input)
                type = input.read()
                chunkHeaders[csid] = ChunkHeader(length, type)
            }
            2 -> readUint24(input)
            3 -> {}
        }
        if (fmt == 2 || fmt == 3) {
            val h = chunkHeaders[csid] ?: throw IOException("未知 chunk 流 $csid")
            length = h.length
            type = h.type
        }
        // 每个 chunk 的 payload 上限就是 chunk size（含首块），与 nginx 出向语义一致
        val firstSize = minOf(length, serverChunkSize)
        var body = ByteArray(firstSize)
        readFully(input, body)
        // 续片（fmt3）
        while (body.size < length) {
            val b3 = input.read()
            if (b3 < 0) throw IOException("连接中断")
            if ((b3 and 0x3F) != csid || (b3 shr 6) != 3) {
                throw IOException("chunk 续片格式错误")
            }
            val n = minOf(serverChunkSize, length - body.size)
            val more = ByteArray(n)
            readFully(input, more)
            body = body + more
        }
        // 服务器告知出向 chunk size
        if (type == 1 && body.size == 4) {
            serverChunkSize =
                ((body[0].toInt() and 0xFF) shl 24) or
                    ((body[1].toInt() and 0xFF) shl 16) or
                    ((body[2].toInt() and 0xFF) shl 8) or
                    (body[3].toInt() and 0xFF)
        }
        return RtmpMessage(type, body)
    }

    private fun readUntilResult(input: InputStream, expectTx: Double) {
        for (i in 0 until 10) {
            val msg = readChunk(input)
            if (msg.type == 0x14) {
                val (name, tx) = parseAmfCommand(msg.body)
                if (name == "_result" && tx == expectTx) return
            }
        }
        throw IOException("RTMP 连接未收到 _result")
    }

    private fun readCreateStreamResult(input: InputStream, expectTx: Double): Int {
        for (i in 0 until 10) {
            val msg = readChunk(input)
            if (msg.type == 0x14) {
                val (name, tx) = parseAmfCommand(msg.body)
                if (name == "_result" && tx == expectTx) {
                    // body: name string, tx number, null, stream id number
                    val off = findNumberAfterNull(msg.body)
                    return off?.let { amfNumberAt(msg.body, it).toInt() } ?: 1
                }
            }
        }
        throw IOException("createStream 失败")
    }

    private fun readUntilStatus(input: InputStream, maxMessages: Int) {
        for (i in 0 until maxMessages + 3) {
            val msg = readChunk(input)
            if (msg.type == 0x14) {
                val (name, _) = parseAmfCommand(msg.body)
                if (name == "onFCPublish" || name == "onStatus") return
            }
        }
    }

    private fun sendCommand(output: OutputStream, timestamp: Int, body: ByteArray, streamId: Int) {
        val head = ByteArrayOutputStream(16)
        head.write(0x03) // fmt0 csid3
        writeUint24(head, timestamp)
        writeUint24(head, body.size)
        head.write(0x14) // type command
        writeLittleInt32(head, streamId)
        output.write(head.toByteArray())
        output.write(body)
        output.flush()
    }

    // ==================== AMF0 ====================

    private fun amf0String(s: String): ByteArray {
        val bytes = s.toByteArray(Charsets.UTF_8)
        val out = ByteArrayOutputStream(bytes.size + 3)
        out.write(0x02)
        out.write((bytes.size shr 8) and 0xFF)
        out.write(bytes.size and 0xFF)
        out.write(bytes)
        return out.toByteArray()
    }

    private fun amf0Number(d: Double): ByteArray {
        val out = ByteArrayOutputStream(9)
        out.write(0x00)
        val bb = ByteBuffer.allocate(8).order(java.nio.ByteOrder.BIG_ENDIAN).putDouble(d).array()
        out.write(bb)
        return out.toByteArray()
    }

    private fun amf0Boolean(b: Boolean): ByteArray =
        byteArrayOf(0x01, if (b) 1 else 0)

    private fun amf0Null(): ByteArray = byteArrayOf(0x05)

    private fun amf0Object(vararg pairs: Pair<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(0x03)
        for ((k, v) in pairs) {
            val kb = k.toByteArray(Charsets.UTF_8)
            out.write((kb.size shr 8) and 0xFF)
            out.write(kb.size and 0xFF)
            out.write(kb)
            out.write(v)
        }
        out.write(0); out.write(0); out.write(0x09) // object end
        return out.toByteArray()
    }

    private fun amf0Command(name: String, tx: Double, vararg args: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(amf0String(name))
        out.write(amf0Number(tx))
        args.forEach { out.write(it) }
        return out.toByteArray()
    }

    private fun parseAmfCommand(body: ByteArray): Pair<String, Double> {
        var off = 0
        // name string
        if (body[off].toInt() != 0x02) return "" to -1.0
        off++
        val len = ((body[off].toInt() and 0xFF) shl 8) or (body[off + 1].toInt() and 0xFF)
        off += 2
        val name = String(body, off, len, Charsets.UTF_8)
        off += len
        // tx number
        if (body[off].toInt() != 0x00) return name to -1.0
        off++
        val tx = ByteBuffer.wrap(body, off, 8).order(java.nio.ByteOrder.BIG_ENDIAN).double
        return name to tx
    }

    private fun findNumberAfterNull(body: ByteArray): Int? {
        // 找 0x05 (null) 之后的下一个 0x00 (number) 位置
        var off = 0
        while (off < body.size - 1) {
            if (body[off].toInt() == 0x05) {
                var j = off + 1
                while (j < body.size - 1) {
                    if (body[j].toInt() == 0x00) return j + 1
                    j++
                }
            }
            off++
        }
        return null
    }

    private fun amfNumberAt(body: ByteArray, off: Int): Double =
        ByteBuffer.wrap(body, off, 8).order(java.nio.ByteOrder.BIG_ENDIAN).double

    private fun readUint24(input: InputStream): Int =
        (input.read() shl 16) or (input.read() shl 8) or input.read()

    private fun readLittleInt32(input: InputStream): Int =
        input.read() or (input.read() shl 8) or (input.read() shl 16) or (input.read() shl 24)

    private fun writeUint24(out: OutputStream, v: Int) {
        out.write((v shr 16) and 0xFF)
        out.write((v shr 8) and 0xFF)
        out.write(v and 0xFF)
    }

    private fun writeLittleInt32(out: OutputStream, v: Int) {
        out.write(v and 0xFF)
        out.write((v shr 8) and 0xFF)
        out.write((v shr 16) and 0xFF)
        out.write((v shr 24) and 0xFF)
    }

    private class RtmpMessage(val type: Int, val body: ByteArray)

    private data class ChunkHeader(val length: Int, val type: Int)
}
