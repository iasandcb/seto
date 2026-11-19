package com.ias.seto

import android.view.inputmethod.EditorInfo
import android.text.InputType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SoftLayoutTest {
    private val korean = SoftLayout.State(korean = true)
    private val english = SoftLayout.State(korean = false)
    private fun letter(base: Char) = SoftLayout.Key(SoftLayout.Kind.Letter, base)
    private fun number(base: Char) = SoftLayout.Key(SoftLayout.Kind.Number, base)

    @Test fun rowsFollowTheIosShapeAndKeep390Choseong() {
        assertEquals("1234567890", SoftLayout.numberRow.joinToString("") { it.base.toString() })
        assertEquals("qwertyuiop", SoftLayout.topRow.joinToString("") { it.base.toString() })
        assertEquals("asdfghjkl;'", SoftLayout.homeRow.joinToString("") { it.base.toString() })
        assertEquals("zxcvbnm", SoftLayout.bottomLetters.joinToString("") { it.base.toString() })
        assertEquals(
            listOf(
                SoftLayout.Kind.Globe, SoftLayout.Kind.Symbol, SoftLayout.Kind.Language,
                SoftLayout.Kind.Hyphen, SoftLayout.Kind.Space, SoftLayout.Kind.Period,
                SoftLayout.Kind.Question, SoftLayout.Kind.Return,
            ),
            SoftLayout.bottomRow.map { it.kind },
        )
    }

    @Test fun letterCapsStack390AndQwertyWithTheActiveModeFirst() {
        val q = letter('q')
        assertEquals("ㅅ\nq", SoftLayout.face(q, korean).text)
        assertEquals("q\nㅅ", SoftLayout.face(q, english).text)
        assertEquals("ㅍ\nQ", SoftLayout.face(q, korean.copy(shifted = true)).text)
        assertEquals("Q\nㅍ", SoftLayout.face(q, english.copy(shifted = true)).text)
        assertEquals("한글 ㅅ, 영문 q, 현재 ㅅ", SoftLayout.face(q, korean).label)
        assertEquals(SoftLayout.Effect.Compose('q'), SoftLayout.tap(q, korean))
        assertEquals(SoftLayout.Effect.Compose('Q'), SoftLayout.tap(q, korean.copy(shifted = true)))
        assertEquals(SoftLayout.Effect.Compose('Q'), SoftLayout.longPress(q, korean))
        assertEquals(SoftLayout.Effect.Literal("Q"), SoftLayout.longPress(q, english.copy(direct = true)))
    }

    @Test fun numberRowIs390InKoreanAndDigitsInEnglish() {
        val one = number('1')
        val four = number('4')
        assertEquals("ㅎ\n1", SoftLayout.face(one, korean).text)
        assertEquals("1 !", SoftLayout.face(one, english).text)
        assertEquals("ㅈ\n1", SoftLayout.face(one, korean.copy(shifted = true)).text)
        assertEquals(SoftLayout.Effect.Compose('1'), SoftLayout.tap(one, korean))
        assertEquals(SoftLayout.Effect.Compose('!'), SoftLayout.tap(one, korean.copy(shifted = true)))
        assertEquals(SoftLayout.Effect.Literal("1"), SoftLayout.longPress(one, korean))
        assertEquals(SoftLayout.Effect.Compose('4'), SoftLayout.tap(four, english))
        assertEquals(SoftLayout.Effect.Compose('$'), SoftLayout.longPress(four, english))
        assertEquals("1 !", SoftLayout.face(one, korean.copy(symbols = true)).text)
        assertEquals(SoftLayout.Effect.Literal("!"), SoftLayout.longPress(one, korean.copy(symbols = true)))
    }

    @Test fun symbolLayerMatchesTheIosMapAndDoesNotCompose() {
        val expected = mapOf(
            'q' to '-', 'w' to '/', 'e' to ':', 'r' to ';', 't' to '(',
            'y' to ')', 'u' to '₩', 'i' to '&', 'o' to '@', 'p' to '~',
            'a' to ',', 's' to '+', 'd' to '!', 'f' to '\'', 'g' to '"',
            'h' to '[', 'j' to ']', 'k' to '{', 'l' to '}', ';' to '+',
            'z' to '=', 'x' to '_', 'c' to '*', 'v' to '%', 'b' to '<',
            'n' to '>', 'm' to '\\',
        )
        val symbols = korean.copy(symbols = true)
        expected.forEach { (base, glyph) ->
            assertEquals(glyph, SoftLayout.symbolFor(base))
            val key = letter(base)
            assertEquals(glyph.toString(), SoftLayout.face(key, symbols).text)
            assertEquals(SoftLayout.Effect.Literal(glyph.toString()), SoftLayout.tap(key, symbols))
            assertNull(SoftLayout.longPress(key, symbols))
        }
    }

    @Test fun referenceMarkHoldAndBottomKeys() {
        val mark = SoftLayout.Key(SoftLayout.Kind.Symbol)
        val language = SoftLayout.Key(SoftLayout.Kind.Language)
        val hyphen = SoftLayout.Key(SoftLayout.Kind.Hyphen)
        val space = SoftLayout.Key(SoftLayout.Kind.Space)
        val period = SoftLayout.Key(SoftLayout.Kind.Period)
        val question = SoftLayout.Key(SoftLayout.Kind.Question)
        assertEquals(SoftLayout.Effect.ToggleSymbols, SoftLayout.tap(mark, korean))
        assertEquals(SoftLayout.Effect.ConvertWord, SoftLayout.longPress(mark, korean))
        assertEquals(SoftLayout.Effect.ToggleLanguage, SoftLayout.tap(language, korean))
        assertEquals(SoftLayout.Effect.ToggleAutoSwitch, SoftLayout.longPress(language, korean))
        assertEquals(SoftLayout.Effect.Compose('-'), SoftLayout.tap(hyphen, korean))
        assertEquals(SoftLayout.Effect.Compose('→'), SoftLayout.longPress(hyphen, korean))
        assertEquals(SoftLayout.Effect.Compose(' '), SoftLayout.tap(space, korean))
        assertEquals(SoftLayout.Effect.Compose('\t'), SoftLayout.longPress(space, korean))
        assertEquals(SoftLayout.Effect.Compose('.'), SoftLayout.tap(period, korean))
        assertEquals(SoftLayout.Effect.Compose(','), SoftLayout.longPress(period, korean))
        assertEquals(SoftLayout.Effect.Literal("!"), SoftLayout.longPress(question, korean))
        assertTrue(SoftLayout.face(mark, korean.copy(symbols = true)).latched)
        assertTrue(SoftLayout.face(SoftLayout.Key(SoftLayout.Kind.Shift), korean.copy(shifted = true)).latched)
    }

    @Test fun shiftClearsAfterACharacterAndNotAfterTheSymbolLayer() {
        val shifted = SoftLayout.reduce(korean, SoftLayout.Effect.Shift)
        assertTrue(shifted.shifted)
        assertFalse(SoftLayout.reduce(shifted, SoftLayout.Effect.Compose('q')).shifted)
        assertFalse(SoftLayout.reduce(shifted, SoftLayout.Effect.Literal("1")).shifted)
        val symbols = SoftLayout.reduce(shifted, SoftLayout.Effect.ToggleSymbols)
        assertTrue(symbols.shifted)
        assertTrue(symbols.symbols)
    }

    @Test fun directFieldsTypeTheVisibleLatinCharacter() {
        val direct = korean.copy(direct = true)
        assertEquals("q\nㅅ", SoftLayout.face(letter('q'), direct).text)
        assertEquals(SoftLayout.Effect.Literal("q"), SoftLayout.tap(letter('q'), direct))
        assertEquals(SoftLayout.Effect.Literal("1"), SoftLayout.tap(number('1'), direct))
        assertEquals("1 !", SoftLayout.face(number('1'), direct).text)
    }

    @Test fun hardware390Labels() {
        val expected = mapOf(
            '1' to "ㅎ", '2' to "ㅆ", '3' to "ㅂ", '4' to "ㅛ", '5' to "ㅠ",
            '6' to "ㅑ", '7' to "ㅖ", '8' to "ㅢ", '9' to "ㅜ", '0' to "ㅋ",
            'q' to "ㅅ", 'w' to "ㄹ", 'e' to "ㅕ", 'r' to "ㅐ", 't' to "ㅓ",
            'y' to "ㄹ", 'u' to "ㄷ", 'i' to "ㅁ", 'o' to "ㅊ", 'p' to "ㅍ",
            'a' to "ㅇ", 's' to "ㄴ", 'd' to "ㅣ", 'f' to "ㅏ", 'g' to "ㅡ",
            'h' to "ㄴ", 'j' to "ㅇ", 'k' to "ㄱ", 'l' to "ㅈ", ';' to "ㅂ", '\'' to "ㅌ",
            'z' to "ㅁ", 'x' to "ㄱ", 'c' to "ㅔ", 'v' to "ㅗ", 'b' to "ㅜ",
            'n' to "ㅅ", 'm' to "ㅎ", '/' to "ㅗ",
            '!' to "ㅈ", 'Q' to "ㅍ", 'W' to "ㅌ", 'E' to "ㅋ", 'R' to "ㅒ",
            'T' to ";", 'Y' to "<", 'U' to "7", 'I' to "8", 'O' to "9", 'P' to ">",
            'A' to "ㄷ", 'S' to "ㄶ", 'D' to "ㄺ", 'F' to "ㄲ", 'G' to "/", 'H' to "'",
            'J' to "4", 'K' to "5", 'L' to "6",
            'Z' to "ㅊ", 'X' to "ㅄ", 'C' to "ㄻ", 'V' to "ㅀ", 'B' to "!",
            'N' to "0", 'M' to "1", '<' to "2", '>' to "3",
            ',' to ",", '.' to ".", ' ' to " ",
        )
        expected.forEach { (key, label) ->
            assertEquals(key.toString(), label, SoftLayout.koreanLabel(key))
        }
    }

    @Test fun qwertyShiftMatchesHardwarePairs() {
        assertEquals(')', SoftLayout.qwertyShift('0'))
        assertEquals('!', SoftLayout.qwertyShift('1'))
        assertEquals('@', SoftLayout.qwertyShift('2'))
        assertEquals('(', SoftLayout.qwertyShift('9'))
        assertEquals('A', SoftLayout.qwertyShift('a'))
        assertEquals(':', SoftLayout.qwertyShift(';'))
        assertEquals('"', SoftLayout.qwertyShift('\''))
        assertEquals('<', SoftLayout.qwertyShift(','))
        assertEquals('>', SoftLayout.qwertyShift('.'))
        assertEquals('?', SoftLayout.qwertyShift('/'))
        assertEquals('~', SoftLayout.qwertyShift('`'))
    }
}

