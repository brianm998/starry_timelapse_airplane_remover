# Star demo video 2 — Keeping the meteors (Auto-Selective)

Follow-up to video 1. Assumes the viewer has seen it: the import, the setup
questions, the horizon painter, the processing window and rendering are all covered
there, so here they get a quick montage and the time goes to finding the meteors.

Target length: 8–10 minutes after editing. **[CUT]** marks waits to cut or speed up.
**ON SCREEN** is what you do, **SAY** is spoken dialog — say it in your own words.

---

## Before you hit record

- Pick a **static** sequence that has **at least one clear meteor** and plenty of
  airplanes and satellites. Know the frame numbers of the meteor(s) before you start
  (scrub it once in Star or any player), so you're not hunting on camera.
- Ideally, also have one frame where Star gets it *wrong* — a meteor it removed, or
  a satellite flare it kept — so section 4 has a real correction to show. Run the
  sequence once beforehand to find one; that run doubles as your backup copy if
  processing is slow on the day.
- Quit and reopen Star so it starts at the welcome screen.

---

## 0. Cold open (headshot, ~20 s)

**SAY:**
> In the last video, Star removed everything that flashed across the sky —
> airplanes, satellites, and meteors too. But a meteor is usually the one thing you
> *want* in your timelapse. This time I'll get rid of the airplanes, the satellites
> and the cars, and bring the meteors back.

## 1. The quick part — same as last time (montage, ~45 s)

**ON SCREEN:** Load Video → Import Video sheet → TIFF 16 bit → Import. **[CUT]**
Horizon? **Yes**. Moving? **Static**. Select the horizon yourself? **Yes** → brush
along the horizon → Return.

**SAY (over the montage):**
> I'm starting exactly the way I did last time: import the video, tell Star there's
> a horizon and the camera didn't move, and paint the horizon in. If you haven't
> seen that part yet, the first video goes through it step by step.

## 2. The one switch that changes everything

**ON SCREEN:** "What do you want Star to remove?" Switch **Meteors off**. Leave
Airplanes, Satellites and Cars on. Point at the description, which changes to:
"Star will run in auto mode, replacing all bad pixels. It will then classify the
bright signals in every frame and restore the original pixels of the ones it decides
to keep, such as meteors…"

**SAY:**
> Here's the only difference from last time. I'm switching meteors off. Watch the
> description change: Star is now in a mode called Auto-Selective.
>
> It works in two passes. First it does exactly what automatic mode did — it cleans
> every frame by replacing every pixel that's brighter than it should be. Then it
> goes back and looks at each of those bright things on its own: what shape is it,
> how long, how bright, does it line up with something in the next frame? A
> decision tree — trained on lots of hand-sorted examples — decides whether it looks
> like something to keep. For anything it keeps, it puts the original pixels back.

**ON SCREEN:** Keep pointing at the last sentence of the description.

**SAY:**
> And Star is honest about this: it can't yet reliably tell an airplane, a satellite
> and a meteor apart every time. So the job in this video is to check what it did,
> and fix anything it got wrong. That's quick, and I'll show you how to go straight
> to the frames that matter.

**ON SCREEN:** **Start Processing** → render-after-processing prompt → **No**.
Dismiss the processing window ("Keep processing and go back to the frames").
**[CUT]** to processing finished (or to the backup copy).

## 3. Finding the meteors

**ON SCREEN:** Press **E** for Edit mode. Go to a frame with nothing special in it
first. Show the coloured outlines over the frame and the outlier counts in the side
panel (✕ removed, ✓ kept, ? undecided).

**SAY:**
> Every bright thing Star found is outlined. Red means Star painted it out. Green
> means Star decided to keep it. Over here it counts them for this frame — removed,
> kept, and undecided.

**ON SCREEN:** In the right panel, set **Fast Advancement Type** to **To next
negative** ("Skip to next frame with a negative outlier"). Press **x**
(fast forward) — Star jumps straight to the first frame with something kept.

**SAY:**
> In a video with a thousand frames, I'm not going to look at every one. Fast
> advancement lets me jump to just the interesting frames. "Negative" here means
> "something Star decided to keep" — so every time I press X, I land on the next
> frame where Star kept something.

**ON SCREEN:** Land on the meteor frame. Zoom in on the green outline. Flip the view
between **original frame**, **auto processed** (everything removed) and **auto
processed with selection** (meteor restored), or **final processed frame**.

**SAY:**
> And here's the meteor. Here's the original frame… here's what full automatic mode
> would have given me — gone… and here's Auto-Selective, with the meteor put back
> and the airplane right next to it still removed.

**ON SCREEN (optional):** Press **G** for Grid mode to show thumbnails of many frames
at once; scan for the meteor visually, click it to go back.

**SAY (optional):**
> If you'd rather see it with your own eyes, grid mode shows you lots of frames at
> once, and a meteor tends to jump right out.

## 4. Fixing what Star got wrong

**ON SCREEN — a meteor Star removed:** Go to that frame (fast advancement **To next
positive** helps if you don't know where it is, but you'll know from your prep).
It's outlined red. Press **2** (Keep tool), click the meteor. It turns green.

**SAY:**
> Here's one Star got wrong — that's a meteor, but it painted it out. I pick the Keep
> tool, click it, and it's green: Star will put it back.

**ON SCREEN — something Star kept that should go:** On a frame with a green
satellite flare or airplane segment, press **1** (Remove tool), click it — red.

**SAY:**
> And it works the other way too. This one is a satellite flaring — it's bright and
> short, so it looked like a meteor. Remove tool, click, and it's gone. You can also
> drag a box over several at once.

**ON SCREEN:** Wait a few seconds (Star saves the frame on its own) or press **R**
to render this frame now. Switch to **final processed frame** to show the result.

**SAY:**
> Star rewrites the frame by itself a few seconds after I stop changing it, or I can
> press R to do it right now. And there's the corrected frame.

**ON SCREEN:** Press **x** a few more times to step through the remaining kept
frames; say "fine" / fix as needed.

**SAY:**
> I keep going through the frames Star kept. Most are right, and when they're not,
> it's one click.

## 5. Play it back, render it

**ON SCREEN:** Play the final frames (Preview First from the prompt, or Play with
space from a few seconds before the meteor). Pause on the meteor.

**SAY:**
> Let's watch it. Airplanes gone, satellites gone… and there's the meteor, exactly
> as the camera caught it.

**ON SCREEN:** **Render Video** → same sheet as video 1 → **Render**. **[CUT]**
→ Reveal In Finder → play the meteor moment full screen.

**SAY:**
> Rendering works exactly the way I showed last time.

## 6. Close (headshot, ~20 s)

**SAY:**
> That's Auto-Selective: let Star clean everything, let it bring back what looks
> worth keeping, then spend a couple of minutes checking the frames it kept. If you
> want complete control — deciding exactly which pixels get replaced on every frame
> — that's selective mode, and that's the next video.

---

## Edit checklist

- Sync screen and camera on the clap.
- Zoom in hard on the meteor and on each correction; meteors are small at full
  frame.
- A slow before/after wipe (original → auto processed → with selection) on the
  meteor frame makes the best thumbnail.
