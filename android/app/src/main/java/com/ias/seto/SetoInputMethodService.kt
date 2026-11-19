package com.ias.seto

import android.content.Context
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import com.ias.seto.core.FieldEdit
import com.ias.seto.core.FieldSession
import com.ias.seto.core.Language
import com.ias.seto.core.SessionUpdate
import com.ias.seto.core.TypoLogger
import org.json.JSONObject
import java.io.File

/**
 * Sebeolsik 390 IME. Hardware QWERTY and the on-screen keyboard both call the
 * shared Rust session. The soft keyboard hides while a hardware keyboard is the
 * active input, unless the system is set to show the on-screen keyboard too.
 */
class SetoInputMethodService : InputMethodService() {
    private val keyboardHost = object : SoftKeyboardView.Host {
        override fun onEffect(effect: SoftLayout.Effect) = dispatch(effect)
        override fun hasMoreText(): Boolean = this@SetoInputMethodService.hasMoreText()
    }
    private var session: FieldSession? = null
    private var applier: FieldEditApplier? = null
    private var tracker = ShiftSpaceToggleTracker()
    private val heldShifts = mutableSetOf<Int>()
    private val consumedKeys = mutableSetOf<Int>()
    private var editing = false
    private var mode = Language.KOREAN
    private var statusMode: Language? = null
    private var directInput = false
    private var autoSwitch = true
    private var correctsTypos = true
    private var keyboard: SoftKeyboardView? = null
    private var modeToast: Toast? = null

    override fun onCreate() {
        super.onCreate()
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        autoSwitch = prefs.getBoolean(KEY_AUTO, true)
        correctsTypos = prefs.getBoolean(KEY_TYPOS, true)
    }

    private fun updateMode(language: Language) {
        val switched = statusMode != null && statusMode != language
        mode = language
        keyboard?.setKorean(language == Language.KOREAN)
        if (statusMode != language) {
            showStatusIcon(if (language == Language.KOREAN) R.drawable.mode_korean else R.drawable.mode_english)
            statusMode = language
            if (switched) showModeToast(language == Language.KOREAN)
        }
    }

    private fun showModeToast(korean: Boolean) {
        modeToast?.cancel()
        modeToast = Toast.makeText(applicationContext, modeToast(korean), Toast.LENGTH_SHORT).also { it.show() }
    }

    override fun onEvaluateInputViewShown(): Boolean {
        // Default framework rule: a connected hardware keyboard hides this view
        // until Settings asks for the on-screen keyboard as well.
        return super.onEvaluateInputViewShown()
    }

    override fun onEvaluateFullscreenMode() = false

    override fun onCreateInputView(): View {
        return SoftKeyboardView(this, keyboardHost).also {
            keyboard = it
            bindKeyboard()
        }
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        keyboard?.cancelPointer()
        bindKeyboard(info)
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        keyboard?.cancelPointer()
        super.onFinishInputView(finishingInput)
    }

    private fun bindKeyboard(info: EditorInfo? = currentInputEditorInfo) {
        keyboard?.setDirect(directInput)
        keyboard?.setKorean(mode == Language.KOREAN)
        if (info != null) keyboard?.setReturnLabel(returnLabel(info))
    }

    private fun dispatch(effect: SoftLayout.Effect) {
        when (effect) {
            is SoftLayout.Effect.Compose -> compose(effect.character)
            is SoftLayout.Effect.Literal -> insertLiteral(effect.text)
            SoftLayout.Effect.Backspace -> backspace()
            SoftLayout.Effect.DeleteWord -> deleteWordWave()
            SoftLayout.Effect.ToggleLanguage -> session?.let { runEdit { it.toggle() } }
            SoftLayout.Effect.ConvertWord -> session?.let { runEdit { it.convertOpenWord() } }
            SoftLayout.Effect.ToggleAutoSwitch -> toggleAutoSwitch()
            SoftLayout.Effect.ReturnKey -> handleReturn()
            SoftLayout.Effect.NextKeyboard -> nextKeyboard(picker = false)
            SoftLayout.Effect.PickKeyboard -> nextKeyboard(picker = true)
            SoftLayout.Effect.Shift, SoftLayout.Effect.ToggleSymbols -> Unit
        }
    }

