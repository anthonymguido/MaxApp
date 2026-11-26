# Floor Plan Scanner (iPhone app)

Walk through your home with your iPhone. The **LiDAR scanner** measures every room (walls, doors,
windows, furniture) while the **camera** photographs everything. The app then paints those photos onto
the walls, floors and furniture and builds a **textured 3D model of your home** (`.usdz`). You can spin
it around, look down into the rooms, place it on a table in AR, or share it.

For extra detail, any piece of furniture can be captured on its own with **photogrammetry** (the same
Object Capture as the Object Scanner app). The detailed model is then dropped into the house in place
of its box.

It combines the other two apps:
- **Wi-Fi Heatmap**: the guided RoomPlan LiDAR scan (step cards, coverage ring, coaching banners)
  and the 2D floor plan drawer.
- **Object Scanner**: Object Capture and on-phone photogrammetry for furniture detail, plus the
  scan-data export.

> Needs **iOS 17 or later** and a phone with a **LiDAR scanner**: iPhone 12 Pro / Pro Max or any later
> **Pro** model, or a recent iPad Pro.

---

## Getting it onto your iPhone from a Windows PC

You'll need: a free **GitHub** account, your **Apple ID**, your iPhone and its USB cable.
If you already set up Sideloadly for the other apps, Part 2 is just the last two steps.

### Part 1 – Let GitHub build the app (about 15 minutes, mostly waiting)

1. On **github.com** click **+** → **New repository**, name it `FloorPlanScanner`, choose **Public**
   (unlimited free build time), and click **Create repository**.
2. Click **uploading an existing file**, drag **everything inside** this folder (including the
   `.github` folder) onto the page, and click **Commit changes**.
   (Or with GitHub Desktop: **File → Add local repository…**, then **Publish repository** with
   **Keep this code private** unticked.)
3. Open the repo's **Actions** tab. A run called "Build iPhone app" starts automatically
   (if GitHub asks you to enable workflows, click the green button, then **Run workflow**).
4. Wait for a green ✓ (about 5–10 minutes). Click the run, scroll to **Artifacts**, and download
   **FloorPlanScanner-ipa**. Unzip it to get `FloorPlanScanner.ipa`.

   If you get a red ✗ instead, click into the failed step and copy the error lines to Claude to fix.

### Part 2 – Install it with Sideloadly

1. Install **iTunes** and **iCloud** from Apple's website, **not** the Microsoft Store versions:
   https://www.apple.com/itunes/download/win64
2. Install **Sideloadly** from https://sideloadly.io
3. Plug in your iPhone, unlock it, and tap **Trust** when asked.
4. Open Sideloadly → drag `FloorPlanScanner.ipa` onto it → type your Apple ID → **Start**.
5. On the iPhone: **Settings → Privacy & Security → Developer Mode** on (restart when prompted), then
   **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.
6. Open **Floor Plan Scanner** from your home screen.

**Every 7 days** the app stops opening (an Apple rule for free accounts). Run Sideloadly again with the
same `.ipa`. Your scans are kept.

---

## Scanning your home

1. **+** → name it (e.g. "Ground floor") → **Start**.
2. Read the tips, then follow the step cards: sweep the walls of each room, tilt down and up, walk
   through the doorway to the next room. The camera counter at the top shows how many photos have
   been recorded for the textures. Banners tell you if you're going too fast or it's too dark.
3. Tap **Done** → check the summary → **Use this scan**.
4. **Detail pass** (recommended): tap **Start detail pass** and walk through again for 1–2 minutes per
   room. The LiDAR mesh drawn over the camera shows what's been captured. Sweep furniture from high,
   middle and low, get close to shelves, and cover the whole floor. The app takes sharp 12-megapixel
   photos and records LiDAR depth as you go. Tap **Finish** when done, or **Skip**.
5. On the house page tap **Build textured house**. Keep the app open. It takes a minute or two for a
   small flat, longer for a big house.
6. **View in 3D / AR** to look around. **Share textured model** exports the `.usdz`, which opens in
   Files, Mail and AirDrop, on a Mac, or in Blender (File → Import → Universal Scene Description).

### For the best textures
- **Turn on all the lights** and open the curtains. Even light gives even colors.
- **Move slowly** and point the phone at **every wall and the floor**. Anything the camera never
  saw gets filled in with nearby colors.
- Walk a little way into each room rather than scanning from the doorway, so walls are photographed
  face-on and not at a sharp angle.
- **Sweep the floor too.** Before tapping Done in each room, tilt the phone down and slowly sweep the
  middle of the floor, including where you were standing. That's the part scans miss most.
- Up to about 800 photos are recorded per scan. Scan one floor at a time.

### Furniture detail (photogrammetry)
Furniture starts as boxes painted with photo colors. For a real-looking model of a piece:
1. On the house page, under **Furniture detail**, tap **Capture detail** next to it (e.g. "Sofa 1").
2. Walk around it like in the Object Scanner app. The model builds automatically afterwards.
3. Tap **Rebuild textured house**. The detailed model replaces the box, sized and placed to fit it.
   If it faces the wrong way, tap **Turn 90°** and rebuild.

Works best for chairs, tables, lamps, side tables and other pieces you can walk all the way around.

### Export for a computer
**Export scan data for a computer** makes a `.zip` with every photo, the LiDAR depth map for each
photo (16-bit PNG, millimetres), the camera position and lens for each photo (`transforms.json`), the
RoomPlan result (`room.json`) and both models. A `README.txt` inside explains how to build a
full-detail photogrammetry model of each room on a Mac, which iPhones can't do.

---

## How it works

1. **Measure**: Apple RoomPlan uses LiDAR to find walls, doors, windows, floors and furniture,
   accurate to a few centimetres.
2. **Photograph**: during the same scan, the app keeps a photo every ~12° of turn or ~25 cm of
   walking (skipping blurry moments). For each one it saves the exact camera position and lens, and the
   LiDAR depth map when available.
3. **Build the shell**: each wall becomes two textured faces (inside and outside of the room) with
   holes cut for doors, windows and openings. Floors follow RoomPlan's floor outlines. Furniture is
   a box.
4. **Paint**: for every 10 cm patch of every surface, the app picks the 3 photos that see it best:
   facing it, close to it, sharp, and **not blocked** by another wall or piece of furniture (checked
   against the plan and the LiDAR depth). It blends them at 1 cm per pixel, smoothly between patches,
   and evens out brightness between photos so camera auto-exposure doesn't show as blotches.
5. **Detail**: Object Capture models of furniture are fitted into their boxes.
6. **Save**: everything is written as one `.usdz`, centred, with the floor at height 0.

### Limits
- Shapes are RoomPlan's: walls are flat, and furniture is a box unless you capture detail for it.
  Very cluttered shelves look like a painted box.
- Ceilings are off by default, so you can look down into the rooms. Turn them on with
  **Include ceilings**.
- Mirrors, glass and TV screens show whatever they reflected.
