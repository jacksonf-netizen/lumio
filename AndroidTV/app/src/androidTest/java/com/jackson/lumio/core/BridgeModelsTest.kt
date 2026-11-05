package com.jackson.lumio.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Reads the bridge fixtures the Swift tests read too (Shared/LumioCore/Tests/IPTVBridgeTests/Fixtures),
 * so a field renamed on one side fails here or there.
 */
@RunWith(AndroidJUnit4::class)
class BridgeModelsTest {
    private fun fixture(name: String): List<JSONObject> {
        val text = InstrumentationRegistry.getInstrumentation().context.assets.open(name).bufferedReader().readText()
        val array = JSONArray(text)
        return List(array.length()) { array.getJSONObject(it) }
    }

    @Test fun providers() {
        val providers = fixture("providers.json").map(::ProviderInfo)
        assertEquals(2, providers.size)
        val first = providers[0]
        assertEquals("Provider One", first.name)
        assertEquals(listOf(true, false), first.links.map { it.inUse })
        assertTrue(first.links[1].down)
        assertEquals(1800000000.0, first.expiresAt)
        assertNull(first.syncing)
        assertEquals("Updating channels…", providers[1].syncing)
        assertEquals("The provider rejected the username or password.", providers[1].lastError)
    }

    @Test fun channelsAndGroups() {
        val channels = fixture("channels.json").map(::Channel)
        assertEquals(EPGRef("bbcone.uk", listOf("p1")), channels[0].epg)
        assertEquals(101, channels[0].number)
        assertNull(channels[1].number)
        assertNull(channels[1].epg)
        assertEquals(listOf("favorites", "all", "category"), fixture("groups.json").map(::ChannelGroup).map { it.kind })
    }

    @Test fun nowNextAndEvents() {
        val nowNext = fixture("nownext.json").map(::NowNext).single()
        assertEquals("News at Six", nowNext.now?.title)
        assertEquals(0.5f, nowNext.now!!.progress(1793816100.0), 0.001f)
        val events = fixture("events.json").map(::BridgeEvent)
        assertEquals(listOf("providers", "sync", "sync", "live"), events.map { it.type })
        assertTrue(events[2].finished)
    }
}
