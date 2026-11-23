package com.ias.seto

/**
 * On-screen board matching the iOS keyboard extension (`KeyboardView`).
 *
 * Rows, key set, stacked Hangul/QWERTY caps, the ※ symbol layer, and Shift
 * follow that view. Hangul caps are the standard two-set readings iOS draws,
 * not Sebeolsik 390. Hardware keys use the session layout (default 390);
 * a soft-key letter is a dubeol atom (`dubeolAtom`).
 *
 * The phrase bar, suggestions, and one-handed mode are not on this keyboard.
 * The iOS globe stays a 32dp leading key so the IME can still be switched.
 */
internal object SoftLayout {
    const val KEY_HEIGHT_DP = 44
    const val ROW_GAP_DP = 11
    const val KEY_GAP_DP = 4
    const val SHIFT_GAP_DP = 14
    const val HOME_INSET = 0.05f
    const val GLOBE_WIDTH_DP = 32
    const val CORNER_RADIUS_DP = 5
    const val VERTICAL_MARGIN_DP = 6
    const val HORIZONTAL_MARGIN_DP = 4
    const val MIN_SPACE_DP = 80
    /** iOS landscape content height minus the phrase bar and its gap. */
    const val LANDSCAPE_KEY_BLOCK_DP = 200
    const val AUTO_SWITCH_MENU = "자동 한영 전환"

    enum class Kind {
        Letter, Number, Shift, Backspace, Symbol, Language, Hyphen, Space, Period, Question, Return, Globe,
    }

    data class Key(val kind: Kind, val base: Char? = null)

    data class Face(
        val text: String,
        val label: String,
        val special: Boolean,
        val latched: Boolean = false,
        val textSizeSp: Int = 17,
    )

    sealed class Effect {
        data class Compose(val character: Char) : Effect()
        data class Literal(val text: String) : Effect()
        data object Backspace : Effect()
        data object DeleteWord : Effect()
        data object Shift : Effect()
        data object ToggleSymbols : Effect()
        data object ConvertWord : Effect()
        data object ToggleLanguage : Effect()
        data object ShowAutoMenu : Effect()
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

    /** english character plus the two-set jamo iOS would compose for it. */
    data class DubeolAtom(val english: Char, val scalar: Int, val jungseong: Boolean)

    val numberRow = "1234567890".map { Key(Kind.Number, it) }
    val topRow = "qwertyuiop".map { Key(Kind.Letter, it) }
    /** Nine keys. iOS insets this row; choseong ㅂ and ㅌ live on q and x. */
    val homeRow = "asdfghjkl".map { Key(Kind.Letter, it) }
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

    fun autoSwitchState(enabled: Boolean): String = if (enabled) "자동 한영 켜짐" else "자동 한영 꺼짐"

    fun face(key: Key, state: State, returnLabel: String = "↵"): Face {
        val special = key.kind in SPECIAL
        return when (key.kind) {
            Kind.Letter -> letterFace(key.base!!, state)
            Kind.Number -> numberFace(key.base!!, state)
            Kind.Shift -> Face("⇧", "시프트", special = true, latched = state.shifted, textSizeSp = 18)
            Kind.Backspace -> Face("⌫", "삭제", special = true, textSizeSp = 18)
            Kind.Symbol -> Face("※", "기호 자판 전환", special = true, latched = state.symbols, textSizeSp = 22)
            Kind.Language -> Face("↔", "한영 전환 및 자동 변환 되돌리기", special = true, textSizeSp = 16)
            Kind.Hyphen -> Face("-", "하이픈 입력", special = false, textSizeSp = 16)
            Kind.Space -> Face("간격", "간격", special = false, textSizeSp = 16)
            Kind.Period -> Face(".", ".", special = false, textSizeSp = 16)
            Kind.Question -> Face("?", "?", special = false, textSizeSp = 16)
            Kind.Return -> Face(returnLabel, returnLabel, special = true, textSizeSp = 16)
            Kind.Globe -> Face("🌐", "다음 키보드", special = true, textSizeSp = 18)
        }
    }

    fun tap(key: Key, state: State): Effect = when (key.kind) {
        Kind.Letter -> characterEffect(letterOutput(key.base!!, state), state)
        Kind.Number -> Effect.Literal(numberOutput(key.base!!, state).toString())
        Kind.Shift -> Effect.Shift
        Kind.Backspace -> Effect.Backspace
        Kind.Symbol -> Effect.ToggleSymbols
        Kind.Language -> Effect.ToggleLanguage
        Kind.Hyphen -> Effect.Literal("-")
        Kind.Space -> plain(' ', state)
        Kind.Period -> Effect.Literal(".")
        Kind.Question -> Effect.Literal("?")
        Kind.Return -> Effect.ReturnKey
        Kind.Globe -> Effect.NextKeyboard
    }

