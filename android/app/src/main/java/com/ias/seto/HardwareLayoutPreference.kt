package com.ias.seto

import android.content.Context

/**
 * Physical-keyboard layout in the `seto` SharedPreferences.
 * Raw values match `KeyboardLayout::raw_value` (`sebeol390`, `dubeol`, `sebeolFinal`).
 * Missing or unknown values stay 세벌식 390. The soft keyboard does not read this.
 */
internal object HardwareLayoutPreference {
    const val PREFS = "seto"
    const val KEY = "hardwareLayout"
    const val SEBEOL390 = "sebeol390"
    const val DUBEOL = "dubeol"
    const val SEBEOL_FINAL = "sebeolFinal"

    fun parse(raw: String?): String = when (raw) {
        DUBEOL, SEBEOL_FINAL -> raw
        else -> SEBEOL390
    }

    fun load(context: Context): String =
        parse(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null))

    fun save(context: Context, raw: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, parse(raw))
            .apply()
    }
}
