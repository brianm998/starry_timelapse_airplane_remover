package com.star.desktop.engine

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class FramingTest {

    @Test
    fun roundTrip() {
        val payloads = listOf(
            ByteArray(0),
            byteArrayOf(1, 2, 3),
            ByteArray(1000) { (it % 256).toByte() },
        )
        val out = ByteArrayOutputStream()
        for (p in payloads) Framing.writeFrame(out, p)
        val input = ByteArrayInputStream(out.toByteArray())
        for (p in payloads) {
            assertContentEquals(p, Framing.readFrame(input))
        }
        assertNull(Framing.readFrame(input), "clean EOF at frame boundary should be null")
    }

    @Test
    fun bigEndianLengthHeader() {
        val encoded = Framing.encode(byteArrayOf(0xAA.toByte(), 0xBB.toByte()))
        // length 2 → 00 00 00 02
        assertEquals(0, encoded[0].toInt())
        assertEquals(0, encoded[1].toInt())
        assertEquals(0, encoded[2].toInt())
        assertEquals(2, encoded[3].toInt())
        assertEquals(0xAA.toByte(), encoded[4])
        assertEquals(0xBB.toByte(), encoded[5])
    }

    @Test
    fun truncatedHeaderThrows() {
        val input = ByteArrayInputStream(byteArrayOf(0, 0)) // only 2 of 4 header bytes
        assertFailsWith<EOFException> { Framing.readFrame(input) }
    }

    @Test
    fun truncatedBodyThrows() {
        // header says 10 bytes, only 3 present
        val input = ByteArrayInputStream(byteArrayOf(0, 0, 0, 10, 1, 2, 3))
        assertFailsWith<EOFException> { Framing.readFrame(input) }
    }
}
