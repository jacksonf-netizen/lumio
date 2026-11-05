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

    private fun fixtureObject(name: String): JSONObject =
        JSONObject(InstrumentationRegistry.getInstrumentation().context.assets.open(name).bufferedReader().readText())

    @Test fun moviesAndSeries() {
        val home = VODHome(fixtureObject("vod_home.json"))
        assertTrue(home.recentlyWatched[0].canResume)
        assertEquals(9, home.recentlyWatched[1].series)
        assertEquals("S1 E2 · Second", home.recentlyWatched[1].subtitle)
        assertEquals("Dune", home.recentlyAdded[0].name)
        assertEquals(2021, home.recentlyAdded[0].year)
        assertEquals("Science Fiction", home.shelves[0].category.name)
        assertEquals(0.26, home.shelves[0].items[0].progress!!, 0.0001)

        val movie = MovieInfo(fixtureObject("movie.json"))
        assertEquals(6960, movie.duration)
        assertEquals("Denis Villeneuve", movie.director)
        assertTrue(movie.progress!!.canResume)
        assertNull(movie.detailsError)

        val series = SeriesInfo(fixtureObject("series.json"))
        assertEquals(listOf("Season One", "Season 2"), series.seasons.map { it.name })
        assertEquals(listOf("e11", "e12", "e21"), series.episodes.map { it.id })
        assertTrue(series.episodes[0].progress!!.watched)
        assertNull(series.episodes[1].progress)
        assertEquals("e12", series.next)
        assertEquals("The provider didn't answer in time.", series.detailsError)
    }

    @Test fun guideRows() {
        val rows = fixture("guide.json").map(::GuideRow)
        assertEquals(listOf("bbcone.uk", "empty.uk"), rows.map { it.epg.id })
        val quiz = rows[0].programmes[0]
        assertEquals("S4 E12", quiz.episode)
        assertEquals("Entertainment", quiz.category)
        assertEquals("Four teams, one trophy.", quiz.summary)
        assertNull(rows[0].programmes[1].episode)
        assertTrue(quiz.isOn(1793815200.0))
        assertTrue(rows[1].programmes.isEmpty())
    }
}
