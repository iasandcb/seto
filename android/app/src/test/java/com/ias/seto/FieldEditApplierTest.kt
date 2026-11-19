package com.ias.seto

import android.view.inputmethod.InputConnection
import com.ias.seto.core.FieldEdit
import com.ias.seto.core.Language
import com.ias.seto.core.SessionUpdate
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

/** A synchronous editor model whose String indices are UTF-16, like Android's Editable. */
class FieldEditApplierTest {
    private class Editor(initial: String) {
        var text = initial
        var cursor = initial.length
        var markStart: Int? = null
        var markEnd: Int? = null
        val calls = mutableListOf<String>()
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java)) { _, method, args ->
            calls.add(method.name)
            when (method.name) {
                "beginBatchEdit", "endBatchEdit" -> true
                "finishComposingText" -> { markStart = null; markEnd = null; true }
                "commitText", "setComposingText" -> {
                    val value = args!![0].toString()
                    val start = markStart ?: cursor
                    val end = markEnd ?: cursor
                    text = text.replaceRange(start, end, value)
                    cursor = start + value.length
                    if (method.name == "setComposingText" && value.isNotEmpty()) {
                        markStart = start; markEnd = cursor
                    } else { markStart = null; markEnd = null }
                    true
                }
                "deleteSurroundingText" -> {
                    // Like BaseInputConnection: exclude an active composing range.
                    val end = markStart ?: cursor
                    val count = args!![0] as Int
                    text = text.removeRange(end - count, end)
                    cursor -= count
                    true
                }
                else -> error("Unexpected call: ${method.name}")
            }
        } as InputConnection
    }
    @Test fun everyEditMatchesCoreSpanSemanticsIncludingSurrogates() {
        data class Case(val field: FieldEdit, val preedit: String, val result: String)
        val cases = listOf(
            Case(FieldEdit.None, "가", "x𝄞가"),
            Case(FieldEdit.Unmark("가"), "", "x𝄞가"),
            Case(FieldEdit.Insert("ab"), "", "x𝄞ab"),
            Case(FieldEdit.Mark("나"), "나", "x𝄞나"),
            Case(FieldEdit.ReplaceBeforeCaret(3u, "나"), "나", "x나"),
            Case(FieldEdit.InsertThenMark("ab", "나"), "나", "x𝄞ab나"),
            Case(FieldEdit.InsertReplacing(3u, "ab"), "", "xab"),
            Case(FieldEdit.InsertReplacingThenMark(3u, "ab", "나"), "나", "xab나"),
            Case(FieldEdit.ClearMarkThenInsert(2u, "ab"), "", "xab"),
            Case(FieldEdit.ClearMarkThenMark(2u, "나"), "나", "x나"),
            Case(FieldEdit.Rewrite(3u, "ab", "나"), "나", "xab나"),
            Case(FieldEdit.Rewrite(3u, "", "나"), "나", "x나"),
            Case(FieldEdit.Mark(""), "", "x𝄞"),
        )
        for (case in cases) {
            val editor = Editor("x𝄞")
            val adapter = FieldEditApplier(editor.connection, editor.cursor, editor.cursor)
            adapter.apply(SessionUpdate(Language.KOREAN, false, "가", FieldEdit.Mark("가")))
            adapter.apply(SessionUpdate(Language.KOREAN, false, case.preedit, case.field))
            assertEquals(case.field.toString(), case.result, editor.text)
            assertEquals(case.preedit.length, adapter.preeditLength)
            assertEquals(if (case.preedit.isEmpty()) null else editor.cursor - case.preedit.length, editor.markStart)
            assertTrue(adapter.acknowledgesSelection(editor.cursor, editor.cursor))
            assertEquals("endBatchEdit", editor.calls.last())
        }
    }
    @Test fun nativeBackspaceKeepsTheOpenLatinTokenAligned() {
        val editor = Editor("ab")
        val adapter = FieldEditApplier(editor.connection, 2, 2)
        adapter.apply(SessionUpdate(Language.ENGLISH, false, "", FieldEdit.None))
        adapter.expectNativeBackspace()
        editor.connection.deleteSurroundingText(1, 0)
        assertTrue(adapter.acknowledgesSelection(1, 1))
        adapter.apply(SessionUpdate(Language.ENGLISH, false, "", FieldEdit.Insert("c")))
        assertEquals("ac", editor.text)
        assertTrue(adapter.acknowledgesSelection(2, 2))
    }
    @Test fun coalescedUpdatesAndExternalCursorMoves() {
        val editor = Editor("")
        val adapter = FieldEditApplier(editor.connection, 0, 0)
        for (text in listOf("a", "b", "𝄞")) {
            adapter.apply(SessionUpdate(Language.ENGLISH, false, "", FieldEdit.Insert(text)))
        }
        assertTrue(adapter.acknowledgesSelection(4, 4))
        assertFalse(adapter.acknowledgesSelection(1, 1))
        assertFalse(adapter.acknowledgesSelection(0, 4))
    }
}
