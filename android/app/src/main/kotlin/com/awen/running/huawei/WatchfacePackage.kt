package com.awen.running.huawei

import com.awen.running.utils.FileLogger
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * 把本地表盘包（.hwt）拆成手表能接收的载荷。
 * 结构取证自华为运动健康 17.0.8.320：com.huawei.watchface.f2（本地 .hwt 安装入口）、
 * com.huawei.watchface.c2（unzipWatchFace）、m5（ZipFileUtil）。
 */
object WatchfacePackage {

    /** .hwt 解出来的内层包，名字就是手表侧的服务名 */
    const val INNER_ENTRY = "com.huawei.watchface"
    const val BIN_ENTRY = "watchface.bin"

    private const val MAX_ENTRY_BYTES = 32L * 1024 * 1024

    /** 本地安装时运动健康写死的假表盘号，签名校验只对商城表盘生效 */
    const val DEFAULT_FACE_ID = "000000001"

    private const val CONTAINER_VERSION: Byte = 1
    private const val HEADER_BYTES = 4
    private const val RECORD_BYTES = 30
    private const val CHECKSUM_BYTES = 1
    private const val ID_BYTES = 11
    private const val VERSION_BYTES = 10

    enum class PayloadMode { BIN, PACKAGE, SYNC, HWT }

    data class Prepared(
        val payload: ByteArray,
        /** description.xml 里的 <version>，手表要求主号等于引擎版本、次号不超过 */
        val declaredVersion: String,
        /** description.xml 里的 <screen>，取值是引擎代号，GT 5 为 HWHD09 */
        val declaredScreen: String,
        val note: String
    )

    fun prepare(source: ByteArray, mode: PayloadMode, faceId: String = DEFAULT_FACE_ID): Prepared {
        val outer = unzip(source)
        if (outer.isEmpty()) return Prepared(source, "", "", "不是 zip 包，原样传输")

        val description = outer["description.xml"]
            ?: return Prepared(source, "", "", "包内没有 description.xml，原样传输")
        val version = childText(description, "version")
        val screen = childText(description, "screen")

        if (mode == PayloadMode.HWT) {
            return Prepared(source, version, screen, "传整个 .hwt（${source.size} 字节，手表自己解包）")
        }

        val inner = outer[INNER_ENTRY]
            ?: return Prepared(source, version, screen, "包内没有 $INNER_ENTRY，原样传输")
        val bin = unzip(inner)[BIN_ENTRY]
        return when {
            bin == null -> Prepared(inner, version, screen, "$INNER_ENTRY 不是 zip，传整包")
            mode == PayloadMode.BIN -> Prepared(bin, version, screen, "传 $BIN_ENTRY（${bin.size} 字节）")
            mode == PayloadMode.PACKAGE -> Prepared(inner, version, screen, "传整包，包里含 $BIN_ENTRY")
            else -> Prepared(
                mergeSyncContainer(faceId, version, inner, bin),
                version,
                screen,
                "传同步容器：整包 + $BIN_ENTRY 两段"
            )
        }
    }

    /**
     * 复刻 WatchFaceUtil.mergeToSyncFileDisk：头部是「版本1 + 段数 + 每段 30 字节记录」，
     * 紧跟 1 个 SHA-256 末字节校验，再顺序拼各段。
     */
    fun mergeSyncContainer(faceId: String, version: String, packagePart: ByteArray, binPart: ByteArray): ByteArray {
        val parts = listOf(packagePart to false, binPart to true)
        val recordCount = parts.size
        val headerSize = recordCount * RECORD_BYTES + HEADER_BYTES
        val header = ByteBuffer.allocate(headerSize).order(ByteOrder.BIG_ENDIAN)
        header.put(CONTAINER_VERSION)
        header.put(recordCount.toByte())
        header.putShort(0)
        var offset = headerSize + CHECKSUM_BYTES
        for (part in parts) {
            header.putInt(offset)
            header.putInt(part.first.size)
            header.put(if (part.second) 0 else 1)
            header.put(asciiPadded(faceId, ID_BYTES))
            header.put(asciiPadded(version, VERSION_BYTES))
            offset += part.first.size
        }
        val headerBytes = header.array()
        val checksum = MessageDigest.getInstance("SHA-256").digest(headerBytes).last()
        return ByteArrayOutputStream(headerBytes.size + CHECKSUM_BYTES + offset).apply {
            write(headerBytes)
            write(checksum.toInt())
            parts.forEach { write(it.first) }
        }.toByteArray()
    }

    /** 复刻 f2.d()：主号必须与手表引擎版本相同，次号不能高于手表 */
    fun isVersionAcceptable(declaredVersion: String, deviceMaxVersion: String): Boolean {
        val face = declaredVersion.split('.')
        val device = deviceMaxVersion.split('.')
        if (face.size < 2 || device.size < 2) return false
        val faceMajor = face[0].toIntOrNull() ?: return false
        val faceMinor = face[1].toIntOrNull() ?: return false
        val deviceMajor = device[0].toIntOrNull() ?: return false
        val deviceMinor = device[1].toIntOrNull() ?: return false
        return faceMajor == deviceMajor && faceMinor <= deviceMinor
    }

    private fun unzip(bytes: ByteArray): Map<String, ByteArray> {
        val entries = LinkedHashMap<String, ByteArray>()
        try {
            ZipInputStream(bytes.inputStream()).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    if (!entry.isDirectory) {
                        val body = ByteArrayOutputStream().use { sink ->
                            val buffer = ByteArray(8192)
                            var total = 0L
                            while (true) {
                                val read = zip.read(buffer)
                                if (read <= 0) break
                                total += read
                                if (total > MAX_ENTRY_BYTES) break
                                sink.write(buffer, 0, read)
                            }
                            sink.toByteArray()
                        }
                        if (body.size.toLong() <= MAX_ENTRY_BYTES) {
                            entries[entry.name.substringAfterLast('/')] = body
                        }
                    }
                    zip.closeEntry()
                }
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "表盘包解压失败", e)
        }
        return entries
    }

    private fun asciiPadded(value: String, size: Int): ByteArray {
        val bytes = value.toByteArray()
        return ByteArray(size).also { System.arraycopy(bytes, 0, it, 0, minOf(size, bytes.size)) }
    }

    private fun childText(xml: ByteArray, tagName: String): String {
        val text = xml.decodeToString()
        if (text.contains("<!DOCTYPE", ignoreCase = true) || text.contains("<!ENTITY", ignoreCase = true)) {
            FileLogger.w(TAG, "description.xml 含 DTD/实体声明，拒绝解析")
            return ""
        }
        val name = Regex.escape(tagName)
        val selfClosed = Regex("<$name\\b[^>]*/>")
        val paired = Regex("<$name\\b[^>]*>(.*?)</$name>", RegexOption.DOT_MATCHES_ALL)
        return when {
            selfClosed.containsMatchIn(text) -> ""
            else -> paired.find(text)?.groupValues?.get(1)?.trim().orEmpty()
        }
    }

    private const val TAG = "WatchfacePackage"
}
