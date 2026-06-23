package com.star.desktop.util

/**
 * Minimal leveled logger to stderr. Keeps the client off `stdout` entirely (which is reserved for
 * nothing in the client, but disciplined logging avoids the v1 client's scattered `println` spew).
 */
object Log {
    enum class Level { DEBUG, INFO, WARN, ERROR }

    @Volatile var level: Level = Level.INFO

    fun d(tag: String, msg: () -> String) = log(Level.DEBUG, tag, msg)
    fun i(tag: String, msg: () -> String) = log(Level.INFO, tag, msg)
    fun w(tag: String, msg: () -> String) = log(Level.WARN, tag, msg)
    fun e(tag: String, t: Throwable? = null, msg: () -> String) {
        log(Level.ERROR, tag, msg)
        t?.let { System.err.println(it.stackTraceToString()) }
    }

    private inline fun log(lvl: Level, tag: String, msg: () -> String) {
        if (lvl.ordinal >= level.ordinal) System.err.println("[$tag/${lvl.name}] ${msg()}")
    }
}
