package com.ias.seto

import android.app.Activity
import android.os.Bundle
import android.widget.RadioGroup

/** IME settings opened from the system keyboard list. No launcher icon. */
class SettingsActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.settings_activity)
        val group = findViewById<RadioGroup>(R.id.hardware_layout)
        group.check(when (HardwareLayoutPreference.load(this)) {
            HardwareLayoutPreference.DUBEOL -> R.id.layout_dubeol
            HardwareLayoutPreference.SEBEOL_FINAL -> R.id.layout_final
            else -> R.id.layout_390
        })
        group.setOnCheckedChangeListener { _, checkedId ->
            val raw = when (checkedId) {
                R.id.layout_dubeol -> HardwareLayoutPreference.DUBEOL
                R.id.layout_final -> HardwareLayoutPreference.SEBEOL_FINAL
                else -> HardwareLayoutPreference.SEBEOL390
            }
            HardwareLayoutPreference.save(this, raw)
        }
    }
}
