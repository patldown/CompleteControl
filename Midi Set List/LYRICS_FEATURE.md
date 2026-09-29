# Feature: Lyrics/Tabs with Performance Mode ✅

## Feature Overview

Added comprehensive lyrics and guitar tabs support with a full-screen **Performance Mode** featuring auto-scroll for hands-free playing during live performances.

---

## What's New

### 1. **Lyrics Field in Song Model**
- ✅ Added `lyrics: String?` property to Song
- ✅ Stores lyrics, chords, and/or guitar tabs
- ✅ Syncs via iCloud (SwiftData)
- ✅ Fully searchable and editable

### 2. **Edit Lyrics View** (`EditLyricsView`)
- ✅ Full-screen text editor
- ✅ **Monospaced font** for chord alignment
- ✅ Auto-focus on appear
- ✅ Clear button for quick reset
- ✅ Info banner with helpful tips
- ✅ Keyboard toolbar with Done button

### 3. **Performance Mode** (`LyricsPerformanceView`)
- ✅ **Full-screen** immersive view
- ✅ **Black background** for minimal distraction
- ✅ **Large text** (24pt monospaced) for easy reading
- ✅ **Auto-scroll** with adjustable speed
- ✅ **Play/Pause** controls
- ✅ **Reset to top** button
- ✅ **Tap to hide/show** controls
- ✅ **Edit button** to jump to lyrics editor
- ✅ **No status bars** for maximum screen space

### 4. **Integration in SongDetailView**
- ✅ New "Performance" section
- ✅ Shows lyrics preview (first 100 chars)
- ✅ "Edit" button to open lyrics editor
- ✅ "Performance Mode" button (when lyrics exist)
- ✅ Helpful footer text

---

## User Workflows

### Adding Lyrics

**From Song View:**
1. Open song
2. Tap "Lyrics / Tabs" row
3. Type or paste lyrics
4. Tap "Save"

**Tips:**
- Use `[Verse]`, `[Chorus]` for structure
- Place chords above lyrics
- Monospaced font keeps chords aligned

**Example Format:**
```
[Intro]
D C G (x4)

[Verse 1]
D            C           G
Big wheels keep on turning
D                C              G
Carry me home to see my kin
```

---

### Performance Mode Workflow

**Setup:**
1. Add lyrics to song
2. Tap "Performance Mode"
3. Adjust scroll speed (slider)
4. Tap "Start Scrolling"

**During Performance:**
- ✅ Lyrics auto-scroll at set speed
- ✅ Tap screen to pause/resume
- ✅ Tap again to show controls
- ✅ Adjust speed on the fly
- ✅ Reset to top if needed

**Hands-Free Playing:**
- Start scroll before song begins
- Perfect for solo performers
- No need to touch device during song
- Controls fade out for clean view

---

## Features in Detail

### Auto-Scroll System

**Speed Control:**
- Range: 5-100 (pixels per second)
- Adjustable in increments of 5
- Real-time speed display
- Changes apply immediately

**Smart Scrolling:**
- Smooth 60fps animation
- Linear interpolation
- Loops back to start at end
- Pause preserves position

**Controls:**
- 🟢 **Play** - Start auto-scrolling
- 🟠 **Pause** - Stop scrolling (keeps position)
- ⬆️ **Reset** - Jump back to top

### Display Optimization

**Full-Screen Mode:**
- Hides status bar
- Hides system overlays
- Maximizes lyrics area
- Black background reduces eye strain

**Typography:**
- 24pt monospaced font
- White text on black (high contrast)
- Left-aligned for readability
- Consistent character spacing

**Spacing:**
- 200pt top padding (centers first verse)
- 500pt bottom padding (scroll past end)
- 32pt horizontal padding (breathing room)
- Proper line height for lyrics

### Control Visibility

**Show/Hide Logic:**
- **Tap screen** → Toggle controls
- **Default:** Controls visible
- **Hidden:** Full-screen lyrics
- **Animated:** Smooth fade transitions

**Always Accessible:**
- Close button (top left)
- Edit button (top right)
- Controls (bottom)

---

## UI Components

### Performance Mode Screen

```
┌─────────────────────────────────┐
│ ✕                            ✎  │ ← Top controls
│                                 │
│                                 │
│     [Verse 1]                   │
│     D       C         G         │
│     Big wheels keep on turning  │
│                                 │
│     D            C          G   │
│     Carry me home to see my kin │
│                                 │
│                                 │
├─────────────────────────────────┤
│ ⚡ Scroll Speed         [20]    │
│ ————————◉————————————           │ ← Speed slider
│                                 │
│ ▶ Start Scrolling               │ ← Play/Pause
│ ⬆ Reset to Top                  │ ← Reset
└─────────────────────────────────┘
```