    private fun hasMoreText(): Boolean {
        val connection = currentInputConnection ?: return false
        if (!connection.getSelectedText(0).isNullOrEmpty()) return true
        val active = session
        if (active != null) {
            try {
                val snapshot = active.state()
                if (snapshot.preedit.isNotEmpty() || snapshot.document.isNotEmpty()) return true
            } catch (error: Exception) {
                fail(error)
                return false
            }
        }
        return !connection.getTextBeforeCursor(1, 0).isNullOrEmpty()
    }

    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        release()
        tracker = ShiftSpaceToggleTracker()
        heldShifts.clear()
        consumedKeys.clear()
        directInput = isPassword(attribute.inputType) || attribute.inputType == InputType.TYPE_NULL
        bindKeyboard(attribute)
        if (directInput) return
        val connection = currentInputConnection ?: return
        val created = createSession(attribute) ?: return
        session = created
        applier = FieldEditApplier(connection, attribute.initialSelStart, attribute.initialSelEnd)
        applyOptions()
        if (session == null) return
        runEdit { created.forceMode(mode) }
    }

    override fun onFinishInput() {
        session?.let { runEdit { it.commitDisplayed(true) } }
        release()
        super.onFinishInput()
    }

    override fun onDestroy() {
        keyboard?.cancelPointer()
        release()
        super.onDestroy()
    }

    private fun release() {
        hideStatusIcon()
        statusMode = null
        destroySession()
    }

    private fun destroySession() {
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

    private fun createSession(attribute: EditorInfo): FieldSession? {
        return try {
            LexiconAssets.load(this)
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
            FieldSession(logger)
        } catch (error: Exception) {
            fail(error)
            null
        }
    }

    private fun applyOptions() {
        val active = session ?: return
        try {
            active.setOptions(autoSwitch, correctsTypos)
        } catch (error: Exception) {
            fail(error)
        }
    }

    private fun toggleAutoSwitch() {
        if (session == null) return
        autoSwitch = !autoSwitch
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_AUTO, autoSwitch).apply()
        applyOptions()
        if (session == null) return
        modeToast?.cancel()
        val label = if (autoSwitch) "자동 한영" else "수동 한영"
        modeToast = Toast.makeText(applicationContext, label, Toast.LENGTH_SHORT).also { it.show() }
    }

    private fun compose(character: Char) {
        val active = session ?: return
        runEdit { active.input(character.toString()) }
    }

    private fun insertLiteral(text: String) {
        val connection = currentInputConnection ?: return
        val active = session
        if (active == null) {
            connection.commitText(text, 1)
            return
        }
        if (runEdit { active.commitDisplayed(true) } == null) return
        applier?.expectInsertion(text.length)
        connection.commitText(text, 1)
        val cursor = applier?.cursorPosition ?: return
        restartSessionAt(cursor)
    }

    private fun restartSessionAt(cursor: Int) {
        val connection = currentInputConnection ?: return
        val attribute = currentInputEditorInfo ?: return
        val language = mode
        destroySession()
        val created = createSession(attribute) ?: return
        session = created
        applier = FieldEditApplier(connection, cursor, cursor)
        applyOptions()
        if (session == null) return
        runEdit { created.forceMode(language) }
    }

    private fun backspace() {
        val active = session
        if (active == null) {
            deleteDirect()
            return
        }
        val update = runEdit { active.backspace() } ?: return
        if (update.field == FieldEdit.None) deliverNativeBackspace()
    }

    private fun deliverNativeBackspace() {
        val connection = currentInputConnection ?: return
        if (applier?.hasSelection == true) {
            applier?.expectNativeBackspace()
            connection.commitText("", 1)
        } else {
            applier?.expectNativeBackspace()
            connection.deleteSurroundingText(1, 0)
        }
    }

    private fun deleteDirect() {
        val connection = currentInputConnection ?: return
        if (!connection.getSelectedText(0).isNullOrEmpty()) connection.commitText("", 1)
        else connection.deleteSurroundingText(1, 0)
    }

    private fun deleteWordWave() {
        val active = session ?: run { deleteDirect(); return }
        val before = try {
            active.state()
        } catch (error: Exception) {
            fail(error)
            return
        }
        val context = currentInputConnection?.getTextBeforeCursor(512, 0)?.toString()
        val selected = !currentInputConnection?.getSelectedText(0).isNullOrEmpty()
        val plan = WordDeletion.plan(context, before.document, before.preedit.isNotEmpty(), selected)
        if (plan.single) {
            backspace()
            return
        }
        if (plan.sessionBackspaces > 0) {
            if (runEdit { active.backspace() } == null) return
            var steps = 1
            while (steps < plan.sessionBackspaces) {
                val mid = try {
                    active.state()
                } catch (error: Exception) {
                    fail(error)
                    return
                }
                if (mid.preedit.isNotEmpty()) break
                val document = mid.document
                if (runEdit { active.backspace() } == null) return
                val afterStep = try {
                    active.state()
                } catch (error: Exception) {
                    fail(error)
                    return
                }
                if (afterStep.document == document) break
                steps += 1
            }
        }
        val after = try {
            active.state()
        } catch (error: Exception) {
            fail(error)
            return
        }
        val host = WordDeletion.hostRemainder(
            plan.suffix, plan.sessionBackspaces, before.document, after.document, after.preedit,
        ) ?: return
        val connection = currentInputConnection ?: return
        applier?.expectNativeDeletion(host.length)
        connection.deleteSurroundingText(host.length, 0)
        val cursor = applier?.cursorPosition ?: return
        restartSessionAt(cursor)
    }

    private fun handleReturn() {
        val info = currentInputEditorInfo
        val action = info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_NONE
        val multiline = (info?.inputType ?: 0) and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0
        val noEnter = (info?.imeOptions ?: 0) and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0
        val performs = !multiline && !noEnter &&
            action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED
        val active = session
        if (active == null) {
            if (performs) currentInputConnection?.performEditorAction(action)
            else currentInputConnection?.commitText("\n", 1)
            return
        }
        if (performs) {
            runEdit { active.commitDisplayed(true) }
            currentInputConnection?.performEditorAction(action)
        } else {
            runEdit { active.input("\n") }
        }
    }

    private fun nextKeyboard(picker: Boolean) {
        val manager = getSystemService(InputMethodManager::class.java)
        if (picker || !switchToNextInputMethod(false)) {
            manager?.showInputMethodPicker()
        }
    }

    private fun runEdit(action: () -> SessionUpdate): SessionUpdate? {
        return try {
            editing = true
            // Every core operation can change mode, including input's automatic
            // conversion, Shift+Space, undo/backspace, and initial forceMode.
            action().also { updateMode(it.mode); applier?.apply(it) }
        } catch (error: Exception) {
            fail(error)
            null
        } finally {
            editing = false
        }
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
        val controlCharacter = HardwareKeys.controlCharacter(
            keyCode, event.isCtrlPressed,
            event.isShiftPressed, event.isAltPressed, event.isMetaPressed, event.isSymPressed,
        )
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

    override fun onUpdateSelection(
        oldSelStart: Int, oldSelEnd: Int, newSelStart: Int,
        newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int,
    ) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        if (editing || session == null) return
        if (applier?.acknowledgesSelection(newSelStart, newSelEnd) == true) return
        // An external cursor/selection move invalidates all relative edit spans. Keep the
        // editor's displayed text, then start an empty core session at the new position.
        currentInputConnection?.finishComposingText()
        val language = mode
        val attribute = currentInputEditorInfo ?: return
        destroySession()
        val connection = currentInputConnection ?: return
        val created = createSession(attribute) ?: return
        session = created
        applier = FieldEditApplier(connection, newSelStart, newSelEnd)
        applyOptions()
        if (session == null) return
        runEdit { created.forceMode(language) }
    }

    private fun isShift(code: Int) = code == KeyEvent.KEYCODE_SHIFT_LEFT || code == KeyEvent.KEYCODE_SHIFT_RIGHT

    private fun isPassword(type: Int): Boolean {
        val variation = type and InputType.TYPE_MASK_VARIATION
        return when (type and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation in setOf(
                InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            )
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    companion object {
        private const val TAG = "Seto"
        private const val PREFS = "seto"
        private const val KEY_AUTO = "autoSwitch"
        private const val KEY_TYPOS = "correctsTypos"
    }
}
