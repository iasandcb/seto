package com.ias.seto

/**
 * On-screen Sebeolsik 390 / QWERTY board.
 *
 * Row structure, number row, symbol layer, and the ※ / hyphen holds follow the
 * iOS touch keyboard. Korean caps are 390, not two-set: the Rust session still
 * receives the QWERTY character and does the composition. The home row also
 * has `;` and `'` because those physical keys are choseong ㅂ and ㅌ.
 */
internal object SoftLayout {
    enum class Kind {
        Letter, Number, Shift, Backspace, Symbol, Language, Hyphen, Space, Period, Question, Return, Globe,
    }

    data class Key(val kind: Kind, val base: Char? = null)

    data class Face(val text: String, val label: String, val special: Boolean, val latched: Boolean = false)

    sealed class Effect {
        data class Compose(val character: Char) : Effect()
        data class Literal(val text: String) : Effect()
        data object Backspace : Effect()
        data object DeleteWord : Effect()
        data object Shift : Effect()
        data object ToggleSymbols : Effect()
        data object ConvertWord : Effect()
        data object ToggleLanguage : Effect()
        data object ToggleAutoSwitch : Effect()
        data object ReturnKey : Effect()
        data object NextKeyboard : Effect()
        data object PickKeyboard : Effect()
    }

    data class State(
        val korean: Boolean = true,
        val shifted: Boolean = false,
        val symbols: Boolean = false,
        val direct: Boolean = false,
    )

    val numberRow = "1234567890".map { Key(Kind.Number, it) }
    val topRow = "qwertyuiop".map { Key(Kind.Letter, it) }
    /** 11 keys: ㅂ and ㅌ have no other unshifted 390 position. */
    val homeRow = "asdfghjkl;'".map { Key(Kind.Letter, it) }
    val bottomLetters = "zxcvbnm".map { Key(Kind.Letter, it) }
    val bottomRow = listOf(
        Key(Kind.Globe),
        Key(Kind.Symbol),
        Key(Kind.Language),
        Key(Kind.Hyphen),
        Key(Kind.Space),
        Key(Kind.Period),
        Key(Kind.Question),
        Key(Kind.Return),
    )

    fun face(key: Key, state: State, returnLabel: String = "↵"): Face {
        val special = key.kind in SPECIAL
        return when (key.kind) {
            Kind.Letter -> letterFace(key.base!!, state, special)
            Kind.Number -> numberFace(key.base!!, state)
            Kind.Shift -> Face("⇧", "시프트", special = true, latched = state.shifted)
            Kind.Backspace -> Face("⌫", "삭제", special = true)
            Kind.Symbol -> Face("※", "기호 자판 전환", special = true, latched = state.symbols)
            Kind.Language -> Face("↔", "한영 전환 및 자동 변환 되돌리기", special = true)
            Kind.Hyphen -> Face("-", "하이픈 입력", special = false)
            Kind.Space -> Face("간격", "간격", special = false)
            Kind.Period -> Face(".", ".", special = false)
            Kind.Question -> Face("?", "?", special = false)
            Kind.Return -> Face(returnLabel, returnLabel, special = true)
            Kind.Globe -> Face("🌐", "다음 키보드", special = true)
        }
    }

    fun tap(key: Key, state: State): Effect = when (key.kind) {
        Kind.Letter -> characterEffect(letterOutput(key.base!!, state), state)
        Kind.Number -> if (state.direct || state.symbols) {
            Effect.Literal(numberOutput(key.base!!, state).toString())
        } else {
            Effect.Compose(numberOutput(key.base!!, state))
        }
        Kind.Shift -> Effect.Shift
        Kind.Backspace -> Effect.Backspace
        Kind.Symbol -> Effect.ToggleSymbols
        Kind.Language -> Effect.ToggleLanguage
        Kind.Hyphen -> plain('-', state)
        Kind.Space -> plain(' ', state)
        Kind.Period -> plain('.', state)
        Kind.Question -> plain('?', state)
        Kind.Return -> Effect.ReturnKey
        Kind.Globe -> Effect.NextKeyboard
    }