class BackspaceRepeatTest {
    @Test fun cadenceMatchesTheSystemKeyboard() {
        val repeat = BackspaceRepeat()
        repeat.begin(0.0)
        assertEquals(0.5, repeat.nextDeadline()!!, 0.0001)
        assertTrue(repeat.dueActions(0.49).isEmpty())
        assertEquals(listOf(BackspaceRepeat.Action.Character), repeat.dueActions(0.5))
        val allCharacters = repeat.dueActions(0.5 + 19 * 0.1)
        assertEquals(19, allCharacters.size)
        assertTrue(allCharacters.all { it == BackspaceRepeat.Action.Character })
        val firstWord = repeat.dueActions(2.5)
        assertEquals(listOf(BackspaceRepeat.Action.Word), firstWord)
        val later = repeat.dueActions(2.5 + 0.35)
        assertEquals(listOf(BackspaceRepeat.Action.Word), later)
        repeat.end()
        assertNull(repeat.nextDeadline())
        assertTrue(repeat.dueActions(10.0).isEmpty())
    }
}

class WordDeletionTest {
    @Test fun twoWordsAndAHyphenBoundary() {
        // A trailing space stays with the word before it, so the wave is "b c".
        assertEquals(listOf("c", "b "), WordDeletion.units("a b c", 2))
        assertEquals("b c", WordDeletion.units("a b c", 2).asReversed().joinToString(""))
        assertEquals(listOf("known", "well-"), WordDeletion.units("well-known", 2))
        assertEquals("well-known", WordDeletion.units("well-known", 2).asReversed().joinToString(""))
        assertEquals(listOf("hi "), WordDeletion.units("hi ", 2))
    }

