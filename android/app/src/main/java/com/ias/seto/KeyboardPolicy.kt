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

/** Base rule used by InputMethodService when the hard-keyboard setting is off. */
internal fun showSoftKeyboard(keyboard: Int, hardKeyboardHidden: Int): Boolean {
    return keyboard == KEYBOARD_NOKEYS || hardKeyboardHidden == HARDKEYBOARDHIDDEN_YES
}

internal const val KEYBOARD_NOKEYS = 1
internal const val KEYBOARD_QWERTY = 2
internal const val HARDKEYBOARDHIDDEN_NO = 1
internal const val HARDKEYBOARDHIDDEN_YES = 2
