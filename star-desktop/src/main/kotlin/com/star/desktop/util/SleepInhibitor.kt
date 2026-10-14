package com.star.desktop.util

/**
 * Holds off the system's idle sleep while a sequence is open, so that a long run is not cut off by the machine going to sleep (the macOS app does
 * the same with `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`). Only idle sleep: the screen may still turn off, and the user can still
 * put the machine to sleep.
 *
 * Best effort. Each system has a command that holds the request for as long as it runs; one is started to acquire and stopped to release. It is
 * given this process's id to watch, so that it ends if the app does without releasing (a crash, a kill), and the machine is not kept awake by
 * something that is no longer there. If the command is missing or will not start the app goes on without, and says so in the log.
 */
class SleepInhibitor(
    private val osName: String = System.getProperty("os.name").orEmpty(),
    private val pid: Long = ProcessHandle.current().pid(),
    private val start: (List<String>) -> Process? = ::startProcess,
) {
    private var holder: Process? = null

    /** Whether idle sleep is being held off now. */
    @get:Synchronized val isHolding: Boolean get() = holder?.isAlive == true

    /** Start holding. Does nothing if it already is; false if there is no way to on this system or it would not start. */
    @Synchronized fun acquire(): Boolean {
        if (isHolding) return true
        val command = commandFor(osName, pid) ?: run {
            Log.d("Sleep") { "no way to hold off idle sleep on '$osName'" }
            return false
        }
        val process = start(command)
        if (process == null) {
            Log.w("Sleep") { "could not hold off idle sleep with ${command.first()}" }
            return false
        }
        holder = process
        Log.d("Sleep") { "holding off idle sleep (${command.first()})" }
        return true
    }

    /** Let the system sleep when it would. */
    @Synchronized fun release() {
        holder?.let {
            runCatching { it.destroy() }
            Log.d("Sleep") { "idle sleep is allowed again" }
        }
        holder = null
    }

    companion object {
        /** The command that holds idle sleep off until process [pid] is gone, or null for a system there is none for. */
        fun commandFor(osName: String, pid: Long): List<String>? {
            val os = osName.lowercase()
            return when {
                // -i: prevent the system from idle sleeping; -w: for as long as that process runs
                "mac" in os || "darwin" in os -> listOf("caffeinate", "-i", "-w", pid.toString())
                // The thread that sets ES_CONTINUOUS | ES_SYSTEM_REQUIRED holds the request until it ends, so a helper PowerShell sets it and waits for
                // this process; stopping the helper, or this process going, ends the request. (No native library is needed for the call. The flags are written
                // in decimal because PowerShell reads 0x80000001 as a negative number, which a uint parameter refuses.)
                "win" in os -> listOf(
                    "powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command",
                    "Add-Type -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern uint SetThreadExecutionState(uint flags);' " +
                        "-Name Power -Namespace Star; [Star.Power]::SetThreadExecutionState([uint32]2147483649) | Out-Null; " +
                        "Wait-Process -Id $pid -ErrorAction SilentlyContinue",
                )
                // systemd-inhibit holds the lock while its command runs; `tail --pid` is that command, and ends when this process does.
                "nux" in os || "nix" in os || "linux" in os ->
                    listOf("systemd-inhibit", "--what=idle", "--who=Star", "--why=Processing a sequence", "--mode=block", "tail", "--pid=$pid", "-f", "/dev/null")
                else -> null
            }
        }

        private fun startProcess(command: List<String>): Process? = try {
            ProcessBuilder(command)
                .redirectInput(ProcessBuilder.Redirect.from(java.io.File(if (System.getProperty("os.name").orEmpty().lowercase().contains("win")) "NUL" else "/dev/null")))
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
        } catch (e: java.io.IOException) {
            null
        }
    }
}
