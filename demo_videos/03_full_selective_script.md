# Star demo video 3 — Full Selective mode

Stands on its own: it walks through import and setup again, but briefly, and says up
front that videos 1 and 2 cover the basics in more depth. The time goes to selective
mode — Star finds and classifies every bright thing, the decision tree makes the
first call, and you go through the video adjusting what gets replaced.

Target length: 12–15 minutes after editing. **[CUT]** marks waits to cut or speed
up. **ON SCREEN** is what you do, **SAY** is spoken dialog — say it in your own words.

---

## Before you hit record

- Pick a sequence where selective mode earns its keep: a **cloudy or hazy** night,
  bright lights on the ground, a meteor or two, or a satellite you want to keep.
  Automatic mode is fine on a clean, clear night; this video should show why you'd
  want more control.
- Run it once beforehand. Note 4–5 frames worth showing on camera:
  - a frame where the decision tree is clearly right (red airplane, untouched stars),
  - a frame with undecided (blue) groups,
  - a frame where the tree is wrong (a meteor it marked red, or cloud edge it marked
    for removal),
  - a group that is half airplane, half something else (for the Razor),
  - something that sits in the same place across many frames — a tower light, a
    house window — for the Multi tool.
  That run is also your backup copy if processing is slow on the day.
- Quit and reopen Star so it starts at the welcome screen.

---

## 0. Cold open (headshot, ~30 s)

**SAY:**
> Star is a free app that removes airplanes and satellites from night-sky
> timelapses. In this video I'm going to use its most hands-on mode, selective
> mode, where Star does all the finding and sorting, and I get the final say on
> exactly which pixels get replaced.
>
> If you're new to Star, the first two videos in this series are a good place to
> start — one covers fully automatic mode, the other shows how to keep meteors — but
> you don't need them to follow this one.

## 1. Import and setup (~1.5 min)

**ON SCREEN:** **Load Video** → **Import Video** sheet → **TIFF, 16 bit** → **Import**.
**[CUT]**

**SAY:**
> Star works on individual frames, so it starts by turning the video into one image
> per frame. Sixteen-bit TIFF keeps the most detail. If you shot stills, you'd just
> load the folder instead.

**ON SCREEN:** Horizon? **Yes** → Moving? **Static** → Select the horizon yourself?
**Yes** → brush along the horizon across the full width; touch up with **P** / **E**,
**[** / **]** for brush size → **Return**.

**SAY:**
> A few quick questions about the shot. Star handles the sky and the ground
> separately — the stars move across the sky over the night, the ground doesn't —
> so it needs to know where the horizon is. On a static shot I just paint it once,
> and Star uses it for every frame.

## 2. How Star finds things, and choosing Selective

**ON SCREEN:** The "What do you want Star to remove?" screen. Leave it for a moment
while you explain.

**SAY — the "how it works" explanation:**
> Here's what happens under the hood, because in selective mode you'll be looking
> at it directly.
>
> For every frame, Star lines up the frames around it — the sky on the stars, the
> ground on the ground — and works out what each pixel *should* look like when
> nothing is passing through. Anything in the real frame that's a lot brighter than
> that is a candidate.
>
> Star then groups those bright pixels into blobs — it calls them outlier groups —
> and joins up the ones that form a line, the way an airplane trail does. Then each
> group goes through a decision tree. That's a classifier trained on lots of groups
> people have sorted by hand. It looks at things like the shape, how straight it is,
> how bright, how big, and whether something similar shows up in the neighbouring
> frames — and it votes: remove this, or keep it.
>
> In automatic mode, Star just acts on that. In selective mode, it shows you every
> decision first, and only replaces the pixels of the groups marked for removal.
> Everything else in the frame stays exactly as the camera recorded it.

**ON SCREEN:** Click **Advanced**. In the settings sheet, set the processing method to
**Selective**. (Optional: point at the **detection type** — Mild, Strong, Stronger,
Excessive.) Click **Process Now**.

**SAY:**
> To pick selective mode directly, I go into Advanced and switch the processing
> method to Selective.
>
> (Optional:) This detection setting controls how hard Star looks. Mild finds the
> big bright streaks and is fastest; the stronger settings find fainter things but
> give you more groups to look at.

**ON SCREEN:** The **Processing Frames** window. Point at the steps briefly, then
**Dismiss** ("Keep processing and go back to the frames"). **[CUT]** to processing
done (or the backup copy).

**SAY:**
> This window shows each stage as it runs. Dismissing it doesn't stop processing —
> I can start looking at frames as soon as they're done.

## 3. What the decision tree decided

**ON SCREEN:** Press **E** for Edit mode. Go to your "tree is clearly right" frame.
Show the coloured outlines and the outlier counts (✕ / ✓ / ?) in the side panel.

**SAY:**
> This is where selective mode lives. Every outlier group Star found is outlined.
> Red will be removed. Green will be kept. Blue means undecided — the tree didn't
> make a call. The panel counts them for this frame.
>
> Here the tree got it right: the airplane is red, and nothing else is touched.

**ON SCREEN:** Press **8** (Information tool), click the airplane group. The outlier
table / info window shows its details.

