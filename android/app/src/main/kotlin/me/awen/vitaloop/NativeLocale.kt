package me.awen.vitaloop

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import java.util.Locale

object NativeLocale {
    private const val PREFS = "vitaloop_locale"
    private const val CODE = "code"

    fun saved(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(CODE, "system")
            ?.takeIf { it.isNotBlank() }
            ?: "system"

    fun current(context: Context): Locale = resolve(context, saved(context))

    fun set(context: Context, code: String) {
        val normalized = code.trim().lowercase().ifEmpty { "system" }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(CODE, normalized)
            .apply()
        apply(context, normalized)
    }

    fun applySaved(context: Context) = apply(context, saved(context))

    private fun apply(context: Context, code: String) {
        val normalized = code.trim().lowercase().ifEmpty { "system" }
        if (Build.VERSION.SDK_INT >= 33) {
            val manager = context.getSystemService(LocaleManager::class.java)
            manager.applicationLocales =
                if (normalized == "system") {
                    LocaleList.getEmptyLocaleList()
                } else {
                    LocaleList.forLanguageTags(normalized)
                }
        }
        val locale = resolve(context, normalized)
        Locale.setDefault(locale)
        updateConfiguration(context, locale)
        updateConfiguration(context.applicationContext, locale)
    }

    private fun resolve(context: Context, code: String): Locale {
        if (code != "system") return Locale.forLanguageTag(code)
        return Resources.getSystem().configuration.locales[0]
    }

    @Suppress("DEPRECATION")
    private fun updateConfiguration(context: Context, locale: Locale) {
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(locale)
        configuration.setLayoutDirection(locale)
        context.resources.updateConfiguration(
            configuration,
            context.resources.displayMetrics,
        )
    }
}
