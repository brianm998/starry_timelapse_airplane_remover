package com.star.desktop.domain

import com.star.proto.BoundingBox
import com.star.proto.OutlierGroup
import kotlin.test.Test
import kotlin.test.assertEquals

class OutlierBoxTest {
    private fun group(id: Int, minX: Int, minY: Int, maxX: Int, maxY: Int, size: Long) = OutlierGroup.newBuilder()
        .setId(id).setSize(size)
        .setBounds(BoundingBox.newBuilder().setMinX(minX).setMinY(minY).setMaxX(maxX).setMaxY(maxY))
        .build()

    private val groups = listOf(
        group(1, 10, 10, 20, 20, 50),
        group(2, 30, 30, 60, 60, 400),
        group(3, 15, 15, 100, 100, 900),   // sticks out of a small box
        group(4, 12, 12, 14, 14, 3),
    )

    /** The box takes a group only if the whole of it is inside (a group partly in is left alone), largest first. */
    @Test fun onlyGroupsWhollyInsideAreSelectedLargestFirst() {
        assertEquals(listOf(2, 1, 4), groupsInsideBox(groups, 0f, 0f, 70f, 70f).map { it.id })
    }

    @Test fun theCornersMayBeGivenInEitherOrder() {
        assertEquals(listOf(2, 1, 4), groupsInsideBox(groups, 70f, 70f, 0f, 0f).map { it.id })
        assertEquals(listOf(2, 1, 4), groupsInsideBox(groups, 70f, 0f, 0f, 70f).map { it.id })
    }

    /** A box inside group 1 holds only the small group within it; group 1, which sticks out, is not taken. */
    @Test fun aGroupThatSticksOutIsNotSelected() {
        assertEquals(listOf(4), groupsInsideBox(groups, 11f, 11f, 19f, 19f).map { it.id })
        assertEquals(emptyList(), groupsInsideBox(groups, 70f, 70f, 90f, 90f).map { it.id })
    }

    /** The edge counts as inside, as in StarCore's BoundingBox.contains. */
    @Test fun aGroupTouchingTheBoxEdgeIsInside() {
        assertEquals(listOf(1, 4), groupsInsideBox(groups, 10f, 10f, 20f, 20f).map { it.id })
    }

    @Test fun fractionsAreTruncatedLikeStarCoreDoes() {
        // 19.9 truncates to 19: the group reaching 20 is no longer inside.
        assertEquals(listOf(4), groupsInsideBox(groups, 10f, 10f, 19.9f, 19.9f).map { it.id })
    }
}