    /**
     * Null means the hold is not its own action, so releasing still delivers the tap.
     * ※ hold re-reads the open word and must not also toggle the symbol layer.
     */
    fun longPress(key: Key, state: State): Effect? = when (key.kind) {
        Kind.Letter -> if (state.symbols) null else characterEffect(qwertyShift(key.base!!), state)
        Kind.Number -> when {
            state.direct || state.symbols -> Effect.Literal(qwertyShift(key.base!!).toString())
            // The digit itself. Sending it through 390 would type the jamo on the cap.
            state.korean -> Effect.Literal(key.base!!.toString())
            else -> Effect.Compose(qwertyShift(key.base!!))
        }
        Kind.Symbol -> Effect.ConvertWord
        Kind.Language -> Effect.ToggleAutoSwitch
        Kind.Hyphen -> plain('→', state)
        Kind.Space -> plain('\t', state)
        Kind.Period -> plain(',', state)
        // '!' is a 390 batchim. The alternate is the punctuation mark, like iOS.
        Kind.Question -> Effect.Literal("!")
        Kind.Globe -> Effect.PickKeyboard
        else -> null
    }

    fun reduce(state: State, effect: Effect): State = when (effect) {
        Effect.Shift -> state.copy(shifted = !state.shifted)
        Effect.ToggleSymbols -> state.copy(symbols = !state.symbols)
        is Effect.Compose, is Effect.Literal -> state.copy(shifted = false)
        else -> state
    }

    fun qwertyShift(base: Char): Char = when (base) {
        in 'a'..'z' -> base.uppercaseChar()
        else -> SHIFTED[base] ?: base
    }

    fun symbolFor(base: Char): Char {
        val index = SYMBOL_POSITIONS.indexOf(base)
        if (index < 0 || index >= SYMBOL_VALUES.length) return base
        return SYMBOL_VALUES[index]
    }

    fun koreanLabel(key: Char): String = when (val glyph = KOREAN[key]) {
        null -> key.toString()
        is Korean.Text -> glyph.value.toString()
        is Korean.Jamo -> JamoLabels.compat(glyph.kind, glyph.scalar).toString()
    }

    private fun letterOutput(base: Char, state: State): Char = when {
        state.symbols && !state.direct -> symbolFor(base)
        state.shifted -> qwertyShift(base)
        else -> base
    }

    private fun numberOutput(base: Char, state: State): Char =
        if (state.shifted) qwertyShift(base) else base

    private fun characterEffect(character: Char, state: State): Effect =
        if (state.direct || state.symbols) Effect.Literal(character.toString()) else Effect.Compose(character)

    private fun plain(character: Char, state: State): Effect =
        if (state.direct) Effect.Literal(character.toString()) else Effect.Compose(character)

    private fun letterFace(base: Char, state: State, special: Boolean): Face {
        if (state.symbols && !state.direct) {
            val glyph = symbolFor(base).toString()
            return Face(glyph, glyph, special)
        }
        val produced = if (state.shifted) qwertyShift(base) else base
        val korean = koreanLabel(produced)
        val latin = produced.toString()
        val showKorean = state.korean && !state.direct
        val primary = if (showKorean) korean else latin
        val secondary = if (showKorean) latin else korean
        val text = if (primary == secondary) primary else "$primary\n$secondary"
        val current = if (showKorean) korean else latin
        return Face(text, "한글 $korean, 영문 $latin, 현재 $current", special)
    }

    private fun numberFace(base: Char, state: State): Face {
        val symbol = qwertyShift(base)
        if (state.direct || state.symbols || !state.korean) {
            return Face("$base $symbol", "숫자 $base, Shift $symbol", special = false)
        }
        val produced = if (state.shifted) symbol else base
        val korean = koreanLabel(produced)
        val text = if (korean == produced.toString()) "$base $symbol" else "$korean\n$base"
        return Face(text, "한글 $korean, 숫자 $base, Shift $symbol", special = false)
    }

