package com.ias.seto

import java.text.BreakIterator
import java.util.Locale

/**
 * Backward word-units, matching the system keyboard's held-delete waves.
 * A unit is the trailing whitespace run plus the word before it. Inside a word
 * it is just that word. Hyphens are boundaries and are deleted with the word
 * they follow.
 */
internal object WordDeletion {
    data class Plan(
        val single: Boolean,
        val sessionBackspaces: Int = 0,
        /** Grapheme suffix the session and the editor are expected to remove together. */
        val suffix: String = "",
    ) {
        companion object {
            val one = Plan(single = true)
        }
    }

    fun plan(
        contextBefore: String?,
        sessionDocument: String,
        composing: Boolean,
        selection: Boolean,
    ): Plan {
        if (composing || selection || contextBefore == null) return Plan.one
        val pieces = units(contextBefore, BackspaceRepeat.WORDS_PER_TICK)
        if (pieces.isEmpty()) return Plan.one
        val suffix = pieces.asReversed().joinToString("")
        if (!contextBefore.endsWith(suffix)) return Plan.one
        val shared = sharedSuffix(sessionDocument, suffix)
        if (sessionDocument.isNotEmpty() && shared.isEmpty()) return Plan.one
        return Plan(single = false, sessionBackspaces = graphemes(shared).size, suffix = suffix)
    }

    /**
     * Text still to delete from the editor after the session backspaces.
     * Null when the wave should stop: an open syllable, a session that did not
     * shrink, or a session that still owns a prefix of the suffix.
     */
    fun hostRemainder(
        suffix: String,
        sessionBackspacesPlanned: Int,
        documentBefore: String,
        documentAfter: String,
        preeditAfter: String,
    ): String? {
        if (preeditAfter.isNotEmpty()) return null
        val removed = (graphemes(documentBefore).size - graphemes(documentAfter).size).coerceAtLeast(0)
        if (sessionBackspacesPlanned > 0 && removed <= 0) return null
        // The session eats the end of the wave. The editor deletes whatever is left in front.
        val graphs = graphemes(suffix)
        val host = graphs.take((graphs.size - removed).coerceAtLeast(0)).joinToString("")
        if (host.isEmpty() || documentAfter.isNotEmpty()) return null
        return host
    }

    fun units(text: String, count: Int): List<String> {
        val characters = graphemes(text).toMutableList()
        val result = mutableListOf<String>()
        repeat(count) {
            val piece = unit(characters)
            if (piece.isEmpty()) return result
            result += piece
            repeat(graphemes(piece).size) { if (characters.isNotEmpty()) characters.removeAt(characters.lastIndex) }
        }
        return result
    }

    private fun unit(characters: List<String>): String {
        if (characters.isEmpty()) return ""
        var index = characters.size
        if (isWhitespace(characters[index - 1])) {
            while (index > 0 && isWhitespace(characters[index - 1])) index -= 1
        }
        if (index > 0 && isHyphen(characters[index - 1])) {
            while (index > 0 && isHyphen(characters[index - 1])) index -= 1
        }
        while (index > 0 && isWordBody(characters[index - 1])) index -= 1
        return characters.subList(index, characters.size).joinToString("")
    }

    private fun sharedSuffix(text: String, suffix: String): String {
        val left = graphemes(text)
        val right = graphemes(suffix)
        var count = 0
        while (count < left.size && count < right.size &&
            left[left.size - 1 - count] == right[right.size - 1 - count]
        ) {
            count += 1
        }
        return right.takeLast(count).joinToString("")
    }

    fun graphemes(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        iterator.setText(text)
        val out = mutableListOf<String>()
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            out += text.substring(start, end)
            start = end
            end = iterator.next()
        }
        return out
    }

    private fun isWhitespace(grapheme: String) = grapheme.all { it.isWhitespace() }

    private fun isHyphen(grapheme: String) = grapheme.length == 1 && grapheme[0] in HYPHENS

    private fun isWordBody(grapheme: String) = !isWhitespace(grapheme) && !isHyphen(grapheme)

    private val HYPHENS = setOf('-', '‐', '‑', '–', '—')
}
