package com.ias.seto

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import com.ias.seto.core.FieldEdit
import com.ias.seto.core.FieldSession
import com.ias.seto.core.Language
import com.ias.seto.core.SessionUpdate
import com.ias.seto.core.TypoLogger
import org.json.JSONObject
import java.io.File

/** Hardware-only IME. No input view is created, including when a hardware keyboard is absent. */
class SetoInputMethodService : InputMethodService() {
    private var session: FieldSession? = null
    private var applier: FieldEditApplier? = null
    private var tracker = ShiftSpaceToggleTracker()
    private val heldShifts = mutableSetOf<Int>()
    private val consumedKeys = mutableSetOf<Int>()
    private var editing = false
    private var mode = Language.KOREAN
    private var statusMode: Language? = null

    private fun updateMode(language: Language) {
        mode = language
        if (statusMode != language) {
            showStatusIcon(if (language == Language.KOREAN) R.drawable.mode_korean else R.drawable.mode_english)
            statusMode = language
        }
    }

    override fun onEvaluateInputViewShown() = false
    override fun onEvaluateFullscreenMode() = false

    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        release()
        tracker = ShiftSpaceToggleTracker()
        heldShifts.clear()
        consumedKeys.clear()
        if (isPassword(attribute.inputType) || attribute.inputType == InputType.TYPE_NULL) return
        val connection = currentInputConnection ?: return
        try {
            LexiconAssets.load(this)
            // Android owns storage; Rust receives only a callback, never a typo-log path.
            val logger = if ((attribute.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING) != 0) null
                else object : TypoLogger {
                    override fun record(wrong: String, wrongKeys: String, finalText: String, finalKeys: String) {
                        try {
                            val row = JSONObject().put("wrong", wrong).put("wrongKeys", wrongKeys)
                                .put("final", finalText).put("finalKeys", finalKeys)
                            File(filesDir, "typos.jsonl").appendText("$row\n")
                        } catch (error: Exception) { Log.w(TAG, "Could not save local typo record", error) }
                    }
                }
            session = FieldSession(logger)
            applier = FieldEditApplier(connection, attribute.initialSelStart, attribute.initialSelEnd)
            session?.let { runEdit { it.forceMode(mode) } }
        } catch (error: Exception) { fail(error) }
    }

    override fun onFinishInput() {
        session?.let { runEdit { it.commitDisplayed(true) } }
        release()
        super.onFinishInput()
    }
    override fun onDestroy() { release(); super.onDestroy() }
    private fun release() {
        hideStatusIcon()
        statusMode = null
        session?.let {
            try { it.shutdown() } catch (_: Exception) { /* poisoned state can still be destroyed */ }
            it.destroy()
        }
        session = null
        applier = null
    }
    private fun fail(error: Exception) {
        Log.e(TAG, "Seto field session stopped", error)
        currentInputConnection?.finishComposingText()
        release()
    }
    private fun runEdit(action: () -> SessionUpdate): SessionUpdate? {
        return try {
            editing = true
            // Every core operation can change mode, including input's automatic
            // conversion, Shift+Space, undo/backspace, and initial forceMode.
            action().also { updateMode(it.mode); applier?.apply(it) }
        } catch (error: Exception) { fail(error); null }
        finally { editing = false }
    }
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (isShift(keyCode)) {
            heldShifts.add(keyCode)
            tracker.shiftChanged(true)
            return super.onKeyDown(keyCode, event)
        }
        tracker.shiftChanged(event.isShiftPressed || heldShifts.isNotEmpty())
        val toggle = tracker.keyDown(keyCode == KeyEvent.KEYCODE_SPACE, event.isShiftPressed)
        val active = session ?: return super.onKeyDown(keyCode, event)
        val controlCharacter = HardwareKeys.controlCharacter(keyCode, event.isCtrlPressed,
            event.isShiftPressed, event.isAltPressed, event.isMetaPressed, event.isSymPressed)
        if (controlCharacter != null) {
            runEdit { active.input(controlCharacter.toString()) }
            consumedKeys.add(keyCode)
            return true
        }
        if (event.isCtrlPressed || event.isAltPressed || event.isMetaPressed || event.isSymPressed) {
            runEdit { active.commitDisplayed(true) }
            return super.onKeyDown(keyCode, event)
        }
        val handled = when {
            toggle -> {
                if (event.repeatCount == 0) runEdit { active.toggle() }
                true
            }
            keyCode == KeyEvent.KEYCODE_DEL -> {
                val update = runEdit { active.backspace() }
                if (update?.field == FieldEdit.None) applier?.expectNativeBackspace()
                update == null || update.field != FieldEdit.None
            }
            else -> {
                val character = HardwareKeys.character(keyCode, event.isShiftPressed)
                if (character != null) {
                    runEdit { active.input(character.toString()) }
                    true
                } else {
                    // Navigation, Enter, Tab, shortcuts and unknown keys end the open run.
                    runEdit { active.commitDisplayed(true) }
                    false
                }
            }
        }
        if (handled) consumedKeys.add(keyCode)
        return handled || super.onKeyDown(keyCode, event)
    }
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (isShift(keyCode)) {
            heldShifts.remove(keyCode)
            tracker.shiftChanged(heldShifts.isNotEmpty())
        }
        if (consumedKeys.remove(keyCode)) return true
        return super.onKeyUp(keyCode, event)
    }
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int,
                                   newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        if (editing || session == null) return
        if (applier?.acknowledgesSelection(newSelStart, newSelEnd) == true) return
        // An external cursor/selection move invalidates all relative edit spans. Keep the
        // editor's displayed text, then start an empty core session at the new position.
        currentInputConnection?.finishComposingText()
        release()
        currentInputEditorInfo?.let {
            it.initialSelStart = newSelStart
            it.initialSelEnd = newSelEnd
            onStartInput(it, true)
        }
    }

    private fun isShift(code: Int) = code == KeyEvent.KEYCODE_SHIFT_LEFT || code == KeyEvent.KEYCODE_SHIFT_RIGHT
    private fun isPassword(type: Int): Boolean {
        val variation = type and InputType.TYPE_MASK_VARIATION
        return when (type and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation in setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD, InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }
    companion object { private const val TAG = "Seto" }
}