    private sealed class Korean {
        data class Jamo(val kind: JamoLabels.Kind, val scalar: Int) : Korean()
        data class Text(val value: Char) : Korean()
    }

    private fun cho(scalar: Int) = Korean.Jamo(JamoLabels.Kind.CHO, scalar)
    private fun jung(scalar: Int) = Korean.Jamo(JamoLabels.Kind.JUNG, scalar)
    private fun jong(scalar: Int) = Korean.Jamo(JamoLabels.Kind.JONG, scalar)
    private fun text(value: Char) = Korean.Text(value)

    /** 390 readings that differ from the QWERTY character. Same table as Layout390. */
    private val KOREAN: Map<Char, Korean> = mapOf(
        '1' to jong(0x11C2), '2' to jong(0x11BB), '3' to jong(0x11B8),
        '4' to jung(0x116D), '5' to jung(0x1172), '6' to jung(0x1163),
        '7' to jung(0x1168), '8' to jung(0x1174), '9' to jung(0x116E),
        '0' to cho(0x110F),
        'q' to jong(0x11BA), 'w' to jong(0x11AF), 'e' to jung(0x1167),
        'r' to jung(0x1162), 't' to jung(0x1165), 'y' to cho(0x1105),
        'u' to cho(0x1103), 'i' to cho(0x1106), 'o' to cho(0x110E),
        'p' to cho(0x1111),
        'a' to jong(0x11BC), 's' to jong(0x11AB), 'd' to jung(0x1175),
        'f' to jung(0x1161), 'g' to jung(0x1173), 'h' to cho(0x1102),
        'j' to cho(0x110B), 'k' to cho(0x1100), 'l' to cho(0x110C),
        ';' to cho(0x1107), '\'' to cho(0x1110),
        'z' to jong(0x11B7), 'x' to jong(0x11A8), 'c' to jung(0x1166),
        'v' to jung(0x1169), 'b' to jung(0x116E), 'n' to cho(0x1109),
        'm' to cho(0x1112), '/' to jung(0x1169),
        '!' to jong(0x11BD),
        'Q' to jong(0x11C1), 'W' to jong(0x11C0), 'E' to jong(0x11BF),
        'R' to jung(0x1164), 'T' to text(';'), 'Y' to text('<'),
        'U' to text('7'), 'I' to text('8'), 'O' to text('9'), 'P' to text('>'),
        'A' to jong(0x11AE), 'S' to jong(0x11AD), 'D' to jong(0x11B0),
        'F' to jong(0x11A9), 'G' to text('/'), 'H' to text('\''),
        'J' to text('4'), 'K' to text('5'), 'L' to text('6'),
        'Z' to jong(0x11BE), 'X' to jong(0x11B9), 'C' to jong(0x11B1),
        'V' to jong(0x11B6), 'B' to text('!'), 'N' to text('0'), 'M' to text('1'),
        '<' to text('2'), '>' to text('3'),
    )

    private val SHIFTED = mapOf(
        '1' to '!', '2' to '@', '3' to '#', '4' to '$', '5' to '%',
        '6' to '^', '7' to '&', '8' to '*', '9' to '(', '0' to ')',
        '`' to '~', '-' to '_', '=' to '+', '[' to '{', ']' to '}',
        '\\' to '|', ';' to ':', '\'' to '"', ',' to '<', '.' to '>', '/' to '?',
    )

    private val SPECIAL = setOf(
        Kind.Shift, Kind.Backspace, Kind.Symbol, Kind.Language, Kind.Return, Kind.Globe,
    )

    private const val SYMBOL_POSITIONS = "1234567890qwertyuiopasdfghjkl;zxcvbnm,./"
    private const val SYMBOL_VALUES = "1234567890-/:;()₩&@~,+!'\"[]{}+=_*%<>\\|~`#"
}