    @Test fun openSyllableAndSelectionStaySingle() {
        assertTrue(WordDeletion.plan("안녕", "안녕", composing = true, selection = false).single)
        assertTrue(WordDeletion.plan("안녕", "안녕", composing = false, selection = true).single)
        assertTrue(WordDeletion.plan(null, "", composing = false, selection = false).single)
    }

    @Test fun sessionOwnedSuffixIsBackspacedBeforeTheHostRemainder() {
        val plan = WordDeletion.plan("hello world", "world", composing = false, selection = false)
        assertFalse(plan.single)
        assertEquals("hello world", plan.suffix)
        assertEquals(5, plan.sessionBackspaces)
        assertEquals("hello ", WordDeletion.hostRemainder(plan.suffix, 5, "world", "", ""))
        assertNull(WordDeletion.hostRemainder(plan.suffix, 5, "world", "wor", ""))
        assertNull(WordDeletion.hostRemainder("hello", 0, "", "", "가"))
    }

    @Test fun textOutsideTheSessionIsDeletedFromTheHost() {
        val plan = WordDeletion.plan("hello", "", composing = false, selection = false)
        assertEquals(0, plan.sessionBackspaces)
        assertEquals("hello", WordDeletion.hostRemainder(plan.suffix, 0, "", "", ""))
    }
}

