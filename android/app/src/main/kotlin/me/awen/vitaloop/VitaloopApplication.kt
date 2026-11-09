package me.awen.vitaloop

import android.app.Application

class VitaloopApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        NativeLocale.applySaved(this)
    }
}
