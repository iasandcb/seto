package com.ias.seto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorDeliveryTest {
    @Test fun missingEditorIsTheBindingFallbackNotASecondConnection() {
        val binding = Any()
        val started = Any()
        assertTrue(editorConnectionMissing(current = null, binding = binding))
        assertTrue(editorConnectionMissing(current = binding, binding = binding))
        assertFalse(editorConnectionMissing(current = started, binding = binding))
        assertFalse(editorConnectionMissing(current = started, binding = null))
    }

    @Test fun patchReplacesASyllableAndAppendsABoundary() {
        assertEquals(TextPatch(0, "ㅁ"), textPatch("", "ㅁ"))
        assertEquals(TextPatch(1, "마"), textPatch("ㅁ", "마"))
        assertEquals(TextPatch(0, " "), textPatch("마", "마 "))
        assertEquals(TextPatch(0, "안"), textPatch("마 ", "마 안"))
        assertEquals(TextPatch(0, ""), textPatch("마", "마"))
    }

    @Test fun patchDoesNotSplitASurrogatePair() {
        val emoji = "\uD83C\uDF00"
        val patch = textPatch(emoji, emoji + "가")
        assertEquals(0, patch.delete)
        assertEquals("가", patch.insert)
        assertEquals(TextPatch(1, "나"), textPatch(emoji, "나"))
    }

    @Test fun swallowCommitDoesNotCountAsDelivered() {
        assertFalse(deliveryAccepted(commit = true, visible = false, keyEvent = false))
        assertFalse(deliveryAccepted(commit = false, visible = false, keyEvent = false))
        assertTrue(deliveryAccepted(commit = true, visible = true, keyEvent = false))
        assertTrue(deliveryAccepted(commit = false, visible = false, keyEvent = true))
    }
}
