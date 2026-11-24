package com.ias.seto

import android.text.InputType
import android.view.inputmethod.EditorInfo

/** Enter-key caption for the current field. Multiline fields keep a newline mark. */
internal fun returnLabel(info: EditorInfo): String {
    val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
    val multiline = info.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0
    val noEnterAction = info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0
    if (multiline || noEnterAction) return "↵"
    return when (action) {
        EditorInfo.IME_ACTION_GO -> "이동"
        EditorInfo.IME_ACTION_SEARCH -> "검색"
        EditorInfo.IME_ACTION_SEND -> "전송"
        EditorInfo.IME_ACTION_NEXT -> "다음"
        EditorInfo.IME_ACTION_DONE -> "완료"
        EditorInfo.IME_ACTION_PREVIOUS -> "이전"
        else -> "↵"
    }
}

internal fun modeToast(korean: Boolean): String = if (korean) "한" else "A"

/**
 * English pass-through is only for masked password fields.
 *
 * [EditorInfo.IME_FLAG_FORCE_ASCII] is not consulted: X chat and other social
 * composers set it on ordinary text. URI, email, web, filter, visible-password,
 * and no-suggestion variations also stay in the Korean session. [imeOptions] is
 * part of the signature so those flags are visible at the call site.
 */
internal fun englishOnlyField(inputType: Int, imeOptions: Int): Boolean {
    val forceAscii = imeOptions and EditorInfo.IME_FLAG_FORCE_ASCII != 0
    if (!isPassword(inputType) && forceAscii) return false
    return isPassword(inputType)
}

/**
 * No text class ([InputType.TYPE_NULL] and other raw fields). The connection
 * often rejects `setComposingText`. Korean still runs; the client commits text.
 */
internal fun commitFallbackField(inputType: Int): Boolean {
    return inputType and InputType.TYPE_MASK_CLASS == InputType.TYPE_NULL
}

/**
 * A restart of the same editor keeps a learned commit-only mode.
 * X chat drops composing after a short idle and then rejects the
 * delete-and-replace fallback; buffering must stay on across that restart.
 * A different field is classified from its input type again.
 */
internal fun nextCommitOnly(
    restarting: Boolean,
    wasCommitOnly: Boolean,
    englishOnly: Boolean,
    inputType: Int,
): Boolean {
    if (englishOnly) return false
    if (restarting && wasCommitOnly) return true
    return commitFallbackField(inputType)
}

/**
 * Open a field session when input is still active and ours is missing.
 * The live connection is read on each edit, so a new wrapper for the same
 * field must not throw away the syllable in progress.
 */
internal fun shouldReopenSession(
    inputActive: Boolean,
    directInput: Boolean,
    hasSession: Boolean,
    hasConnection: Boolean,
): Boolean {
    if (!inputActive || directInput || !hasConnection) return false
    return !hasSession
}

/** Masked passwords only. Visible-password is an ordinary field for Hangul. */
internal fun isPassword(type: Int): Boolean {
    val variation = type and InputType.TYPE_MASK_VARIATION
    return when (type and InputType.TYPE_MASK_CLASS) {
        InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
        InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        else -> false
    }
}

/** Base rule used by InputMethodService when the hard-keyboard setting is off. */
internal fun showSoftKeyboard(keyboard: Int, hardKeyboardHidden: Int): Boolean {
    return keyboard == KEYBOARD_NOKEYS || hardKeyboardHidden == HARDKEYBOARDHIDDEN_YES
}

internal const val KEYBOARD_NOKEYS = 1
internal const val KEYBOARD_QWERTY = 2
internal const val HARDKEYBOARDHIDDEN_NO = 1
internal const val HARDKEYBOARDHIDDEN_YES = 2
