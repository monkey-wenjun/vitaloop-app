package me.awen.vitaloop

import android.database.sqlite.SQLiteDatabase
import android.os.Bundle
import androidx.activity.ComponentActivity
import com.awen.running.utils.FileLogger
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * adb 触发的本地备份与诊断入口，和旧版迁移导出一样用 DUMP 权限守卫。
 *
 * 锁屏时 Flutter UI 点不到，但升级/迁移后仍需要核对本机 SQLite 是否真的写进去了。
 * 这里用 VACUUM INTO 生成一致快照，并把各表行数写到 counts.txt；不打印任何健康数值。
 */
class LocalBackupActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val source = File(filesDir, "vitaloop.db")
        val dir = File(getExternalFilesDir(null), "backup").apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val target = File(dir, "vitaloop-$stamp.db")
        val lines = mutableListOf<String>()

        if (!source.exists()) {
            lines += "database not found: ${source.path}"
        } else {
            if (!vacuumInto(source, target)) {
                lines += "VACUUM INTO failed, source remains at ${source.path}"
            } else {
                lines += "snapshot=${target.path}"
                // 诊断快照要给 adb shell / sqlite3 读取；目录本身仍受 Android/data 隔离。
                target.setReadable(true, false)
            }
            queryCounts(target.takeIf { it.exists() } ?: source, lines)
        }
        val counts = File(dir, "counts.txt")
        counts.writeText(lines.joinToString("\n") + "\n")
        counts.setReadable(true, false)
        FileLogger.i(TAG, "本地备份完成: ${target.path}")
        finish()
    }

    private fun vacuumInto(source: File, target: File): Boolean = try {
        if (target.exists()) target.delete()
        SQLiteDatabase.openDatabase(
            source.path,
            null,
            SQLiteDatabase.OPEN_READONLY,
        ).use { db ->
            db.execSQL("VACUUM INTO '${target.path.replace("'", "''")}'")
        }
        target.exists() && target.length() > 0
    } catch (e: Exception) {
        FileLogger.w(TAG, "VACUUM INTO 失败: ${e.message}")
        false
    }

    private fun queryCounts(dbFile: File, lines: MutableList<String>) {
        val tables = listOf(
            "daily_metrics",
            "heart_rate_points",
            "sleep_sessions",
            "sleep_stages",
            "workouts",
            "weight_records",
            "blood_pressure_records",
            "blood_glucose_records",
            "arrhythmia_records",
            "metric_points",
        )
        try {
            SQLiteDatabase.openDatabase(
                dbFile.path,
                null,
                SQLiteDatabase.OPEN_READONLY,
            ).use { db ->
                for (table in tables) {
                    val count = runCatching {
                        db.rawQuery("SELECT COUNT(*) FROM $table", null).use { cursor ->
                            if (cursor.moveToFirst()) cursor.getLong(0) else -1L
                        }
                    }.getOrDefault(-1L)
                    lines += "$table=$count"
                }
                val probes = linkedMapOf(
                    "workouts_legacy_server" to
                        "SELECT COUNT(*) FROM workouts WHERE id LIKE 'legacy-server-%'",
                    "workouts_with_track" to
                        "SELECT COUNT(*) FROM workouts WHERE track_json IS NOT NULL AND track_json <> ''",
                    "workouts_with_samples" to
                        "SELECT COUNT(*) FROM workouts WHERE samples_json IS NOT NULL AND samples_json <> ''",
                    "workouts_latest_ms" to "SELECT MAX(start_ms) FROM workouts",
                    "weight_with_body_comp" to
                        "SELECT COUNT(*) FROM weight_records WHERE body_fat_percent IS NOT NULL",
                    "weight_with_resistance" to
                        "SELECT COUNT(*) FROM weight_records WHERE resistance_ohm IS NOT NULL",
                )
                for ((label, sql) in probes) {
                    val value = runCatching {
                        db.rawQuery(sql, null).use { cursor ->
                            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else -1L
                        }
                    }.getOrDefault(-1L)
                    lines += "$label=$value"
                }
                runCatching {
                    db.rawQuery(
                        "SELECT MAX(ts_ms) FROM heart_rate_points",
                        null,
                    ).use { cursor ->
                        if (cursor.moveToFirst() && !cursor.isNull(0)) {
                            lines += "heart_rate_latest_ms=${cursor.getLong(0)}"
                        }
                    }
                }
                runCatching {
                    db.rawQuery(
                        "SELECT MAX(end_ms) FROM sleep_sessions",
                        null,
                    ).use { cursor ->
                        if (cursor.moveToFirst() && !cursor.isNull(0)) {
                            lines += "sleep_latest_end_ms=${cursor.getLong(0)}"
                        }
                    }
                }
            }
        } catch (e: Exception) {
            lines += "query failed: ${e.message}"
        }
    }

    private companion object {
        const val TAG = "LocalBackup"
    }
}
