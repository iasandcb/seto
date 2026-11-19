package com.ias.seto

import android.view.KeyEvent

/** Physical Android key codes, independent of the active OS language/key character map. */
internal object HardwareKeys {
    /** InputController's only Control-only mappings; all other shortcuts pass through. */
    fun controlCharacter(code: Int, control: Boolean, shift: Boolean = false,
                         alt: Boolean = false, meta: Boolean = false, sym: Boolean = false): Char? {
        if (!control || shift || alt || meta || sym) return null
        return when (code) {
            KeyEvent.KEYCODE_COMMA -> '←'
            KeyEvent.KEYCODE_PERIOD -> '→'
            else -> null
        }
    }

    fun character(code: Int, shift: Boolean): Char? {
        if (code in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
            return ((if (shift) 'A' else 'a').code + code - KeyEvent.KEYCODE_A).toChar()
        }
        if (code in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9) {
            return (if (shift) ")!@#$%^&*(" else "0123456789")[code - KeyEvent.KEYCODE_0]
        }
        val pair = when (code) {
            KeyEvent.KEYCODE_GRAVE -> "`~"
            KeyEvent.KEYCODE_MINUS -> "-_"
            KeyEvent.KEYCODE_EQUALS -> "=+"
            KeyEvent.KEYCODE_LEFT_BRACKET -> "[{"
            KeyEvent.KEYCODE_RIGHT_BRACKET -> "]}"
            KeyEvent.KEYCODE_BACKSLASH -> "\\|"
            KeyEvent.KEYCODE_SEMICOLON -> ";:"
            KeyEvent.KEYCODE_APOSTROPHE -> "\'\""
            KeyEvent.KEYCODE_COMMA -> ",<"
            KeyEvent.KEYCODE_PERIOD -> ".>"
            KeyEvent.KEYCODE_SLASH -> "/?"
            KeyEvent.KEYCODE_SPACE -> "  "
            else -> return null
        }
        return pair[if (shift) 1 else 0]
    }
}

/** Same transition rules as Sources/SetoCore/ShiftSpaceToggleTracker.swift. */
internal class ShiftSpaceToggleTracker {
    private var shiftDown = false
    private var otherKeyTyped = false
    fun shiftChanged(isDown: Boolean) {
        if (isDown && !shiftDown) otherKeyTyped = false
        shiftDown = isDown
    }
    fun keyDown(isSpace: Boolean, shift: Boolean): Boolean {
        if (isSpace) return shift && !otherKeyTyped
        if (shift) otherKeyTyped = true
        return false
    }
}
