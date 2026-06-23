package com.star.desktop.engine

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream

/**
 * Wire framing for the stard stdio protocol.
 *
 * Each message is a **4-byte big-endian unsigned length** followed by exactly that many
 * payload bytes (a serialized `star.v1.Envelope`). This mirrors the daemon's
 * `StarDaemonMessages/Framing.swift` and `StdioTransport.swift` byte-for-byte.
 *
 * These helpers are intentionally free of any connection/coroutine state so they can be
 * exercised directly in unit tests.
 */
object Framing {

    /** Prepend the 4-byte big-endian length header to [payload]. */
    fun encode(payload: ByteArray): ByteArray {
        val out = ByteArray(4 + payload.size)
        val n = payload.size
        out[0] = (n ushr 24).toByte()
        out[1] = (n ushr 16).toByte()
        out[2] = (n ushr 8).toByte()
        out[3] = n.toByte()
        System.arraycopy(payload, 0, out, 4, payload.size)
        return out
    }

    /**
     * Read one frame from [input]: a 4-byte big-endian length, then exactly that many bytes.
     *
     * Returns `null` on a clean EOF at a frame boundary (no bytes of a new frame yet read).
     * Throws [EOFException] if EOF arrives *mid-frame* — i.e. the stream is truncated/desynced;
     * the caller must tear the connection down rather than try to resync.
     */
    fun readFrame(input: InputStream): ByteArray? {
        val header = ByteArray(4)
        // A clean EOF before any header byte → null. Partial header → truncation.
        var read = 0
        while (read < 4) {
            val n = input.read(header, read, 4 - read)
            if (n < 0) {
                if (read == 0) return null
                throw EOFException("EOF after $read of 4 header bytes (truncated frame)")
            }
            read += n
        }
        val len =
            ((header[0].toInt() and 0xFF) shl 24) or
                ((header[1].toInt() and 0xFF) shl 16) or
                ((header[2].toInt() and 0xFF) shl 8) or
                (header[3].toInt() and 0xFF)
        if (len < 0) throw EOFException("implausible frame length $len (corrupt stream)")
        if (len == 0) return ByteArray(0)

        val body = ByteArray(len)
        var bodyRead = 0
        while (bodyRead < len) {
            val n = input.read(body, bodyRead, len - bodyRead)
            if (n < 0) throw EOFException("EOF after $bodyRead of $len body bytes (truncated frame)")
            bodyRead += n
        }
        return body
    }

    /** Write one framed message to [output] and flush. */
    fun writeFrame(output: OutputStream, payload: ByteArray) {
        output.write(encode(payload))
        output.flush()
    }
}
