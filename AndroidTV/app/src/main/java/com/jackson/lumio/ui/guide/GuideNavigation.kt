package com.jackson.lumio.ui.guide

import com.jackson.lumio.core.Programme
import kotlin.math.ceil
import kotlin.math.floor

/**
 * Where the guide's highlight is. [time] is the moment the highlight sits on, which keeps it lined
 * up when moving up and down (the programme on at that time in the next row is highlighted).
 * [windowStart] is the time at the left edge of the grid. Times are seconds since 1970.
 *
 * Kept so that `windowStart <= time < windowStart + window`: the highlight is always on screen.
 */
data class GuideCursor(val row: Int, val time: Double, val windowStart: Double)

/**
 * A highlightable cell: a programme, or a gap with no guide information (cut into half-hour slots
 * and squeezed between the programmes either side).
 */
data class GuideCell(val start: Double, val stop: Double, val programme: Programme?)

/** How the remote moves through the guide. No Android here, so the tests run anywhere. */
object GuideNavigation {
    /** The grid's time marks, and the size of a gap's cell. */
    const val SLOT = 1800.0
    const val DAY = 86_400.0

    fun floorSlot(time: Double): Double = floor(time / SLOT) * SLOT

    fun ceilSlot(time: Double): Double = ceil(time / SLOT) * SLOT

    /** The cell at [time] in a row whose programmes are [programmes] (in order). */
    fun cell(programmes: List<Programme>, time: Double): GuideCell {
        programmes.firstOrNull { it.start <= time && it.stop > time }?.let { return GuideCell(it.start, it.stop, it) }
        val slot = floorSlot(time)
        val before = programmes.lastOrNull { it.stop <= time }?.stop ?: slot
        val after = programmes.firstOrNull { it.start > time }?.start ?: (slot + SLOT)
        return GuideCell(maxOf(slot, before), minOf(slot + SLOT, after), null)
    }

    /** The next cell along. Moves the grid on when it goes past the right edge. Null at [maxTime]. */
    fun right(cursor: GuideCursor, programmes: List<Programme>, window: Double, maxTime: Double): GuideCursor? {
        val target = cell(programmes, cursor.time).stop
        if (target >= maxTime) return null
        val start = if (target >= cursor.windowStart + window) floorSlot(target) else cursor.windowStart
        return cursor.copy(time = target, windowStart = start)
    }

    /**
     * The cell before. A programme cut off at the left edge first has the grid moved back to its
     * start; one that's partly on screen is highlighted where it shows; one wholly off screen has
     * the grid moved back to show it (its end, when it's long). Null before [minTime].
     */
    fun left(cursor: GuideCursor, programmes: List<Programme>, window: Double, minTime: Double): GuideCursor? {
        val current = cell(programmes, cursor.time)
        if (current.start < cursor.windowStart) {
            val start = maxOf(floorSlot(current.start), floorSlot(minTime))
            if (start < cursor.windowStart) return cursor.copy(time = maxOf(current.start, start), windowStart = start)
        }
        val time = current.start - 1
        if (time < minTime) return null
        val previous = cell(programmes, time)
        if (previous.stop > cursor.windowStart) return cursor.copy(time = maxOf(previous.start, cursor.windowStart))
        val start = maxOf(floorSlot(previous.start), ceilSlot(previous.stop) - window, floorSlot(minTime))
        return cursor.copy(time = maxOf(previous.start, start), windowStart = start)
    }

    /** Up or down by [by] rows (a page with CH+/CH-), staying at the same time. */
    fun move(cursor: GuideCursor, by: Int, rows: Int): GuideCursor =
        cursor.copy(row = (cursor.row + by).coerceIn(0, maxOf(0, rows - 1)))

    /** The same time a day later or earlier, within the guide's days. */
    fun day(cursor: GuideCursor, by: Int, minTime: Double, maxTime: Double): GuideCursor {
        val time = (cursor.time + by * DAY).coerceIn(minTime, maxTime - 1)
        // The grid moves by as much as the highlight did, so the highlight stays where it was on screen.
        return cursor.copy(time = time, windowStart = cursor.windowStart + (time - cursor.time))
    }

    /** The grid at now, with the highlight on what's on. */
    fun now(cursor: GuideCursor, now: Double): GuideCursor = cursor.copy(time = now, windowStart = floorSlot(now))

    /** The row for a typed channel number: that number, or else the next one up. */
    fun rowForNumber(numbers: List<Int?>, number: Int): Int? =
        numbers.indexOf(number).takeIf { it >= 0 }
            ?: numbers.withIndex().filter { (it.value ?: -1) > number }.minByOrNull { it.value!! }?.index
}
