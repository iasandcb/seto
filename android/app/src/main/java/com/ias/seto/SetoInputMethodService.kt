package com.ias.seto

import android.content.Context
import android.content.SharedPreferences
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import com.ias.seto.core.Atom
import com.ias.seto.core.AtomReading
import com.ias.seto.core.FieldEdit
import com.ias.seto.core.FieldSession
import com.ias.seto.core.JamoPosition
import com.ias.seto.core.Language
import com.ias.seto.core.LayoutKind
import com.ias.seto.core.SessionUpdate
import com.ias.seto.core.TypoLogger
import org.json.JSONObject
import java.io.File

/**
 * Hardware QWERTY feeds the selected session layout (default 세벌식 390).
 * The on-screen keyboard matches the iOS touch board: letter taps are two-set
 * atoms, and the view hides while a hardware keyboard is the active input
 * unless the system is set to show the on-screen keyboard too.
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
    private var resettingField = false
    private var rebinding = false
    private var inputActive = false
    private var inputGeneration = 0
    private var deferRestart = false
    private var deferredRestarting = false
    private var deferredAttribute: EditorInfo? = null
    private var beginningField = false
    private var commitOnly = false
    /** StartInput was given a null editor context. Hardware keys must not be eaten. */
    private var editorMissing = false
    private var startedLookupFailed = false
    private var reportedStart = -1
    private var reportedEnd = -1
    private var mode = Language.KOREAN
    private var statusMode: Language? = null
    private var directInput = false
    private var autoSwitch = true
    private var correctsTypos = true
    private var hardwareLayout = LayoutKind.SEBEOL390
    private var keyboard: SoftKeyboardView? = null
    private var modeToast: Toast? = null
    private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == HardwareLayoutPreference.KEY) mainExecutor.execute { applyHardwareLayout() }
    }

    override fun onCreate() {
        super.onCreate()
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        autoSwitch = prefs.getBoolean(KEY_AUTO, true)
        correctsTypos = prefs.getBoolean(KEY_TYPOS, true)
        hardwareLayout = readHardwareLayout()
        prefs.registerOnSharedPreferenceChangeListener(preferenceListener)
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

    override fun onBindInput() {
        super.onBindInput()
        Log.i(TAG, "onBindInput connected=${currentInputConnection != null}")
        ensureSession("onBindInput")
    }

    override fun onUnbindInput() {
        Log.i(TAG, "onUnbindInput")
        release()
        inputActive = false
        super.onUnbindInput()
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        keyboard?.cancelPointer()
        bindKeyboard(info)
        Log.i(TAG, "onStartInputView restarting=$restarting")
        ensureSession("onStartInputView")
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        keyboard?.cancelPointer()
        Log.i(TAG, "onFinishInputView finishingInput=$finishingInput")
        // The default implementation calls finishComposingText() when the soft
        // keyboard hides. A hardware keyboard keeps this field focused after that
        // hide (Galaxy Fold idle timeout, or the framework hiding the view).
        // Finishing the span here makes the next Hangul edit miss, and X chat
        // then rejects the repair. Leave the syllable in place.
    }

    private fun bindKeyboard(info: EditorInfo? = currentInputEditorInfo) {
        keyboard?.setDirect(directInput)
        keyboard?.setKorean(mode == Language.KOREAN)
        keyboard?.setAutomatic(autoSwitch)
        if (info != null) keyboard?.setReturnLabel(returnLabel(info))
    }

    private fun dispatch(effect: SoftLayout.Effect) {
        refreshEditorLink("soft-key")
        ensureSession("soft-key")
        when (effect) {
            is SoftLayout.Effect.Compose -> compose(effect.character)
            is SoftLayout.Effect.Literal -> insertLiteral(effect.text)
            SoftLayout.Effect.Backspace -> backspace()
            SoftLayout.Effect.DeleteWord -> deleteWordWave()
            SoftLayout.Effect.ToggleLanguage -> session?.let { runEdit { it.toggle() } }
            SoftLayout.Effect.ConvertWord -> session?.let { runEdit { it.convertOpenWord() } }
            SoftLayout.Effect.ShowAutoMenu -> Unit
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
        inputGeneration++
        inputActive = true
        hardwareLayout = readHardwareLayout()
        tracker = ShiftSpaceToggleTracker()
        heldShifts.clear()
        consumedKeys.clear()
        val englishOnly = englishOnlyField(attribute.inputType, attribute.imeOptions)
        // TYPE_NULL (X chat and other raw/Compose fields) still gets Hangul.
        // IME_FLAG_FORCE_ASCII is not a reason to skip the Korean session.
        // An idle restart must keep commit-only: X drops the composing span and
        // rejects deleteSurroundingText, which used to end the Korean session.
        commitOnly = nextCommitOnly(restarting, commitOnly, englishOnly, attribute.inputType)
        directInput = englishOnly
        reportedStart = attribute.initialSelStart
        reportedEnd = attribute.initialSelEnd
        Log.i(
            TAG,
            "onStartInput package=${attribute.packageName} inputType=0x${Integer.toHexString(attribute.inputType)} " +
                "imeOptions=0x${Integer.toHexString(attribute.imeOptions)} restarting=$restarting " +
                "englishOnly=$englishOnly commitOnly=$commitOnly connected=${currentInputConnection != null}",
        )
        bindKeyboard(attribute)
        refreshEditorLink("onStartInput")
        if (editing) {
            // X chat restarts input when the typing pause ends. Finishing that
            // inside an open batch drops the characters on the old connection.
            Log.i(TAG, "onStartInput deferred; edit in progress restarting=$restarting")
            deferRestart = true
            deferredRestarting = restarting
            deferredAttribute = attribute
            return
        }
        beginField(restarting)
    }

    private fun beginField(restarting: Boolean) {
        if (beginningField) {
            Log.i(TAG, "onStartInput reentered; this start will rebind when the outer one finishes")
            return
        }
        beginningField = true
        try {
            if (directInput) {
                release()
                return
            }
            if (restarting && session != null) flushBufferedText()
            release()
            ensureSession(if (restarting) "onStartInput restart" else "onStartInput")
        } finally {
            beginningField = false
            // A restart that arrived during flush is satisfied by the rebind above.
            deferRestart = false
            deferredAttribute = null
        }
    }

    /** Put buffered Hangul or an unconfirmed English prefix on screen before the session is replaced. */
    private fun flushBufferedText() {
        val pending = try {
            session?.state()?.preedit?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
        Log.i(TAG, "onStartInput restart; flush buffered text len=${pending?.length ?: 0}")
        val flushed = session?.let { runEdit { it.commitDisplayed(true) } }
        if (flushed != null || pending.isNullOrEmpty()) return
        val wrote = currentInputConnection?.commitText(pending, 1) == true
        Log.i(TAG, "onStartInput restart; direct commit of buffered text wrote=$wrote")
    }

    private fun runDeferredRestart() {
        if (!deferRestart || editing || beginningField) return
        val restarting = deferredRestarting
        deferRestart = false
        deferredAttribute = null
        Log.i(TAG, "running deferred onStartInput restarting=$restarting")
        beginField(restarting)
    }

    override fun onFinishInput() {
        val generation = inputGeneration
        Log.i(TAG, "onFinishInput")
        session?.let { runEdit { it.commitDisplayed(true) } }
        if (generation != inputGeneration) {
            Log.i(TAG, "onFinishInput kept the session from a newer onStartInput")
            return
        }
        release()
        inputActive = false
        super.onFinishInput()
    }

    override fun onDestroy() {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .unregisterOnSharedPreferenceChangeListener(preferenceListener)
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
            FieldSession.withLayout(logger, hardwareLayout)
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
        keyboard?.setAutomatic(autoSwitch)
        applyOptions()
        if (session == null) return
        modeToast?.cancel()
        val label = if (autoSwitch) "자동 한영" else "수동 한영"
        modeToast = Toast.makeText(applicationContext, label, Toast.LENGTH_SHORT).also { it.show() }
    }

    private fun compose(character: Char) {
        if (editorMissing) {
            val accepted = editWithoutEditor { active ->
                val touch = SoftLayout.dubeolAtom(character)
                if (touch == null) {
                    active.input(character.toString())
                } else {
                    val position = if (touch.jungseong) JamoPosition.JUNGSEONG else JamoPosition.CHOSEONG
                    active.inputAtom(
                        Atom(
                            LayoutKind.DUBEOL,
                            touch.english.toString(),
                            AtomReading.Jamo(touch.scalar.toUInt(), position),
                        ),
                    )
                }
            }
            if (!accepted) Log.i(TAG, "soft key not delivered; no editor InputConnection")
            return
        }
        val active = session ?: return
        val touch = SoftLayout.dubeolAtom(character)
        if (touch == null) {
            // Space and newline. Hardware keys use input(), which follows the session layout.
            runEdit { active.input(character.toString()) }
            return
        }
        val position = if (touch.jungseong) JamoPosition.JUNGSEONG else JamoPosition.CHOSEONG
        val atom = Atom(
            LayoutKind.DUBEOL,
            touch.english.toString(),
            AtomReading.Jamo(touch.scalar.toUInt(), position),
        )
        runEdit { active.inputAtom(atom) }
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

    private fun openField(
        start: Int,
        end: Int,
        language: Language,
        attribute: EditorInfo? = currentInputEditorInfo,
    ) {
        val info = attribute ?: run {
            Log.i(TAG, "openField deferred; no editor info")
            return
        }
        if (currentInputConnection == null) {
            Log.i(TAG, "openField deferred; no connection")
            return
        }
        val created = createSession(info) ?: return
        session = created
        // Fetch the connection on every edit. X chat replaces it on idle
        // (invalidateInput / restartInput) and a cached one returns false.
        applier = FieldEditApplier({ currentInputConnection }, start, end).also { it.commitOnly = commitOnly }
        applyOptions()
        if (session == null) return
        runEdit {
            val update = created.forceMode(language)
            if (commitOnly) created.setComposing(false, true)
            update
        }
    }

    /**
     * Input can stay started while our session is gone: an idle restart passed a
     * connection that was not ready yet, a rejected edit called release(), or
     * onStartInputView never ran because the hardware keyboard hid the soft view.
     * Bind again before the key falls through as English.
     */
    private fun ensureSession(reason: String) {
        val live = currentInputConnection
        if (!shouldReopenSession(inputActive, directInput, session != null, live != null)) return
        if (rebinding) return
        val info = currentInputEditorInfo
        if (live == null || info == null) {
            Log.i(TAG, "rebind deferred ($reason); connection=${live != null} editor=${info != null}")
            return
        }
        Log.i(TAG, "rebind field session ($reason) hadSession=${session != null} commitOnly=$commitOnly")
        rebinding = true
        try {
            val start = if (reportedStart >= 0) reportedStart else info.initialSelStart
            val end = if (reportedEnd >= 0) reportedEnd else info.initialSelEnd
            release()
            openField(start, end, mode, info)
        } finally {
            rebinding = false
        }
    }

    private fun restartSessionAt(cursor: Int) {
        if (rebinding) return
        if (currentInputConnection == null || currentInputEditorInfo == null) {
            Log.i(TAG, "restartSessionAt deferred; editor not ready")
            release()
            return
        }
        val language = mode
        rebinding = true
        try {
            release()
            openField(cursor, cursor, language)
        } finally {
            rebinding = false
        }
    }

    /** Fold a syllable the host already committed, or drop the session if setText replaced it. */
    private fun prepareComposition(): Boolean {
        if (applier?.composingSpanStale() != true) return true
        if (hostShowsSessionText()) {
            adoptCommitFallback()
            return session != null
        }
        restartAtReportedSelection()
        return false
    }

    private fun adoptCommitFallback() {
        val active = session ?: return
        if (!commitOnly) Log.i(TAG, "commit fallback: host has no composing span")
        commitOnly = true
        applier?.commitOnly = true
        try {
            active.setComposing(false, true)
        } catch (error: Exception) {
            fail(error)
            return
        }
        applier?.noteComposingFolded()
    }

    private fun hostShowsSessionText(): Boolean {
        val active = session ?: return false
        val document = try {
            active.state().document
        } catch (_: Exception) {
            return true
        }
        if (document.isEmpty()) return true
        val before = currentInputConnection?.getTextBeforeCursor(document.length, 0)?.toString() ?: return true
        return before.endsWith(document)
    }

    private fun restartAtReportedSelection() {
        if (resettingField || rebinding) return
        val info = currentInputEditorInfo
        val connection = currentInputConnection
        if (info == null || connection == null) {
            Log.i(TAG, "selection restart deferred; editor not ready")
            release()
            return
        }
        val start = if (reportedStart >= 0) reportedStart else applier?.cursorPosition ?: 0
        val end = if (reportedEnd >= 0) reportedEnd else start
        Log.i(TAG, "restart session at selection $start..$end")
        resettingField = true
        try {
            connection.finishComposingText()
            val language = mode
            release()
            openField(start, end, language, info)
        } finally {
            resettingField = false
        }
    }

    private fun backspace() {
        val active = session
        if (active == null) {
            if (commitOnly) sendDelKey() else deleteDirect()
            return
        }
        val hidden = hiddenSyllable()
        val update = runEdit { active.backspace() } ?: return
        if (update.field == FieldEdit.None && !keptInBuffer(hidden, update)) {
            if (commitOnly) sendDelKey() else deliverNativeBackspace()
        }
    }

    /** The open syllable was never sent, so backspace must not delete host text. */
    private fun hiddenSyllable(): Boolean {
        if (!commitOnly) return false
        val active = session ?: return false
        return try {
            active.state().preedit.isNotEmpty()
        } catch (_: Exception) {
            false
        }
    }

    private fun keptInBuffer(hiddenBefore: Boolean, update: SessionUpdate): Boolean {
        return commitOnly && (hiddenBefore || update.preedit.isNotEmpty())
    }

    private fun sendDelKey() {
        val connection = currentInputConnection ?: return
        val now = android.os.SystemClock.uptimeMillis()
        connection.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL, 0))
        connection.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL, 0))
        applier?.expectNativeBackspace()
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
        if (commitOnly) {
            backspace()
            return
        }
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
        if (!prepareComposition()) return null
        val generation = inputGeneration
        return try {
            editing = true
            // Every core operation can change mode, including input's automatic
            // conversion, Shift+Space, undo/backspace, and initial forceMode.
            val update = action()
            if (generation != inputGeneration) {
                Log.i(TAG, "edit dropped; input restarted during the edit")
                return null
            }
            updateMode(update.mode)
            applier?.apply(update)
            if (generation != inputGeneration) return update
            if (applier?.fellBackToCommit == true || applier?.composingSpanStale() == true) {
                if (hostShowsSessionText()) adoptCommitFallback() else restartAtReportedSelection()
            }
            update
        } catch (error: EditorRejectedEdit) {
            // A stale connection or a failed batch answers false. The key must
            // be retried on the live connection; consuming it here drops the
            // character for both Hangul and English.
            Log.i(TAG, "editor rejected an edit; will rebind commit-only")
            commitOnly = true
            release()
            null
        } catch (error: Exception) {
            fail(error)
            null
        } finally {
            editing = false
            runDeferredRestart()
        }
    }

    /** Apply [action] once, and once more on a fresh session if the editor rejected it. */
    private fun edit(action: (FieldSession) -> SessionUpdate): SessionUpdate? {
        fun applyOnce(): SessionUpdate? {
            val active = session ?: return null
            return runEdit { action(active) }
        }
        val first = applyOnce()
        if (first != null) return first
        if (session == null) {
            Log.i(TAG, "rebinding after a rejected edit")
            ensureSession("rejected edit")
        }
        return applyOnce()
    }

    private fun inputText(text: String): Boolean {
        if (session == null) ensureSession("input")
        if (session == null) return false
        // A live session with a null update did not commit this key. Consuming
        // it anyway is how characters disappear after X restarts input.
        val update = edit { it.input(text) } ?: return false
        if (update.field == FieldEdit.None) {
            Log.i(TAG, "buffered no commit preedit='${update.preedit}' field=${update.field}")
        }
        return true
    }

    /**
     * X chat with `inputContext=null` still binds an InputConnection, but it is
     * the process binding, not an editor. Commit-only mode then keeps the
     * syllable in the session and consumes the hardware key, so nothing appears.
     * The view inserts characters from the KeyEvent itself when the key is not
     * consumed. Try `commitText` and an ACTION_MULTIPLE key event first; if
     * neither lands, give the original key back.
     */
    private fun refreshEditorLink(reason: String) {
        val current = currentInputConnection
        val binding = currentInputBinding?.connection
        val started = lookupStartedConnection()
        val before = try {
            current?.getTextBeforeCursor(8, 0)
        } catch (error: Exception) {
            Log.i(TAG, "getTextBeforeCursor failed ${error.javaClass.simpleName}: ${error.message}")
            null
        }
        editorMissing = when {
            directInput -> false
            current == null -> true
            !startedLookupFailed -> started == null
            else -> editorConnectionMissing(current, binding)
        }
        Log.i(
            TAG,
            "link $reason ic=${current?.javaClass?.name ?: "null"} startedNull=${started == null} " +
                "lookupFailed=$startedLookupFailed bindingSame=${current === binding} " +
                "beforeNull=${before == null} beforeLen=${before?.length ?: -1} editorMissing=$editorMissing",
        )
    }

    private fun lookupStartedConnection(): InputConnection? {
        if (startedLookupFailed) return null
        return try {
            val field = InputMethodService::class.java.getDeclaredField("mStartedInputConnection")
            field.isAccessible = true
            field.get(this) as? InputConnection?
        } catch (error: Throwable) {
            startedLookupFailed = true
            Log.i(TAG, "mStartedInputConnection lookup failed ${error.javaClass.simpleName}: ${error.message}")
            null
        }
    }

    /**
     * @param undo pop the session key when the view did not accept it.
     * Backspace already is that pop; undoing it again would drop a second character.
     * @return true when the editor accepted the change and the hardware key must be consumed.
     */
    private fun editWithoutEditor(undo: Boolean = true, action: (FieldSession) -> SessionUpdate): Boolean {
        val active = session ?: return false
        val before = try {
            active.state().document
        } catch (error: Exception) {
            fail(error)
            return false
        }
        val update = try {
            action(active)
        } catch (error: Exception) {
            fail(error)
            return false
        }
        val next = try {
            active.state().document
        } catch (error: Exception) {
            fail(error)
            return false
        }
        val patch = textPatch(before, next)
        val changed = patch.delete > 0 || patch.insert.isNotEmpty()
        Log.i(
            TAG,
            "raw edit field=${update.field} preedit='${update.preedit}' delete=${patch.delete} insert='${patch.insert}'",
        )
        val accepted = changed && pushPatch(patch)
        if (!accepted) {
            Log.i(TAG, "raw edit not accepted; undo=$undo changed=$changed")
            if (undo && changed) {
                try {
                    updateMode(active.backspace().mode)
                } catch (error: Exception) {
                    Log.i(TAG, "undo after rejected delivery failed ${error.javaClass.simpleName}")
                }
            }
            return false
        }
        updateMode(update.mode)
        return true
    }

    private fun pushPatch(patch: TextPatch): Boolean {
        val ic = currentInputConnection
        if (ic == null) {
            Log.i(TAG, "deliver ic=null commit=false keyEvent=false")
            return false
        }
        val icName = ic.javaClass.name
        if (patch.delete > 0) {
            var deleted = true
            repeat(patch.delete) {
                val down = sendLoggedKey(ic, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL)
                val up = sendLoggedKey(ic, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL)
                if (!down && !up) deleted = false
            }
            Log.i(TAG, "sendKeyEvent DEL count=${patch.delete} accepted=$deleted ic=$icName")
            if (!deleted) return false
        }
        if (patch.insert.isEmpty()) return true
        val commit = ic.commitText(patch.insert, 1)
        val before = try {
            ic.getTextBeforeCursor(patch.insert.length.coerceAtLeast(1), 0)
        } catch (error: Exception) {
            Log.i(TAG, "getTextBeforeCursor after commit failed ${error.javaClass.simpleName}")
            null
        }
        val visible = before?.endsWith(patch.insert) == true
        Log.i(
            TAG,
            "commitText ok=$commit visible=$visible beforeNull=${before == null} text='${patch.insert}' ic=$icName",
        )
        if (deliveryAccepted(commit, visible, keyEvent = false)) return true
        val event = KeyEvent(
            android.os.SystemClock.uptimeMillis(),
            patch.insert,
            android.view.KeyCharacterMap.VIRTUAL_KEYBOARD,
            KeyEvent.FLAG_SOFT_KEYBOARD,
        )
        val sent = ic.sendKeyEvent(event)
        Log.i(
            TAG,
            "sendKeyEvent action=${event.action} keyCode=${event.keyCode} chars='${event.characters}' ok=$sent ic=$icName",
        )
        return deliveryAccepted(commit, visible, sent)
    }

    private fun sendLoggedKey(ic: InputConnection, action: Int, keyCode: Int): Boolean {
        val now = android.os.SystemClock.uptimeMillis()
        val ok = ic.sendKeyEvent(KeyEvent(now, now, action, keyCode, 0))
        Log.i(TAG, "sendKeyEvent action=$action keyCode=$keyCode ok=$ok ic=${ic.javaClass.name}")
        return ok
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        refreshEditorLink("onKeyDown")
        Log.i(
            TAG,
            "onKeyDown keyCode=$keyCode meta=0x${Integer.toHexString(event.metaState)} " +
                "repeat=${event.repeatCount} unicode=${event.unicodeChar} direct=$directInput commitOnly=$commitOnly " +
                "session=${session != null} editorMissing=$editorMissing",
        )
        ensureSession("onKeyDown")
        if (isShift(keyCode)) {
            heldShifts.add(keyCode)
            tracker.shiftChanged(true)
            return super.onKeyDown(keyCode, event)
        }
        tracker.shiftChanged(event.isShiftPressed || heldShifts.isNotEmpty())
        val toggle = tracker.keyDown(keyCode == KeyEvent.KEYCODE_SPACE, event.isShiftPressed)
        val active = session ?: run {
            if (!directInput && inputActive) Log.i(TAG, "onKeyDown pass-through; Korean session is not bound")
            return super.onKeyDown(keyCode, event)
        }
        val controlCharacter = HardwareKeys.controlCharacter(
            keyCode, event.isCtrlPressed,
            event.isShiftPressed, event.isAltPressed, event.isMetaPressed, event.isSymPressed,
        )
        if (controlCharacter != null) {
            val handled = if (editorMissing) {
                editWithoutEditor { it.input(controlCharacter.toString()) }
            } else {
                inputText(controlCharacter.toString())
            }
            if (handled) consumedKeys.add(keyCode)
            else Log.i(TAG, "onKeyDown did not commit control keyCode=$keyCode")
            return handled || super.onKeyDown(keyCode, event)
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
                if (editorMissing) {
                    val doc = try {
                        active.state().document
                    } catch (_: Exception) {
                        ""
                    }
                    if (doc.isEmpty() || !editWithoutEditor(undo = false) { it.backspace() }) {
                        Log.i(TAG, "onKeyDown DEL pass-through; no editor connection")
                        return super.onKeyDown(keyCode, event)
                    }
                    true
                } else {
                    val hidden = hiddenSyllable()
                    val update = runEdit { active.backspace() }
                    val kept = update != null && keptInBuffer(hidden, update)
                    if (kept) Log.i(TAG, "commitOnly backspace stayed inside the buffered syllable")
                    if (update?.field == FieldEdit.None && !kept) applier?.expectNativeBackspace()
                    kept || update == null || update.field != FieldEdit.None
                }
            }
            else -> {
                val character = HardwareKeys.character(keyCode, event.isShiftPressed)
                if (character != null) {
                    val accepted = if (editorMissing) {
                        editWithoutEditor { it.input(character.toString()) }
                    } else {
                        inputText(character.toString())
                    }
                    if (!accepted) {
                        Log.i(TAG, "onKeyDown pass-through keyCode=$keyCode editorMissing=$editorMissing")
                        return super.onKeyDown(keyCode, event)
                    }
                    true
                } else {
                    // Navigation, Enter, Tab, shortcuts and unknown keys end the open run.
                    // A view with no editor inserts those keys itself.
                    if (!editorMissing) runEdit { active.commitDisplayed(true) }
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
        Log.i(
            TAG,
            "onUpdateSelection old=$oldSelStart..$oldSelEnd new=$newSelStart..$newSelEnd " +
                "candidates=$candidatesStart..$candidatesEnd",
        )
        reportedStart = newSelStart
        reportedEnd = newSelEnd
        if (resettingField || rebinding) return
        val spanLive = candidatesStart >= 0 && candidatesEnd >= 0
        applier?.noteComposingSpan(spanLive)
        if (editing || session == null) return
        if (applier?.composingSpanStale() == true) {
            if (hostShowsSessionText() && applier?.expectsSelection(newSelStart, newSelEnd) == true) {
                adoptCommitFallback()
                applier?.acknowledgesSelection(newSelStart, newSelEnd)
                return
            }
            if (!hostShowsSessionText()) {
                restartAtReportedSelection()
                return
            }
        }
        if (applier?.acknowledgesSelection(newSelStart, newSelEnd) == true) return
        // An external cursor/selection move invalidates all relative edit spans. Keep the
        // editor's displayed text, then start an empty core session at the new position.
        restartAtReportedSelection()
    }

    private fun isShift(code: Int) = code == KeyEvent.KEYCODE_SHIFT_LEFT || code == KeyEvent.KEYCODE_SHIFT_RIGHT

    private fun readHardwareLayout(): LayoutKind = when (HardwareLayoutPreference.load(this)) {
        HardwareLayoutPreference.DUBEOL -> LayoutKind.DUBEOL
        HardwareLayoutPreference.SEBEOL_FINAL -> LayoutKind.SEBEOL_FINAL
        else -> LayoutKind.SEBEOL390
    }

    /** Commit the open word, then read later hardware keys with the saved layout. */
    private fun applyHardwareLayout() {
        val next = readHardwareLayout()
        if (next == hardwareLayout) return
        hardwareLayout = next
        val active = session ?: return
        runEdit { active.setLayout(next) }
    }

    companion object {
        private const val TAG = "Seto"
        private const val PREFS = HardwareLayoutPreference.PREFS
        private const val KEY_AUTO = "autoSwitch"
        private const val KEY_TYPOS = "correctsTypos"
    }
}
