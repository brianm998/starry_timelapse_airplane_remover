# Star demo video 1 — Full Automatic (static timelapse)

Target length: 8–12 minutes after editing. Long waits (import, processing, render)
are cut or sped up in the edit; each one is marked **[CUT]** below.

Two columns per beat: **ON SCREEN** is what you do, **SAY** is spoken dialog. Treat the
dialog as a starting point — say it in your own words, it will sound better.

Button and dialog names below are taken from the gui's English string catalogue, so
they should match what is on screen. Rehearse once anyway: anything marked
**(check)** is a spot that could not be confirmed from the code alone.

---

## Before you hit record

- Pick a **static** sequence with obvious airplane and satellite trails, a clear
  horizon (trees, mountains or a building line), and ideally no meteors — meteors
  belong in video 2.
- Have the source **video file** (not frames) somewhere with lots of free disk space
  next to it; Star writes the frames and its temp files beside it.
- Make a second, already-processed copy of the same sequence (run it once
  beforehand). If processing takes longer than you want to film, you can cut to that
  copy for steps 5 and 6 and nobody will know.
- Quit Star and reopen it so it starts at the welcome screen.
- In Star's preferences, make sure the processing-steps window is enabled (the
  setting described as "a window showing each processing step and the alignment
  information appears when processing starts"), and that **Skip Render Prompt After
  Processing** is *off* — the script uses both.

---

## 0. Cold open (headshot only, ~20 s)

**SAY:**
> If you've ever shot a night-sky timelapse, you know the problem: you set up for
> hours to catch the stars, and half your frames have an airplane or a satellite
> streaking straight through them. Star is a free app that removes those trails
> for you. In this video I'll take a timelapse straight off the camera, run it
> through Star's fully automatic mode, and render out a clean video — start to
> finish.

## 1. Decoding the video into an image sequence

**ON SCREEN:** Star's welcome screen ("Welcome to Star v…"). Click **Load Video**
(or drop the video file onto the window). The **Import Video** sheet appears.

**SAY:**
> Star works on individual frames, not on the video itself, so the first thing it
> does is turn the video into one image per frame.

**ON SCREEN:** Point at the **Frame format** choices: JPEG, TIFF 8 bit, TIFF 16 bit
(best quality). Point at the disk-space estimate line.

**SAY:**
> You get a choice of format here. Sixteen-bit TIFF keeps the most detail from the
> original — that's what I use — but it's big; Star tells you right here how much
> disk space it's going to need. JPEG is much smaller if you're tight on space.
> If you shot stills instead of video, you skip this step entirely and just load
> the folder of images.

**ON SCREEN:** Pick **TIFF, 16 bit**, click **Import**. **[CUT]** the wait.

## 2. The setup questions, and how Star works

The first questions are quick yes/no screens.

**ON SCREEN:** "Does this video include a horizon?" → **Yes**.

**SAY:**
> Star asks a few questions about the shot. First: is there a horizon? Star treats
> the sky and the ground separately, because they move differently — the stars
> rotate across the sky over the night, but the ground stays put.

**ON SCREEN:** "Was the camera moving during this video, or was it stationary on a
tripod the entire time?" → **Static**.

**SAY:**
> This one was on a tripod the whole time, so it's a static shot. That's the
> easiest case for Star and it gives the best results, because it can build a
> clean picture of the ground as well as the sky.

**ON SCREEN:** "Do you want to select the horizon yourself?" — **don't answer yet.**
Pause here for the explanation, then go to section 3. (The removal choices come
*after* the horizon — see section 3b.)

**SAY — the "how it works" explanation (keep the frame on screen while you talk):**
> Before we go on, here's the idea behind Star, because it explains every choice
> you'll make.
>
> A timelapse is a long run of almost identical pictures. From one frame to the
> next, the stars shift a tiny bit and the ground doesn't move at all. An
> airplane is different: it's only in any given spot for one frame, maybe two.
>
> So for every frame, Star takes the frames on either side of it and lines them
> up — the sky is lined up on the stars, and the ground is lined up on the ground.
> Then for every single pixel it asks: what does this spot look like in all those
> neighbouring frames? It throws out the unusually bright values — which is exactly
> what an airplane or satellite is — and takes what's left. That gives Star a clean
> version of the frame, what the sky looked like with nothing passing through it.
>
> Then it compares your real frame to that clean version. Anything much brighter
> than it should be gets painted over, blending in pixels from the clean version
> so you can't see a seam.
>
> That's also why Star needs to know where the horizon is: the sky and the ground
> are lined up differently, and it has to know which pixels are which.

## 3. Selecting the horizon by hand

**ON SCREEN:** On "Do you want to select the horizon yourself?" click **Yes**. The
horizon painter opens with its instructions overlay.

**SAY:**
> Star can find the horizon on its own, but on a static shot it's worth spending a
> minute doing it yourself. You only do it once — for a static video, Star applies
> the same horizon to every frame — and it makes processing both faster and more
> accurate.

**ON SCREEN:** If the first frame shows the horizon poorly, scrub to one that shows
it well.

**SAY:**
> Pick any frame where the horizon is easy to see. This one's good.

**ON SCREEN:** Brush along the horizon line from the left edge of the frame to the
right. Star then auto-fills the sky down to the horizon it finds.

**SAY:**
> All I do is brush along the horizon itself, all the way across the frame. Once
> I've covered the full width, Star fills in the sky for me, and stops where it
> thinks the ground begins.

