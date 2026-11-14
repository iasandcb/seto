package com.ias.seto

import android.view.KeyEvent
import org.junit.Assert.*
import org.junit.Test

class HardwareKeysTest {
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
