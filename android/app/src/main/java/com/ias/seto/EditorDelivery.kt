package com.ias.seto

/**
 * X chat sometimes focuses a view with no editor: InputMethodManagerService
 * logs `inputContext=null`, while [android.inputmethodservice.InputMethodService.getCurrentInputConnection]
 * still returns the binding-level connection. That object is not the started
 * editor. `commitText` on it does not reach the view, and a commit-only session
 * consumes hardware keys while the Hangul stays in memory.
 *
 * The binding connection and the started connection are different objects when
 * an editor exists. They are the same object when startInput was given a null
 * context and the getter fell back to the binding.
 */
internal fun editorConnectionMissing(current: Any?, binding: Any?): Boolean {
    if (current == null) return true
    if (binding == null) return false
    return current === binding
}

/** UTF-16-safe edit that turns [pushed] into [next]. [delete] counts Unicode scalars. */
internal data class TextPatch(val delete: Int, val insert: String)

internal fun textPatch(pushed: String, next: String): TextPatch {
    var shared = 0
    val limit = minOf(pushed.length, next.length)
    while (shared < limit && pushed[shared] == next[shared]) shared += 1
    if (shared > 0 && pushed[shared - 1].isHighSurrogate()) shared -= 1
    val delete = pushed.codePointCount(shared, pushed.length)
    return TextPatch(delete = delete, insert = next.substring(shared))
}

/**
 * A `commitText` that returns true on a connection which cannot read the caret
 * did not land in the view. `sendKeyEvent` must itself return true before a
 * hardware key may be consumed; a false return is how BaseInputConnection
 * reports a dead connection, and swallowing the key then drops the character.
 */
internal fun deliveryAccepted(commit: Boolean, visible: Boolean, keyEvent: Boolean): Boolean {
    if (commit && visible) return true
    return keyEvent
}
