package com.star.desktop.domain

/**
 * What picking a run back up does about the questions around a run (the critical warning's Restart Now, the engine restart), as the gui's
 * `restartProcessing` does. A resume is the press of the button the user already made, so it asks nothing before it starts; it still ends
 * like any other run.
 */
object ResumedRun {
    /**
     * Whether the run ends with "render a video?": yes unless the user has turned the render prompts off. It is never answered in advance, so
     * nothing renders unasked (S3: the desktop cleared the question, and a resumed run ended without one).
     */
    fun asksAboutRenderingAtTheEnd(skipRenderPrompts: Boolean): Boolean = !skipRenderPrompts

    /**
     * Whether the "where this sequence left off" panel goes up over the sequence as it opens. It is for a sequence opened to look at; one
     * opened to carry on is about to run, and the panel stayed over the run (S2).
     */
    fun showsProgressPanel(resuming: Boolean): Boolean = !resuming
}
