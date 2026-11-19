package com.ias.seto

import android.view.KeyEvent
import org.junit.Assert.*
import org.junit.Test

class HardwareKeysTest {
    @Test fun controlOnlyArrowsMatchMac() {
        assertEquals('←', HardwareKeys.controlCharacter(KeyEvent.KEYCODE_COMMA, control = true))
        assertEquals('→', HardwareKeys.controlCharacter(KeyEvent.KEYCODE_PERIOD, control = true))
        // Other physical keys pass through, including the K/T hotkey letters.
        for (code in KeyEvent.KEYCODE_UNKNOWN..KeyEvent.KEYCODE_PROFILE_SWITCH) {
            if (code != KeyEvent.KEYCODE_COMMA && code != KeyEvent.KEYCODE_PERIOD) {
                assertNull(HardwareKeys.controlCharacter(code, control = true))
            }
        }
    }

    @Test fun arrowShortcutsRequireOnlyControl() {
        for (code in listOf(KeyEvent.KEYCODE_COMMA, KeyEvent.KEYCODE_PERIOD)) {
            // Cover every modifier combination, including Ctrl+Shift and Ctrl+Alt (AltGr).
            for (mask in 0..31) {
                val result = HardwareKeys.controlCharacter(code, control = mask and 1 != 0,
                    shift = mask and 2 != 0, alt = mask and 4 != 0,
                    meta = mask and 8 != 0, sym = mask and 16 != 0)
                if (mask == 1) assertNotNull(result) else assertNull(result)
            }
        }
    }

    @Test fun physicalQwertyDoesNotDependOnOsLayout() {
        for (offset in 0..25) {
            assertEquals('a' + offset, HardwareKeys.character(KeyEvent.KEYCODE_A + offset, false))
            assertEquals('A' + offset, HardwareKeys.character(KeyEvent.KEYCODE_A + offset, true))
        }
        for (offset in 0..9) {
            assertEquals("0123456789"[offset], HardwareKeys.character(KeyEvent.KEYCODE_0 + offset, false))
            assertEquals(")!@#$%^&*("[offset], HardwareKeys.character(KeyEvent.KEYCODE_0 + offset, true))
        }
        val punctuation = listOf(KeyEvent.KEYCODE_GRAVE to "`~", KeyEvent.KEYCODE_MINUS to "-_",
            KeyEvent.KEYCODE_EQUALS to "=+", KeyEvent.KEYCODE_LEFT_BRACKET to "[{",
            KeyEvent.KEYCODE_RIGHT_BRACKET to "]}", KeyEvent.KEYCODE_BACKSLASH to "\\|",
            KeyEvent.KEYCODE_SEMICOLON to ";:", KeyEvent.KEYCODE_APOSTROPHE to "'\"",
            KeyEvent.KEYCODE_COMMA to ",<", KeyEvent.KEYCODE_PERIOD to ".>", KeyEvent.KEYCODE_SLASH to "/?")
        for ((code, pair) in punctuation) {
            assertEquals(pair[0], HardwareKeys.character(code, false))
            assertEquals(pair[1], HardwareKeys.character(code, true))
        }
        assertNull(HardwareKeys.character(KeyEvent.KEYCODE_DPAD_LEFT, false))
    }
    @Test fun shiftSpaceMatchesOracleTransitions() {
        val tracker = ShiftSpaceToggleTracker()
        tracker.shiftChanged(true)
        assertTrue(tracker.keyDown(true, true))
        assertTrue(tracker.keyDown(true, true))
        assertFalse(tracker.keyDown(false, true)) // Shift+/
        assertFalse(tracker.keyDown(true, true)) // still holding shift: ordinary space
        tracker.shiftChanged(false)
        tracker.shiftChanged(true)
        assertTrue(tracker.keyDown(true, true))
        assertFalse(tracker.keyDown(true, false))
    }
}
