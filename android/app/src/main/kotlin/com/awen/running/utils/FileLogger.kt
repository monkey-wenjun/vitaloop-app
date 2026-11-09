package com.awen.running.utils

import android.util.Log

object FileLogger {
    @JvmStatic fun d(tag: String, msg: String) = Log.d(tag, msg)
    @JvmStatic fun i(tag: String, msg: String) = Log.i(tag, msg)
    @JvmStatic fun w(tag: String, msg: String) = Log.w(tag, msg)
    @JvmStatic fun e(tag: String, msg: String, tr: Throwable? = null) = Log.e(tag, msg, tr)
}
