package com.jackson.lumio.ui.guide

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.jackson.lumio.core.Programme
import com.jackson.lumio.ui.guide.GuideNavigation.SLOT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/** How the remote moves the guide's highlight. */
@RunWith(AndroidJUnit4::class)
class GuideNavigationTest {
    /** 18:00 on some day, as seconds since 1970 (a whole half hour). */
    private val six = 1_793_815_200.0
    private val hour = 3600.0
    private val window = 1.5 * hour

    /** Times here are whole seconds, so they compare exactly. */
    private fun assertEquals(expected: Double, actual: Double) = org.junit.Assert.assertEquals(expected, actual, 0.0)

    private fun show(title: String, start: Double, minutes: Int) = Programme(title, start, start + minutes * 60)

    // 17:00 Film (2 h) · 19:00 News (30 min) · 19:30 Quiz (1 h) · gap · 21:00 Late (1 h)
    private val row = listOf(
        show("Film", six - hour, 120),
        show("News", six + hour, 30),
        show("Quiz", six + 1.5 * hour, 60),
        show("Late", six + 3 * hour, 60),
    )

    @Test fun cellsAreProgrammesOrHalfHourGapsBetweenThem() {
        assertEquals("Film", GuideNavigation.cell(row, six + 600).programme?.title)
        val gap = GuideNavigation.cell(row, six + 2.6 * hour)
        assertNull(gap.programme)
        assertEquals(six + 2.5 * hour, gap.start)
        assertEquals(six + 3 * hour, gap.stop)
        // A row with no guide is all half-hour gaps.
        assertEquals(GuideCell(six, six + SLOT, null), GuideNavigation.cell(emptyList(), six + 60))
    }

    @Test fun rightGoesToTheNextProgrammeAndMovesTheGridOnPastTheEdge() {
        var cursor = GuideCursor(0, six + 600, six)
        cursor = GuideNavigation.right(cursor, row, window, Double.MAX_VALUE)!!
        assertEquals(six + hour, cursor.time) // News, still on screen
        assertEquals(six, cursor.windowStart)
        cursor = GuideNavigation.right(cursor, row, window, Double.MAX_VALUE)!!
        assertEquals(six + 1.5 * hour, cursor.time) // Quiz starts at the right edge: the grid moves on
        assertEquals(six + 1.5 * hour, cursor.windowStart)
        cursor = GuideNavigation.right(cursor, row, window, Double.MAX_VALUE)!!
        assertEquals(six + 2.5 * hour, cursor.time) // the gap after Quiz
        assertNull(GuideNavigation.right(cursor, row, window, maxTime = six + 3 * hour))
    }

    @Test fun leftShowsTheEndOfAProgrammeThatStartedOffScreen() {
        // On News at 19:00 with the grid starting 18:00: Film started at 17:00, off screen.
        var cursor = GuideCursor(0, six + hour, six)
        cursor = GuideNavigation.left(cursor, row, window, minTime = 0.0)!!
        assertEquals(six, cursor.time) // Film, highlighted from the left edge
        assertEquals(six, cursor.windowStart)
        // Left again: the grid moves back to show Film whole.
        cursor = GuideNavigation.left(cursor, row, window, minTime = 0.0)!!
        assertEquals(six - hour, cursor.windowStart)
        assertEquals(six - hour, cursor.time)
        // From Quiz at the left edge, News is wholly off screen: the grid moves back to show it.
        val back = GuideNavigation.left(GuideCursor(0, six + 1.5 * hour, six + 1.5 * hour), row, window, minTime = 0.0)!!
        assertEquals(GuideCursor(0, six + hour, six + hour), back)
        // Before the guide's first day there's nothing.
        assertNull(GuideNavigation.left(GuideCursor(0, six, six), row, window, minTime = six))
    }

    @Test fun upAndDownKeepTheTimeAndStopAtTheEnds() {
        val cursor = GuideCursor(3, six + 600, six)
        assertEquals(GuideCursor(4, six + 600, six), GuideNavigation.move(cursor, 1, rows = 5))
        assertEquals(4, GuideNavigation.move(cursor, 9, rows = 5).row)
        assertEquals(0, GuideNavigation.move(cursor, -9, rows = 5).row)
        assertEquals(0, GuideNavigation.move(GuideCursor(0, six, six), 1, rows = 0).row)
    }

    @Test fun daysMoveTheGridAndTheHighlightTogether() {
        val cursor = GuideCursor(2, six + 600, six)
        val tomorrow = GuideNavigation.day(cursor, 1, minTime = 0.0, maxTime = Double.MAX_VALUE)
        assertEquals(six + 86_400 + 600, tomorrow.time)
        assertEquals(six + 86_400, tomorrow.windowStart)
        // Past the guide's last day it stops at the end.
        val capped = GuideNavigation.day(cursor, 1, minTime = 0.0, maxTime = six + hour)
        assertEquals(six + hour - 1, capped.time)
        assertEquals(capped.windowStart + 600, capped.time)
    }

    @Test fun nowAndChannelNumbers() {
        assertEquals(GuideCursor(1, six + 700, six), GuideNavigation.now(GuideCursor(1, 0.0, 0.0), six + 700))
        val numbers = listOf(1, 5, null, 101, 20)
        assertEquals(3, GuideNavigation.rowForNumber(numbers, 101))
        assertEquals(4, GuideNavigation.rowForNumber(numbers, 7)) // no 7: the next one up, 20
        assertNull(GuideNavigation.rowForNumber(numbers, 500))
    }

    @Test fun holdingOkIsReportedOnRelease() {
        val press = PressTracker()
        assertEquals(PressTracker.Result.None, press.ok(keyDown = true, repeatCount = 0))
        assertEquals(PressTracker.Result.Click, press.ok(keyDown = false, repeatCount = 0))
        press.ok(keyDown = true, repeatCount = 0)
        assertEquals(PressTracker.Result.None, press.ok(keyDown = true, repeatCount = 1))
        assertEquals(PressTracker.Result.LongClick, press.ok(keyDown = false, repeatCount = 0))
        // A release whose press went to something else is ignored.
        assertEquals(PressTracker.Result.None, press.ok(keyDown = false, repeatCount = 0))
    }
}
