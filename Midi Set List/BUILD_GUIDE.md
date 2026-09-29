# Build Configuration & Troubleshooting

## Required Xcode Project Settings

### 1. iOS Deployment Target
- **Minimum**: iOS 17.0 (for SwiftData + Tab API)
- **Recommended**: iOS 17.2+ (for latest features)

### 2. Capabilities & Entitlements

#### iCloud (for SwiftData sync)
1. Select your target
2. Go to "Signing & Capabilities"
3. Click "+ Capability"
4. Add "iCloud"
5. Enable "CloudKit"

#### Background Modes (optional, for background MIDI)
- Audio, AirPlay, and Picture in Picture
- Background fetch

### 3. Info.plist Additions

No special additions required! CoreMIDI works without Info.plist entries.

### 4. Swift Language Version
- Swift 5.9 or later

---

## Common Build Errors & Fixes

### Error: "Cannot find type 'Song' in scope"
**Fix**: Make sure all model files are added to your target
- Select each file in Models/ folder
- Check "Target Membership" in File Inspector
- Ensure your app target is checked

### Error: "navigationBarTitleDisplayMode is unavailable in macOS"
**Cause**: Project might be set to multiplatform or macOS
**Fix**: 
1. Select project → Target → General
2. Under "Supported Destinations", remove macOS
3. Keep only iOS and iPadOS

### Error: "Cannot find 'UIPasteboard' in scope"
**Fix**: Already handled with `#if canImport(UIKit)` guards

### Error: "Cannot find 'ModelContainer' in scope"
**Fix**: Add `import SwiftData` to the file

---

## File Checklist

Verify these files exist and are in target:

### Models/
- ✅ MIDICommandType.swift
- ✅ MIDICommand.swift
- ✅ Song.swift
- ✅ SetList.swift
- ✅ SavedPreset.swift
- ✅ MIDIDevice.swift

### Views/Songs/
- ✅ SongsLibraryView.swift
- ✅ AddSongView.swift
- ✅ SongDetailView.swift
- ✅ AddMIDICommandView.swift
- ✅ QuickCommandsView.swift
- ✅ BatchEditCommandsView.swift
- ✅ ExportCommandsView.swift
- ✅ ImportCommandsView.swift

### Views/SetLists/
- ✅ SetListsView.swift
- ✅ AddSetListView.swift
- ✅ SetListDetailView.swift

### Views/MIDIDevices/
- ✅ MIDIDevicesView.swift
- ✅ MIDITestView.swift

### Managers/
- ✅ MIDIManager.swift

### Utilities/
- ✅ MIDICommandTemplate.swift
- ✅ CommandClipboard.swift
- ✅ CommandExporter.swift

### Root/
- ✅ Midi_Set_ListApp.swift
- ✅ ContentView.swift

---

## Build Steps

1. **Clean Build Folder**
   - Product → Clean Build Folder (⇧⌘K)

2. **Delete Derived Data** (if issues persist)
   - Xcode → Settings → Locations
   - Click arrow next to Derived Data path
   - Delete the folder for your project

3. **Rebuild**
   - Product → Build (⌘B)

4. **Run**
   - Product → Run (⌘R)
   - Choose iOS Simulator or real device

---

## Testing on Device vs Simulator

### Simulator
- ✅ UI testing
- ✅ Data persistence
- ✅ SwiftData/iCloud
- ⚠️ Limited MIDI device support
- ❌ No real Bluetooth MIDI

### Real Device (Recommended)
- ✅ Full MIDI support
- ✅ USB MIDI (with Lightning to USB adapter)
- ✅ Bluetooth MIDI
- ✅ Network MIDI
- ✅ Best performance testing

---

## Runtime Errors & Solutions

### "No MIDI devices found"
**Possible causes:**
1. No devices connected
2. Device not powered on
3. Bluetooth device not paired in Settings first

**Fix:**
- USB: Connect device with adapter
- Bluetooth: Pair in Settings → Bluetooth first, then scan in app
- Network MIDI: Configure on Mac with Audio MIDI Setup

### "MIDI system not initialized"
**Cause:** CoreMIDI client creation failed
**Fix:** 
- Restart app
- Check device capabilities
- On Simulator: expected behavior

### SwiftData errors
**Cause:** Model configuration issues
**Fix:**
- Ensure models have `@Model` macro
- Verify relationships are correct
- Delete app and reinstall to reset database

---

## Performance Optimization

### For Release Builds

1. **Build Configuration**
   - Target → Build Settings
   - Optimization Level: "Optimize for Speed"
   - Swift Compilation Mode: "Whole Module Optimization"

2. **Reduce Binary Size**
   - Enable "Strip Debug Symbols" (Release only)
   - Enable "Strip Swift Symbols" (Release only)

---

## Debugging Tools

### MIDI Debugging
```swift
// Add to MIDIManager for verbose logging
print("Sending MIDI: \(packet)")
print("To device: \(device.name)")
print("Status: \(status)")
```

### SwiftData Debugging
```swift
// Print all songs
let descriptor = FetchDescriptor<Song>()
let songs = try? modelContext.fetch(descriptor)
print("Songs: \(songs?.count ?? 0)")
```

### Performance Profiling
- Instruments → Time Profiler
- Monitor MIDI send latency
- Check for main thread blocking

---

## App Store Submission Checklist

### Before Submission

1. ✅ Test on multiple devices
2. ✅ Test with real MIDI hardware
3. ✅ Test iCloud sync between devices
4. ✅ Add app icons (all sizes)
5. ✅ Create screenshots
6. ✅ Write privacy policy (for iCloud data)
7. ✅ Test in Airplane mode
8. ✅ Test with VoiceOver (accessibility)

### App Description Keywords
- MIDI controller
- Set list manager
- Live performance
- BeatBuddy
- HX Stomp
- Program change
- MIDI commands
- Musician tool

---

## Known Limitations

1. **MIDI Input**: Currently send-only (no MIDI in)
2. **SysEx**: Not implemented (PC/CC/Bank only)
3. **MIDI Clock**: Not implemented
4. **Multi-port**: Single output port only
5. **macOS**: iOS/iPadOS only

---

## Future Enhancements

See PHASE3_COMPLETE.md for roadmap!