    /**
     * Null means the hold is not its own action, so releasing still delivers the tap.
     * ※ hold re-reads the open word and must not also toggle the symbol layer.
     * ↔ hold opens the auto-switch check, matching the iOS menu, and does not toggle yet.
     */
    fun longPress(key: Key, state: State): Effect? = when (key.kind) {
        Kind.Letter -> if (state.symbols) null else characterEffect(qwertyShift(key.base!!), state)
        Kind.Number -> Effect.Literal(qwertyShift(key.base!!).toString())
        Kind.Symbol -> Effect.ConvertWord
        Kind.Language -> Effect.ShowAutoMenu
        Kind.Hyphen -> Effect.Literal("→")
        Kind.Space -> Effect.Literal("\t")
        Kind.Period -> Effect.Literal(",")
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

    /** Two-set compat jamo for [key], or the character itself when it is not a letter. */
    fun koreanLabel(key: Char): String {
        val atom = dubeolAtom(key) ?: return key.toString()
        val kind = if (atom.jungseong) JamoLabels.Kind.JUNG else JamoLabels.Kind.CHO
        return JamoLabels.compat(kind, atom.scalar).toString()
    }

    /**
     * Letter atoms only. Space, newline, and punctuation stay on the session's
     * own layout (or are inserted literally) because two-set reads them as themselves.
     */
    fun dubeolAtom(key: Char): DubeolAtom? {
        val lower = key.lowercaseChar()
        val index = DUBEOL_LETTERS.indexOf(lower)
        if (index < 0) return null
        val scalar = DUBEOL_SHIFT[key] ?: DUBEOL_SCALARS[index]
        return DubeolAtom(key, scalar, scalar >= 0x1161)
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

    private fun letterFace(base: Char, state: State): Face {
        if (state.symbols && !state.direct) {
            val glyph = symbolFor(base).toString()
            return Face(glyph, glyph, special = false, textSizeSp = 21)
        }
        val produced = if (state.shifted) qwertyShift(base) else base
        val korean = koreanLabel(produced)
        val latin = produced.toString()
        val showKorean = state.korean && !state.direct
        val primary = if (showKorean) korean else latin
        val secondary = if (showKorean) latin else korean
        val text = if (primary == secondary) primary else "$primary\n$secondary"
        val current = if (showKorean) korean else latin
        val size = if (primary == secondary) 21 else 17
        return Face(text, "한글 $korean, 영문 $latin, 현재 $current", special = false, textSizeSp = size)
    }

    private fun numberFace(base: Char, state: State): Face {
        val symbol = qwertyShift(base)
        val current = if (state.shifted) symbol else base
        return Face(
            "$base $symbol",
            "숫자 $base, Shift $symbol, 현재 $current",
            special = false,
            textSizeSp = 17,
        )
    }

    private val SHIFTED = mapOf(
        '1' to '!', '2' to '@', '3' to '#', '4' to '$', '5' to '%',
        '6' to '^', '7' to '&', '8' to '*', '9' to '(', '0' to ')',
        '`' to '~', '-' to '_', '=' to '+', '[' to '{', ']' to '}',
        '\\' to '|', ';' to ':', '\'' to '"', ',' to '<', '.' to '>', '/' to '?',
    )

    private val SPECIAL = setOf(
        Kind.Shift, Kind.Backspace, Kind.Symbol, Kind.Language, Kind.Return, Kind.Globe,
    )

    /** Same slots as `KeyboardView.output` in symbol mode, including keys this board does not show. */
    private const val SYMBOL_POSITIONS = "1234567890qwertyuiopasdfghjkl;zxcvbnm,./"
    private const val SYMBOL_VALUES = "1234567890-/:;()₩&@~,+!'\"[]{}+=_*%<>\\|~`#"

    private const val DUBEOL_LETTERS = "qwertyuiopasdfghjklzxcvbnm"
    private val DUBEOL_SCALARS = intArrayOf(
        0x1107, 0x110C, 0x1103, 0x1100, 0x1109, 0x116D, 0x1167, 0x1163, 0x1162, 0x1166,
        0x1106, 0x1102, 0x110B, 0x1105, 0x1112, 0x1169, 0x1165, 0x1161, 0x1175,
        0x110F, 0x1110, 0x110E, 0x1111, 0x1172, 0x116E, 0x1173,
    )
    private val DUBEOL_SHIFT = mapOf(
        'Q' to 0x1108, 'W' to 0x110D, 'E' to 0x1104, 'R' to 0x1101,
        'T' to 0x110A, 'O' to 0x1164, 'P' to 0x1168,
    )
}
