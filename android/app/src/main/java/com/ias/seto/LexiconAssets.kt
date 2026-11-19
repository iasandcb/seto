package com.ias.seto

import android.content.Context
import com.ias.seto.core.LexiconPaths
import com.ias.seto.core.loadLexicon
import java.io.File

internal object LexiconAssets {
    @Synchronized fun load(context: Context) {
        // Bump this version when the bundled lists change. Never overwrite an mmap'd file.
        val directory = File(context.filesDir, "lexicon-v2").apply { mkdirs() }
        fun copy(name: String): String {
            val destination = File(directory, name)
            if (!destination.isFile) {
                val temporary = File(directory, "$name.tmp")
                context.assets.open("lexicon/$name").use { input ->
                    temporary.outputStream().use { output -> input.copyTo(output) }
                }
                check(temporary.renameTo(destination)) { "Cannot publish lexicon asset" }
            }
            return destination.absolutePath
        }
        loadLexicon(LexiconPaths(copy("keyboard-english.txt"), copy("korean-words.txt"), copy("keyboard-korean-valid.txt")))
    }
}