**ON SCREEN:** Zoom in on a tricky part (tree tops, a gap between hills). Fix it with
the brush: **P** paints sky (adds to the selection), **E** erases sky (removes from
the selection). Use **[** and **]** to shrink and grow the brush, and **R** to reset
and start over if it goes badly.

**SAY:**
> If it's not quite right somewhere — like these tree tops — I just touch it up.
> Paint to add sky, erase to take it away, and the square-bracket keys make the
> brush smaller or bigger. It doesn't need to be perfect to the pixel; it just
> needs to be right where it matters.

**ON SCREEN:** Press **Return** — "Save horizon and continue".

### 3b. What to remove — choosing Automatic

**ON SCREEN:** "What do you want Star to remove?" Leave **Airplanes, Satellites,
Meteors, Cars** all switched on. Point at the description text underneath:
"Star will run in automatic mode, replacing all bad pixels…"

**SAY:**
> Now Star asks what it should remove. I'm leaving everything on — airplanes,
> satellites, meteors, cars. With everything on, Star runs in fully automatic
> mode: it replaces every pixel that's brighter than it should be, and if all goes
> well, you won't have to touch a single frame.
>
> If you'd rather keep the meteors, you'd switch that one off, and Star would run
> a different mode that puts them back — that's the next video in this series.

**ON SCREEN (optional, only if it's showing a recommendation):** the
**Speed vs. Sharpness** section — Best quality / Best balance / Fastest.

**SAY (optional):**
> Down here is a speed-versus-sharpness setting. Star has to line up the stars in
> every frame, and doing that from smaller copies is much faster at the cost of a
> little sharpness. Best quality is the default, and Star tells you if your
> computer would benefit from changing it.

**ON SCREEN:** Click **Start Processing**. The "Render video after processing?"
prompt appears → click **No**.

**SAY:**
> Star can render the final video automatically when it's done, but I'm saying no,
> because I want to look at the result first. I'll show you how to render it at
> the end.

## 4. Watching processing — and getting out of the way

**ON SCREEN:** The **Processing Frames** window appears, with the **Processing Steps**
list and progress per step. Hover over a step to show its help text.

**SAY:**
> This window shows everything Star is doing. Each row is one stage: finding the
> horizon in every frame, finding the stars, working out how to line each frame up
> with its neighbours — for the sky and for the ground — and finally building the
> cleaned frames. The star-finding step is nearly always the slowest one.

**ON SCREEN (optional):** Toggle **Show alignment results** to show the star and earth
alignment deviation graphs.

**SAY (optional):**
> If you're curious, you can see how well each frame lined up with its neighbours.
> Flat and low is good.

**ON SCREEN:** Click **Dismiss** ("Keep processing and go back to the frames").

**SAY:**
> You don't have to sit and watch this. Dismissing it doesn't stop anything —
> processing keeps going in the background, and I can look at frames as they
> finish.

**ON SCREEN:** In the main window, scrub to a frame that has finished and has a trail.
Switch the view between **original frame** and **final processed frame** a few
times. Show the filmstrip/progress filling in.

**SAY:**
> Here's a finished frame. This is the original, with the airplane… and here's what
> Star made of it. Gone. And the stars and the ground around it are untouched.

**[CUT]** the rest of processing (or cut to the pre-processed copy).

## 5. Playing the result inside Star

**ON SCREEN:** When processing finishes the **Processing complete** / "Render video
now?" prompt appears. Click **Preview First**.

**SAY:**
> Processing is done, and Star offers to render the video. Before I do, I'll use
> Preview First, which plays all the finished frames right here in the app.

**ON SCREEN:** Let it play. Pause (space) on a frame where a trail used to be, flip
back to the original view, then forward again. **w** plays in reverse.

**SAY:**
> This is the real output, playing at the video's frame rate. If anything looks
> wrong, this is the time to catch it — before spending time rendering. Space
> plays and pauses, and I can always flip back to the original to compare.

## 6. Rendering the final video

**ON SCREEN:** Open **Render Video** — from the prompt's **Yes**, or later from the
**Render Video** button in the sequence progress panel (check where you prefer to
show it). The "Render video from N frames" sheet appears.

**SAY:**
> Now the video itself. Star builds it from the finished frames.

**ON SCREEN:** Walk through the sheet: **Container**, **Codec**, **Encoder**,
**Pixel format / bit depth**, **Resolution** (Original), **Frame rate**, and the
**Total length** it computes.

**SAY:**
> You choose the container and codec here — ProRes if you're going to edit it
> further, H.264 or HEVC if it's going straight to the web. Resolution defaults
> to the original size, and the frame rate is the same as the video you started
> with, so the length matches.

**ON SCREEN:** Click **Render**. **[CUT]** the wait. On "Successfully Rendered …",
click **Reveal In Finder**, open the video, play a few seconds full screen.

**SAY:**
> And there it is — the whole night, with no airplanes.

## 7. Close (headshot, ~20 s)

**SAY:**
> That's fully automatic mode: import, tell Star about the shot, select the horizon,
> and let it go. In the next video I'll show how to keep the meteors while still
> removing the airplanes, and after that, full selective mode, where you decide
> exactly which pixels get replaced. Links are below.

---

## Edit checklist

- Sync screen and camera on the clap at the start of each take.
- Speed-ramp or hard-cut: video import, processing, render.
- Zoom (crop-in) the screen recording on: Frame format choices, the horizon
  brushing, the before/after flip, the render sheet.
- Headshot full-frame for sections 0, the "how it works" explanation, and 7;
  picture-in-picture corner the rest of the time.
