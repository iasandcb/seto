package com.ias.seto

import android.content.Context
import android.content.res.Configuration
import android.graphics.Typeface
import android.text.Layout
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.PopupMenu
import android.widget.TextView
import kotlin.math.max
import kotlin.math.min

/**
 * Key grid sized like the iOS touch keyboard: 44dp caps, 11dp row gaps, and a
 * 5% inset on the nine-key home row. Shift, symbol mode, and repeat timing live
 * here. The service applies every [SoftLayout.Effect].
 */
internal class SoftKeyboardView(
    context: Context,
    private val host: Host,
) : ViewGroup(context) {
    interface Host {
        fun onEffect(effect: SoftLayout.Effect)
        fun hasMoreText(): Boolean
    }

    private val keys = mutableListOf<KeyCap>()
    private val numberKeys = row(SoftLayout.numberRow)
    private val topKeys = row(SoftLayout.topRow)
    private val homeKeys = row(SoftLayout.homeRow)
    private val shiftKey = cap(SoftLayout.Key(SoftLayout.Kind.Shift))
    private val letterKeys = row(SoftLayout.bottomLetters)
    private val backspaceKey = cap(SoftLayout.Key(SoftLayout.Kind.Backspace))
    private val bottomKeys = row(SoftLayout.bottomRow)
    private var state = SoftLayout.State()
    private var automatic = true
    private var returnLabel = "↵"
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val repeat = BackspaceRepeat()
    private var holding: KeyCap? = null
    private var holdFired = false
    private var movedOff = false
    private val audio = context.getSystemService(AudioManager::class.java)
    private val slop = ViewConfiguration.get(context).scaledTouchSlop

    init {
        isFocusable = false
        isFocusableInTouchMode = false
        descendantFocusability = FOCUS_BLOCK_DESCENDANTS
        val marginH = dp(SoftLayout.HORIZONTAL_MARGIN_DP)
        val marginV = dp(SoftLayout.VERTICAL_MARGIN_DP)
        setPadding(marginH, marginV, marginH, marginV)
        setOnApplyWindowInsetsListener { _, insets ->
            val bottom = insets.getInsets(WindowInsets.Type.navigationBars()).bottom + marginV
            if (paddingBottom != bottom) setPadding(paddingLeft, paddingTop, paddingRight, bottom)
            insets
        }
        val children = numberKeys + topKeys + homeKeys + listOf(shiftKey) + letterKeys +
            listOf(backspaceKey) + bottomKeys
        children.forEach { addView(it) }
        applyChrome()
        refreshFaces()
        setAutomatic(true)
    }

    fun setKorean(korean: Boolean) {
        if (state.korean == korean) return
        state = state.copy(korean = korean)
        refreshFaces()
    }

    fun setDirect(direct: Boolean) {
        state = state.copy(direct = direct, shifted = false, symbols = false)
        refreshFaces()
    }

    fun setAutomatic(enabled: Boolean) {
        automatic = enabled
        keys.filter { it.spec.kind == SoftLayout.Kind.Language }.forEach { key ->
            key.stateDescription = SoftLayout.autoSwitchState(enabled)
        }
    }

    fun setReturnLabel(label: String) {
        if (returnLabel == label) return
        returnLabel = label
        refreshFaces()
    }

    fun cancelPointer() {
        handler.removeCallbacksAndMessages(null)
        repeat.end()
        holding?.let {
            it.isPressed = false
            paint(it)
        }
        holding = null
        holdFired = false
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec).takeIf { it > 0 } ?: dp(360)
        val natural = keyBlock(1f)
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val block = if (landscape) min(natural, dp(SoftLayout.LANDSCAPE_KEY_BLOCK_DP)) else natural
        val preferred = paddingTop + paddingBottom + block
        val height = when (MeasureSpec.getMode(heightMeasureSpec)) {
            MeasureSpec.EXACTLY -> MeasureSpec.getSize(heightMeasureSpec)
            MeasureSpec.AT_MOST -> min(preferred, MeasureSpec.getSize(heightMeasureSpec))
            else -> preferred
        }
        setMeasuredDimension(width, max(height, 0))
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestApplyInsets()
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val inner = width - paddingLeft - paddingRight
        val gap = dp(SoftLayout.KEY_GAP_DP)
        val rows = ROWS
        val available = height - paddingTop - paddingBottom
        val natural = keyBlock(1f)
        val scale = if (natural <= 0) 1f else min(1f, available.toFloat() / natural)
        val keyH = max(1, (dp(SoftLayout.KEY_HEIGHT_DP) * scale).toInt())
        val preferredGap = max(0, (dp(SoftLayout.ROW_GAP_DP) * scale).toInt())
        val gapBudget = available - keyH * rows
        val vGap = if (rows <= 1) 0 else min(preferredGap, max(0, gapBudget / (rows - 1)))
        val ten = equalWidths(10, inner, gap)
        val letterW = ten.min()
        var y = paddingTop
        placeEqual(numberKeys, paddingLeft, y, keyH, inner, gap)
        y += keyH + vGap
        placeEqual(topKeys, paddingLeft, y, keyH, inner, gap)
        y += keyH + vGap
        placeHome(y, keyH, inner, gap)
        y += keyH + vGap
        placeShiftRow(y, keyH, inner, gap, letterW)
        y += keyH + vGap
        placeBottom(y, keyH, inner, gap, letterW)
        keys.forEach { fit(it) }
    }

    private fun keyBlock(scale: Float): Int {
        val keyH = (dp(SoftLayout.KEY_HEIGHT_DP) * scale).toInt()
        val vGap = (dp(SoftLayout.ROW_GAP_DP) * scale).toInt()
        return keyH * ROWS + vGap * (ROWS - 1)
    }

    private fun placeEqual(row: List<KeyCap>, x0: Int, y: Int, keyH: Int, inner: Int, gap: Int) {
        val widths = equalWidths(row.size, inner, gap)
        var x = x0
        row.zip(widths).forEach { (view, w) ->
            place(view, x, y, w, keyH)
            x += w + gap
        }
    }

    private fun placeHome(y: Int, keyH: Int, inner: Int, gap: Int) {
        val inset = (inner * SoftLayout.HOME_INSET).toInt()
        val rowInner = max(1, inner - inset * 2)
        placeEqual(homeKeys, paddingLeft + inset, y, keyH, rowInner, gap)
    }

    private fun placeShiftRow(y: Int, keyH: Int, inner: Int, gap: Int, preferredLetter: Int) {
        val sideGap = dp(SoftLayout.SHIFT_GAP_DP)
        val count = letterKeys.size
        var letterW = preferredLetter
        fun lettersWidth(width: Int) = width * count + gap * (count - 1)
        if (letterW * 2 + lettersWidth(letterW) + sideGap * 2 > inner) {
            letterW = max(1, (inner - gap * (count - 1) - sideGap * 2) / (count + 2))
        }
        val letters = lettersWidth(letterW)
        val side = max(letterW, (inner - letters - sideGap * 2) / 2)
        var x = paddingLeft
        place(shiftKey, x, y, side, keyH)
        x += side + sideGap
        letterKeys.forEachIndexed { index, view ->
            place(view, x, y, letterW, keyH)
            x += letterW
            if (index != letterKeys.lastIndex) x += gap
        }
        x += sideGap
        place(backspaceKey, x, y, max(1, paddingLeft + inner - x), keyH)
    }

    private fun placeBottom(y: Int, keyH: Int, inner: Int, gap: Int, letterW: Int) {
        val globe = bottomKeys.first { it.spec.kind == SoftLayout.Kind.Globe }
        val space = bottomKeys.first { it.spec.kind == SoftLayout.Kind.Space }
        val fixed = bottomKeys.filter { it !== space && it !== globe }
        val globeW = dp(SoftLayout.GLOBE_WIDTH_DP)
        val gaps = gap * (bottomKeys.size - 1)
        val minSpace = dp(SoftLayout.MIN_SPACE_DP)
        var fixedW = letterW
        if (globeW + fixedW * fixed.size + gaps + minSpace > inner) {
            fixedW = max(dp(28), (inner - globeW - gaps - minSpace) / fixed.size)
        }
        val spaceW = max(dp(48), inner - globeW - fixedW * fixed.size - gaps)
        var x = paddingLeft
        bottomKeys.forEach { view ->
            val w = when {
                view === globe -> globeW
                view === space -> spaceW
                else -> fixedW
            }
            place(view, x, y, w, keyH)
            x += w + gap
        }
    }

    private fun place(view: KeyCap, x: Int, y: Int, w: Int, h: Int) {
        view.measure(
            MeasureSpec.makeMeasureSpec(max(1, w), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(max(1, h), MeasureSpec.EXACTLY),
        )
        view.layout(x, y, x + max(1, w), y + max(1, h))
    }

    private fun equalWidths(count: Int, inner: Int, gap: Int): List<Int> {
        val base = (inner - gap * (count - 1)) / count
        val extra = (inner - gap * (count - 1)) % count
        return List(count) { base + if (it < extra) 1 else 0 }
    }

    private fun fit(view: KeyCap) {
        val padX = dp(2)
        val padY = dp(1)
        val maxW = (view.width - padX * 2).toFloat()
        val maxH = (view.height - padY * 2).toFloat()
        val lines = view.text?.toString().orEmpty().split('\n')
        val paint = view.paint
        val preferred = spPx(view.face.textSizeSp)
        val size = fittedTextSizePx(
            lines, maxW, maxH, preferred, preferred * 0.5f,
            measureWidth = { px, line ->
                paint.textSize = px
                paint.measureText(line)
            },
            lineHeight = { px ->
                paint.textSize = px
                paint.fontSpacing
            },
        )
        view.setTextSize(TypedValue.COMPLEX_UNIT_PX, size)
        view.ellipsize = null
    }

    private fun refreshFaces() {
        keys.forEach { key ->
            val face = SoftLayout.face(key.spec, state, returnLabel)
            key.face = face
            key.text = face.text
            key.contentDescription = face.label
            key.ellipsize = null
            paint(key)
        }
        if (width > 0) keys.forEach { fit(it) }
    }

    private fun applyChrome() {
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        setBackgroundColor(if (night) 0xFF1F1F1F.toInt() else 0xFFE8EAED.toInt())
        keys.forEach { paint(it) }
    }

    private fun paint(view: KeyCap) {
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        val key = if (night) 0xFF3C4043.toInt() else 0xFFFFFFFF.toInt()
        val special = if (night) 0xFF5F6368.toInt() else 0xFFD3D6DA.toInt()
        val pressed = if (night) 0xFF6B7075.toInt() else 0xFFC5C8CC.toInt()
        val latched = if (night) 0xFF8AB4F8.toInt() else 0xFF1A73E8.toInt()
        val text = if (night) 0xFFE8EAED.toInt() else 0xFF202124.toInt()
        val bg = when {
            view.face.latched -> latched
            view.isPressed -> pressed
            view.face.special -> special
            else -> key
        }
        view.background = GradientDrawable().apply {
            cornerRadius = dp(SoftLayout.CORNER_RADIUS_DP).toFloat()
            setColor(bg)
        }
        view.setTextColor(if (view.face.latched) 0xFFFFFFFF.toInt() else text)
    }

    private fun onDown(view: KeyCap) {
        cancelPointer()
        holding = view
        holdFired = false
        movedOff = false
        view.isPressed = true
        paint(view)
        feedback(view.spec.kind)
        when (view.spec.kind) {
            SoftLayout.Kind.Backspace -> beginRepeat()
            SoftLayout.Kind.Shift -> {
                holdFired = true
                dispatch(SoftLayout.Effect.Shift)
            }
            else -> handler.postDelayed({ fireLongPress(view) }, LONG_PRESS_MS)
        }
    }

    private fun fireLongPress(view: KeyCap) {
        if (holding !== view || movedOff) return
        val effect = SoftLayout.longPress(view.spec, state) ?: return
        holdFired = true
        feedback(view.spec.kind)
        if (effect == SoftLayout.Effect.ShowAutoMenu) showAutoMenu(view) else dispatch(effect)
    }

    /** iOS shows this as a checkmark menu on ↔. Choosing the row flips the setting. */
    private fun showAutoMenu(anchor: View) {
        val popup = PopupMenu(context, anchor)
        val item = popup.menu.add(SoftLayout.AUTO_SWITCH_MENU)
        item.isCheckable = true
        item.isChecked = automatic
        popup.setOnMenuItemClickListener {
            dispatch(SoftLayout.Effect.ToggleAutoSwitch)
            true
        }
        popup.show()
    }

    private fun onUp(view: KeyCap) {
        handler.removeCallbacksAndMessages(null)
        val wasRepeat = view.spec.kind == SoftLayout.Kind.Backspace
        if (wasRepeat) repeat.end()
        if (holding === view && !holdFired && !movedOff && !wasRepeat) {
            dispatch(SoftLayout.tap(view.spec, state))
        }
        view.isPressed = false
        paint(view)
        holding = null
    }

    private fun dispatch(effect: SoftLayout.Effect) {
        state = SoftLayout.reduce(state, effect)
        refreshFaces()
        host.onEffect(effect)
    }

    private fun beginRepeat() {
        host.onEffect(SoftLayout.Effect.Backspace)
        if (!host.hasMoreText()) return
        repeat.begin(now())
        scheduleRepeat()
    }

    private fun scheduleRepeat() {
        val deadline = repeat.nextDeadline() ?: return
        val delay = ((deadline - now()) * 1000.0).toLong().coerceAtLeast(0L)
        handler.postDelayed({
            val actions = repeat.dueActions(now())
            for (action in actions) {
                val effect = if (action == BackspaceRepeat.Action.Word) {
                    SoftLayout.Effect.DeleteWord
                } else {
                    SoftLayout.Effect.Backspace
                }
                feedback(SoftLayout.Kind.Backspace)
                host.onEffect(effect)
                if (!host.hasMoreText()) {
                    repeat.end()
                    return@postDelayed
                }
            }
            scheduleRepeat()
        }, delay)
    }

    private fun feedback(kind: SoftLayout.Kind) {
        performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        val sound = when (kind) {
            SoftLayout.Kind.Backspace -> AudioManager.FX_KEYPRESS_DELETE
            SoftLayout.Kind.Return -> AudioManager.FX_KEYPRESS_RETURN
            SoftLayout.Kind.Space -> AudioManager.FX_KEYPRESS_SPACEBAR
            else -> AudioManager.FX_KEYPRESS_STANDARD
        }
        audio?.playSoundEffect(sound)
    }

    private fun now() = SystemClock.uptimeMillis() / 1000.0

    private fun row(keys: List<SoftLayout.Key>) = keys.map { cap(it) }

    private fun cap(spec: SoftLayout.Key): KeyCap {
        val view = KeyCap(context, spec)
        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> onDown(view)
                MotionEvent.ACTION_MOVE -> {
                    val inside = event.x >= -slop && event.y >= -slop &&
                        event.x < view.width + slop && event.y < view.height + slop
                    if (!inside) {
                        movedOff = true
                        handler.removeCallbacksAndMessages(null)
                        if (view.spec.kind == SoftLayout.Kind.Backspace) repeat.end()
                    }
                }
                MotionEvent.ACTION_UP -> onUp(view)
                MotionEvent.ACTION_CANCEL -> {
                    movedOff = true
                    onUp(view)
                }
            }
            true
        }
        keys += view
        return view
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt().coerceAtLeast(if (value == 0) 0 else 1)

    private fun spPx(value: Int): Float = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_SP, value.toFloat(), resources.displayMetrics,
    )

    override fun onDetachedFromWindow() {
        cancelPointer()
        super.onDetachedFromWindow()
    }

    private class KeyCap(context: Context, val spec: SoftLayout.Key) : TextView(context) {
        var face: SoftLayout.Face = SoftLayout.Face("", "", false)

        init {
            gravity = Gravity.CENTER
            maxLines = 2
            ellipsize = null
            isSingleLine = false
            includeFontPadding = false
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            isFocusable = false
            isFocusableInTouchMode = false
            isClickable = true
            importantForAutofill = IMPORTANT_FOR_AUTOFILL_NO
            setHorizontallyScrolling(false)
            hyphenationFrequency = Layout.HYPHENATION_FREQUENCY_NONE
        }
    }

    companion object {
        private const val ROWS = 5
        private const val LONG_PRESS_MS = 400L
    }
}
