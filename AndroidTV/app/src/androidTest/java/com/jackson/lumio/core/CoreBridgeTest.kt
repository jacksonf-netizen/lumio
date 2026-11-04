package com.jackson.lumio.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/** The real core through JNI: requests, replies, errors and text outside the basic plane. */
@RunWith(AndroidJUnit4::class)
class CoreBridgeTest {
    init {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        InstrumentationRegistry.getInstrumentation().runOnMainSync { LumioCore.start(context) }
    }

    @Test fun emojiSurviveTheRoundTrip() = runBlocking {
        val name = "⚽ Sport 📺 Télé"
        val id = LumioCore.addProvider(name, "http://bridge-test.invalid", "viewer", "pass")
        try {
            val provider = LumioCore.providers().single { it.id == id }
            assertEquals(name, provider.name)
            assertEquals("viewer", LumioCore.providerEditor(id).username)
        } finally {
            LumioCore.removeProvider(id)
        }
        assertFalse(LumioCore.providers().any { it.id == id })
    }

    @Test fun badRequestsComeBackAsMessages() = runBlocking {
        try {
            LumioCore.call("providers.nonsense")
            fail("expected an error")
        } catch (error: CoreException) {
            assertTrue(error.message!!.contains("Unknown request"))
        }
        val checks = LumioCore.debug("icuChecks") as org.json.JSONArray
        assertTrue(checks.length() > 10)
    }
}