### Edit Lyrics View

```
┌─────────────────────────────────┐
│ Cancel  Edit Lyrics / Tabs  Save│
├─────────────────────────────────┤
│ ℹ️ Add lyrics, chords, or tabs.  │
│   Use monospaced font for        │
│   chord alignment.               │
├─────────────────────────────────┤
│                                 │
│ [Verse 1]                       │
│ D       C         G             │
│ Big wheels keep on turning      │
│                                 │
│ [Type lyrics here...]           │
│                                 │
│                                 │
└─────────────────────────────────┘
```

---

## Technical Implementation

### Model Changes

**Song.swift:**
```swift
@Model
class Song {
    var lyrics: String?  // NEW
    
    init(..., lyrics: String? = nil) {
        self.lyrics = lyrics
    }
}
```

### New Views

**`EditLyricsView`:**
- SwiftUI `TextEditor`
- Monospaced font
- Keyboard toolbar
- Auto-focus
- Save/Cancel actions

**`LyricsPerformanceView`:**
- Full-screen cover
- ScrollViewReader for programmatic scrolling
- Timer-based auto-scroll
- State management for controls
- Gesture-based control toggle

### Auto-Scroll Implementation

```swift
@State private var isAutoScrolling = false
@State private var scrollSpeed: Double = 20.0
@State private var scrollPosition: CGFloat = 0
@State private var scrollTimer: Timer?

private func startAutoScroll() {
    scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
        scrollPosition += (scrollSpeed / 1000) * 0.016
        
        if scrollPosition >= 1.0 {
            scrollPosition = 0  // Loop
        }
    }
}
```

---

## Use Cases

### 1. **Solo Performer**
- Add song lyrics with chords
- Enter Performance Mode
- Set comfortable scroll speed
- Start scrolling before song
- Play guitar hands-free ✅

### 2. **Band Practice**
- Share lyrics across devices (iCloud)
- Everyone sees same content
- No need for printed sheets
- Easy updates if arrangement changes

### 3. **Learning New Songs**
- Paste lyrics and chords
- Slow scroll speed for learning
- Pause to practice sections
- Visual reference while playing

### 4. **Live Performance**
- Full-screen lyrics for confidence
- Auto-scroll eliminates page flipping
- Professional presentation
- No paper on stage

---

## Benefits

### For Musicians
- ✅ **Hands-free** operation during performance
- ✅ **No page flipping** or scrolling manually
- ✅ **Large, readable** text
- ✅ **Chord alignment** with monospaced font
- ✅ **Quick edits** on the fly
- ✅ **Always available** on device

### For Setups
- ✅ **Integrated** with MIDI commands
- ✅ **One app** for everything
- ✅ **Cloud sync** across devices
- ✅ **No extra apps** needed
- ✅ **Organized** by song/set list

### For Workflow
- ✅ **Fast entry** - paste from web
- ✅ **Easy editing** - full-screen editor
- ✅ **Quick access** - one tap to perform mode
- ✅ **Flexible** - works with or without MIDI

---

## Future Enhancements

Could add:
- 📱 Font size adjustment
- 🎨 Color themes (amber, green, etc.)
- 📑 Section navigation (jump to chorus)
- 🔊 Metronome integration
- 🎵 Audio recording/playback
- 📤 Share lyrics (export as PDF)
- 🔍 Search within lyrics
- 📊 Practice tracking

But current implementation covers **core use case perfectly**! 🎸

---

## Files Created/Modified

### New Files:
- `ViewsSongsLyricsPerformanceView.swift` - Full-screen performance mode
- `ViewsSongsEditLyricsView.swift` - Lyrics editor

### Modified Files:
- `ModelsSong.swift` - Added lyrics property
- `ViewsSongsSongDetailView.swift` - Added lyrics section & buttons

---

## Testing Scenarios

### Scenario 1: Add Lyrics
1. Create song "Sweet Home Alabama"
2. Tap "Lyrics / Tabs"
3. Paste lyrics with chords
4. Tap "Save"
5. See preview in song view ✓

### Scenario 2: Performance Mode
1. Open song with lyrics
2. Tap "Performance Mode"
3. Tap "Start Scrolling"
4. Watch smooth auto-scroll ✓
5. Tap to pause
6. Adjust speed
7. Resume scrolling ✓

### Scenario 3: Edit During Performance
1. In Performance Mode
2. Notice typo
3. Tap "Edit" button
4. Fix typo
5. Save
6. Return to performance
7. Changes visible ✓

---

## Impact

**Before:** No lyrics support, manual scrolling, separate apps  
**After:** Integrated lyrics with hands-free performance mode

**Result:** Complete all-in-one solution for live musicians! 🎤🎸

**User Value:** ⬆️⬆️⬆️⬆️⬆️
