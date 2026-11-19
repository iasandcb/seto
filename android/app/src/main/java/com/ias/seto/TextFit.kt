package com.ias.seto

/**
 * Largest size in [minSizePx, maxSizePx] whose lines fit the key.
 * Callers draw the returned size with ellipsize disabled, so a label never becomes "...".
 */
internal fun fittedTextSizePx(
    lines: List<String>,
    maxWidthPx: Float,
    maxHeightPx: Float,
    maxSizePx: Float,
    minSizePx: Float,
    measureWidth: (sizePx: Float, line: String) -> Float,
    lineHeight: (sizePx: Float) -> Float,
): Float {
    if (lines.isEmpty() || maxWidthPx <= 0f || maxHeightPx <= 0f) return minSizePx
    var size = maxSizePx
    while (size > minSizePx) {
        val widthFits = lines.all { measureWidth(size, it) <= maxWidthPx }
        val heightFits = lineHeight(size) * lines.size <= maxHeightPx
        if (widthFits && heightFits) return size
        size -= 1f
    }
    return minSizePx
}
