package com.ias.seto

import android.view.inputmethod.InputConnection
import com.ias.seto.core.FieldEdit
import com.ias.seto.core.SessionUpdate

/** Kotlin String.length and deleteSurroundingText both count UTF-16 code units. */
internal class FieldEditApplier(
    private val connection: InputConnection,
    initialStart: Int,
    initialEnd: Int,
) {
    private var cursor = initialStart
    private var selectionEnd = initialEnd
    private val expectedSelections = mutableListOf(initialStart to initialEnd)
    /** Host cannot keep a composing span. Marks are committed text. */
    var commitOnly = false
    /** The last edit wrote with commitText because setComposingText was rejected or the span was already gone. */
    var fellBackToCommit = false
    private var composingSpanLive = false
    private var spanEpoch = 0
    /** Liveness at the start of this edit. `finish` inside the edit must not look like the host dropped the span. */
    private var spanAtEditStart = false

    /** The host reported whether a composing span exists. Called even while an edit is in flight. */
    fun noteComposingSpan(live: Boolean) {
        spanEpoch += 1
        composingSpanLive = live
    }

    /** Preedit was folded into committed text. Further edits replace that text. */
    fun noteComposingFolded() {
        commitOnly = true
        preeditLength = 0
        composingSpanLive = false
        fellBackToCommit = false
    }

    /** A syllable is on screen but the composing span is gone, so the next mark would insert beside it. */
    fun composingSpanStale(): Boolean = preeditLength > 0 && !composingSpanLive

    fun expectsSelection(start: Int, end: Int): Boolean {
        if (expectedSelections.any { it.first == start && it.second == end }) return true
        return start == cursor && end == selectionEnd
    }

    /** Editors may coalesce selection callbacks for multiple batches. */
    fun acknowledgesSelection(start: Int, end: Int): Boolean {
        val index = expectedSelections.indexOfLast { it.first == start && it.second == end }
        if (index >= 0) {
            repeat(index + 1) { expectedSelections.removeAt(0) }
            return true
        }
        return start == cursor && end == selectionEnd
    }
    val cursorPosition: Int get() = cursor
    val hasSelection: Boolean get() = cursor != selectionEnd

    /** Core returns None when Android should perform its normal backspace. Open Latin
     * tokens delete one UTF-16 unit. A wider native deletion triggers a safe session reset. */
    fun expectNativeBackspace() = expectNativeDeletion(1)

    fun expectNativeDeletion(utf16: Int) {
        cursor = if (cursor != selectionEnd) minOf(cursor, selectionEnd) else maxOf(0, cursor - utf16)
        selectionEnd = cursor
        expectedSelections.add(cursor to cursor)
    }

    /** A character inserted outside the session, such as a symbol-layer literal. */
    fun expectInsertion(utf16: Int) {
        cursor += utf16
        selectionEnd = cursor
        expectedSelections.add(cursor to cursor)
    }
    private fun advance(edit: FieldEdit) {
        if (edit == FieldEdit.None || edit is FieldEdit.Unmark) return
        val selected = kotlin.math.abs(selectionEnd - cursor)
        val insertionStart = minOf(cursor, selectionEnd)
        val markedStart = cursor - preeditLength
        fun insert(text: String) {
            cursor = (if (preeditLength > 0) markedStart else insertionStart) + text.length
        }
        when (edit) {
            FieldEdit.None, is FieldEdit.Unmark -> Unit
            is FieldEdit.Insert -> insert(edit.text)
            is FieldEdit.Mark -> insert(edit.text)
            is FieldEdit.ReplaceBeforeCaret -> cursor += edit.text.length - span(edit.utf16) - selected
            is FieldEdit.InsertThenMark -> { insert(edit.insert); cursor += edit.mark.length }
            is FieldEdit.InsertReplacing -> cursor += edit.text.length - span(edit.utf16) - selected
            is FieldEdit.InsertReplacingThenMark -> cursor += edit.insert.length + edit.mark.length - span(edit.utf16) - selected
            is FieldEdit.ClearMarkThenInsert -> cursor += edit.text.length - span(edit.utf16) - preeditLength - selected
            is FieldEdit.ClearMarkThenMark -> cursor += edit.text.length - span(edit.utf16) - preeditLength - selected
            is FieldEdit.Rewrite -> cursor += edit.text.length + edit.thenMark.length - span(edit.utf16) - selected
        }
        selectionEnd = cursor
        expectedSelections.add(cursor to cursor)
        // Bound storage for editors that never send selection notifications.
        if (expectedSelections.size > 128) expectedSelections.removeAt(0)
    }
    var preeditLength = 0
        private set
    private fun checked(ok: Boolean) { check(ok) { "Editor rejected Seto edit" } }
    private fun span(value: ULong): Int {
        require(value <= Int.MAX_VALUE.toULong()) { "Edit span exceeds Android range" }
        return value.toInt()
    }
    private fun commit(text: String) { checked(connection.commitText(text, 1)) }
    /**
     * Prefer a composing span. If the host has none, or rejects setComposingText,
     * commit the syllable over the previous committed preedit.
     */
    private fun mark(text: String) {
        if (commitOnly || (!spanAtEditStart && preeditLength > 0)) {
            commitOnly = true
            fellBackToCommit = true
            finish()
            delete(preeditLength)
            commit(text)
            composingSpanLive = false
            return
        }
        val epoch = spanEpoch
        if (connection.setComposingText(text, 1)) {
            if (spanEpoch == epoch) composingSpanLive = true
            return
        }
        commitOnly = true
        fellBackToCommit = true
        composingSpanLive = false
        // A live span is replaced by commitText. With no span this inserts.
        commit(text)
    }
    private fun finish() {
        val ok = connection.finishComposingText()
        composingSpanLive = false
        // A commit-only field may not implement composing at all. Deleting and
        // committing still has to proceed, or the session is dropped and later
        // hardware keys fall through as English.
        if (!commitOnly) checked(ok)
    }
    private fun delete(count: Int) {
        if (count > 0) checked(connection.deleteSurroundingText(count, 0))
    }
    private fun replace(count: Int, text: String, composing: Boolean) {
        // finish first: Android deletion otherwise excludes the composing region.
        finish()
        delete(count)
        if (!composing || commitOnly) {
            composingSpanLive = false
            commit(text)
            return
        }
        val epoch = spanEpoch
        if (connection.setComposingText(text, 1)) {
            if (spanEpoch == epoch) composingSpanLive = true
            return
        }
        commitOnly = true
        fellBackToCommit = true
        composingSpanLive = false
        commit(text)
    }
    fun apply(update: SessionUpdate) {
        spanAtEditStart = composingSpanLive
        connection.beginBatchEdit()
        try {
            when (val edit = update.field) {
                FieldEdit.None -> Unit
                is FieldEdit.Unmark -> finish()
                is FieldEdit.Insert -> commit(edit.text)
                is FieldEdit.Mark -> mark(edit.text)
                is FieldEdit.ReplaceBeforeCaret -> replace(span(edit.utf16), edit.text, true)
                is FieldEdit.InsertThenMark -> { commit(edit.insert); mark(edit.mark) }
                is FieldEdit.InsertReplacing -> replace(span(edit.utf16), edit.text, false)
                is FieldEdit.InsertReplacingThenMark -> {
                    replace(span(edit.utf16), edit.insert, false); mark(edit.mark)
                }
                is FieldEdit.ClearMarkThenInsert -> {
                    mark(""); finish(); delete(span(edit.utf16)); commit(edit.text)
                }
                is FieldEdit.ClearMarkThenMark -> {
                    mark(""); finish(); delete(span(edit.utf16)); mark(edit.text)
                }
                is FieldEdit.Rewrite -> {
                    replace(span(edit.utf16), edit.text, false)
                    if (edit.thenMark.isNotEmpty()) mark(edit.thenMark)
                }
            }
            advance(update.field)
            preeditLength = update.preedit.length
        } finally { connection.endBatchEdit() }
    }
}
