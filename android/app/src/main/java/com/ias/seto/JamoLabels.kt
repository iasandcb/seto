package com.ias.seto

/** Compatibility jamo for key caps. Composition stays in the Rust core. */
internal object JamoLabels {
    enum class Kind { CHO, JUNG, JONG }

    fun compat(kind: Kind, scalar: Int): Char {
        val value = when (kind) {
            Kind.CHO -> choCompat(scalar)
            Kind.JUNG -> 0x314F + scalar - 0x1161
            Kind.JONG -> jongCompat(scalar)
        }
        return value.toChar()
    }

    private fun choCompat(scalar: Int): Int {
        val table = intArrayOf(
            0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143,
            0x3145, 0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
        )
        return table.getOrElse(scalar - 0x1100) { 0x3131 }
    }

    private fun jongCompat(scalar: Int): Int {
        val table = intArrayOf(
            0x3131, 0x3132, 0x3133, 0x3134, 0x3135, 0x3136, 0x3137, 0x3139, 0x313A,
            0x313B, 0x313C, 0x313D, 0x313E, 0x313F, 0x3140, 0x3141, 0x3142, 0x3144,
            0x3145, 0x3146, 0x3147, 0x3148, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E,
        )
        return table.getOrElse(scalar - 0x11A8) { 0x3131 }
    }
}
