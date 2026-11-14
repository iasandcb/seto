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

    /** Editors may coalesce selection callbacks for multiple batches. */
    fun acknowledgesSelection(start: Int, end: Int): Boolean {
        val index = expectedSelections.indexOfLast { it.first == start && it.second == end }
        if (index >= 0) {
            repeat(index + 1) { expectedSelections.removeAt(0) }
            return true
        }
        return start == cursor && end == selectionEnd
    }
    /** Core returns None when Android should perform its normal backspace. Open Latin
     * tokens delete one UTF-16 unit. A wider native deletion triggers a safe session reset. */
    fun expectNativeBackspace() {
        cursor = if (cursor != selectionEnd) minOf(cursor, selectionEnd) else maxOf(0, cursor - 1)
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
    private fun mark(text: String) { checked(connection.setComposingText(text, 1)) }
    private fun finish() { checked(connection.finishComposingText()) }
    private fun delete(count: Int) {
        if (count > 0) checked(connection.deleteSurroundingText(count, 0))
    }
    private fun replace(count: Int, text: String, composing: Boolean) {
        // finish first: Android deletion otherwise excludes the composing region.
        finish()
        delete(count)
        if (composing) mark(text) else commit(text)
    }
    fun apply(update: SessionUpdate) {
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