class TextFitTest {
    @Test fun shrinksUntilEveryLineFitsAndNeverGrowsPastTheMax() {
        fun width(size: Float, line: String) = size * line.length
        fun height(size: Float) = size
        val fitted = fittedTextSizePx(listOf("한글", "qw"), 20f, 40f, 18f, 8f, ::width, ::height)
        assertEquals(10f, fitted, 0.01f)
        val already = fittedTextSizePx(listOf("a"), 100f, 100f, 18f, 8f, ::width, ::height)
        assertEquals(18f, already, 0.01f)
        val tiny = fittedTextSizePx(listOf("너무김"), 1f, 1f, 18f, 8f, ::width, ::height)
        assertEquals(8f, tiny, 0.01f)
    }
}

class KeyboardPolicyTest {
    @Test fun hardwareKeyboardHidesTheSoftKeyboardUntilItIsClosed() {
        assertTrue(showSoftKeyboard(KEYBOARD_NOKEYS, HARDKEYBOARDHIDDEN_NO))
        assertFalse(showSoftKeyboard(KEYBOARD_QWERTY, HARDKEYBOARDHIDDEN_NO))
        assertTrue(showSoftKeyboard(KEYBOARD_QWERTY, HARDKEYBOARDHIDDEN_YES))
    }

    @Test fun modeToastIsASingleGlyph() {
        assertEquals("한", modeToast(true))
        assertEquals("A", modeToast(false))
    }

    @Test fun returnLabelFollowsTheEditorAction() {
        val search = EditorInfo()
        search.imeOptions = EditorInfo.IME_ACTION_SEARCH
        search.inputType = InputType.TYPE_CLASS_TEXT
        assertEquals("검색", returnLabel(search))
        val multiline = EditorInfo()
        multiline.imeOptions = EditorInfo.IME_ACTION_SEARCH
        multiline.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        assertEquals("↵", returnLabel(multiline))
    }
}