**SAY:**
> If I'm curious why, the Information tool shows me what Star measured about any
> group.

**ON SCREEN:** Flip the view mode between **original frame** and **final processed
frame** (or **selective processed**).

**SAY:**
> And here's the result: before… and after. Only the pixels inside that red group
> were replaced.

## 4. Scrubbing through and adjusting

**ON SCREEN:** In the right panel, set **Fast Advancement Type** to **To next
unknown**. Press **x** to jump to the next frame with undecided groups.

**SAY:**
> I don't have to check every frame by hand. Fast advancement lets me jump straight
> to the next frame that needs attention. Right now I'm jumping to frames with
> undecided groups. I can also jump to frames with something marked for removal, or
> something marked to keep, or just skip frames with nothing in them.

**ON SCREEN — deciding the undecided:** On that frame, press **1** (Remove), drag a
box over the blue airplane segments. Then **2** (Keep), click a blue group that's
really a star or cloud edge.

**SAY:**
> These two are clearly airplane — Remove tool, drag a box, they go red. This one is
> just the edge of a cloud, so Keep tool, click — green.

**ON SCREEN — fixing a wrong call:** Go to your "tree is wrong" frame. Keep the
meteor (or the cloud edge it marked red) with **2**.

**SAY:**
> And here the tree got one wrong. That's a meteor, and it's marked red. One click
> with Keep and it stays in the video.

**ON SCREEN — Razor:** On the mixed group, press **3** (Razor), drag a box around
just the airplane part. Then mark the remainder.

**SAY:**
> Sometimes a group is half airplane and half something I want to keep. The Razor
> cuts a group down to just what's inside the box I draw.

**ON SCREEN — Shovel and Trash (optional):** **4** Shovel: drag a box to throw away
and re-detect the groups in that area. **5** Trash, and toggle **Show Trash** to
show what Star already judged not worth looking at (yellow).

**SAY (optional):**
> The Shovel throws away what Star found in an area and looks again from scratch.
> And the trash is where Star puts things it's confident aren't worth removing —
> you can show it, and pull things back out if you need to.

**ON SCREEN — the same thing in many frames:** Go to the tower light / window frame.
Press **7** (Multi), click the group. The dialog offers to apply Keep or Remove to the
overlapping groups in other frames (all frames, from here to the end, from the start
to here…). Choose **Keep** for **all frames**.

**SAY:**
> This light on the hill is in every frame, and I want it left alone. Instead of
> clicking it a thousand times, the Multi tool applies my decision to the matching
> group in every other frame at once.

**ON SCREEN — whole-frame shortcuts:** On a busy frame, show **Actions** menu:
**Remove All** (**a**), **Keep All** (**k**), **Clear Undecided** (**u**),
**Decision Tree All**.

**SAY:**
> There are shortcuts for a whole frame too. A removes everything on this frame, K
> keeps everything, U leaves anything undecided alone. And if I've made a mess of a
> frame, Decision Tree All puts back the tree's original decisions for it.

**ON SCREEN:** Press **R** (Render This Frame) and show **final processed frame**.
Mention that the frame also saves on its own a few seconds after you stop editing.

**SAY:**
> Star rewrites a frame by itself a few seconds after I stop changing it, and R
> does it immediately so I can check.

**ON SCREEN (optional) — per-frame mode:** In the right panel, the frame's **Clean**
method: switch one frame to **Automatic**.

**SAY (optional):**
> And each frame can have its own mode. If one frame is just full of airplanes, I can
> switch that frame alone to automatic and let Star clean all of it.

## 5. Playing it back

**ON SCREEN:** Press **S** for Scrub mode. Play (space) the final processed frames
through the sections you edited; **w** plays in reverse; pause on a corrected frame.

**SAY:**
> Once I've been through the frames that matter, I play the whole thing back here in
> Star. If I spot anything, I stop, switch back to edit mode, and fix it.

## 6. Rendering

**ON SCREEN:** **Render Video** → the "Render video from N frames" sheet: container,
codec, resolution (Original), frame rate, total length → **Render**. **[CUT]** →
**Reveal In Finder** → play a few seconds full screen.

**SAY:**
> When I'm happy, I render the video. ProRes if it's going into an editor, H.264 or
> HEVC if it's going straight online. Same frame rate as the original, so the
> length matches.
>
> And that's it — every airplane gone, and every pixel that was replaced was one I
> agreed to.

## 7. Close (headshot, ~20 s)

**SAY:**
> Selective mode takes a bit longer than automatic, but on a tricky night — clouds,
> lights on the ground, a meteor you can't lose — it gives you complete control,
> and the decision tree does most of the work for you. If you want the quicker
> routes, the first two videos cover fully automatic mode and keeping meteors
> automatically.

---

## Edit checklist

- Sync screen and camera on the clap.
- Zoom in on every tool use; outlines are thin at full frame.
- Consider an on-screen key legend while section 4 runs:
  1 Remove · 2 Keep · 3 Razor · 4 Shovel · 5 Trash · 7 Multi · 8 Info ·
  a/k/u whole frame · r render frame · z/x fast skip · E/S/G modes.
