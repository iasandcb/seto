package com.ias.seto

import org.junit.Assert.assertEquals
import org.junit.Test

class HardwareLayoutPreferenceTest {
    @Test fun missingOrUnknownValuesStay390() {
        assertEquals(HardwareLayoutPreference.SEBEOL390, HardwareLayoutPreference.parse(null))
        assertEquals(HardwareLayoutPreference.SEBEOL390, HardwareLayoutPreference.parse(""))
        assertEquals(HardwareLayoutPreference.SEBEOL390, HardwareLayoutPreference.parse("Dubeol"))
        assertEquals(HardwareLayoutPreference.SEBEOL390, HardwareLayoutPreference.parse("세벌식 390"))
        assertEquals(HardwareLayoutPreference.SEBEOL390, HardwareLayoutPreference.parse("sebeol"))
    }

    @Test fun rawValuesMatchTheRustLayoutTokens() {
        assertEquals("sebeol390", HardwareLayoutPreference.SEBEOL390)
        assertEquals("dubeol", HardwareLayoutPreference.DUBEOL)
        assertEquals("sebeolFinal", HardwareLayoutPreference.SEBEOL_FINAL)
        assertEquals(HardwareLayoutPreference.DUBEOL, HardwareLayoutPreference.parse("dubeol"))
        assertEquals(HardwareLayoutPreference.SEBEOL_FINAL, HardwareLayoutPreference.parse("sebeolFinal"))
        assertEquals(HardwareLayoutPreference.SEBEOL390, HardwareLayoutPreference.parse("sebeol390"))
    }
}
