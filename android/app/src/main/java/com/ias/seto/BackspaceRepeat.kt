package com.ias.seto

/**
 * Cadence of a held backspace, matching the iOS touch keyboard.
 *
 * One deletion happens on contact, outside this schedule. Then a 500 ms pause,
 * twenty character deletions every 100 ms, then a word wave every 350 ms.
 * The first wave is one character-interval after the last character.
 */
internal class BackspaceRepeat {
    enum class Action { Character, Word }

    private var pressing = false
    private var start = 0.0
    private var ticks = 0

    fun begin(at: Double) {
        pressing = true
        start = at
        ticks = 0
    }

    fun end() {
        pressing = false
    }

    fun nextDeadline(): Double? = if (pressing) time(ticks) else null

    fun dueActions(at: Double): List<Action> {
        if (!pressing) return emptyList()
        val actions = mutableListOf<Action>()
        var steps = 0
        while (steps < 10_000) {
            val deadline = nextDeadline() ?: break
            if (deadline > at) break
            actions += if (ticks < CHARACTER_REPEAT_COUNT) Action.Character else Action.Word
            ticks += 1
            steps += 1
        }
        return actions
    }

    private fun time(tick: Int): Double {
        if (tick < CHARACTER_REPEAT_COUNT) {
            return start + INITIAL_DELAY + tick * CHARACTER_INTERVAL
        }
        val wordIndex = tick - CHARACTER_REPEAT_COUNT
        val wordStart = start + INITIAL_DELAY + CHARACTER_REPEAT_COUNT * CHARACTER_INTERVAL
        return wordStart + wordIndex * WORD_INTERVAL
    }

    companion object {
        const val INITIAL_DELAY = 0.5
        const val CHARACTER_INTERVAL = 0.1
        const val CHARACTER_REPEAT_COUNT = 20
        const val WORD_INTERVAL = 0.35
        const val WORDS_PER_TICK = 2
    }
}
