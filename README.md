# Melodash

Melodash is a local, couch-multiplayer **singing battle** that scores **how you feel a song, not
just whether you hit the notes**. 2–5 players take turns singing; as each player performs, the app
listens to their voice *and* watches their expression, gives live feedback, and hands back a
per-turn score. A space-themed wizard runs the whole battle — setup, avatars, a "Mic Roulette"
turn order, per-turn results, and a final podium.

Everything runs **on-device** with Apple frameworks only — **Vision + Core ML** for expression,
**AVAudioEngine + Accelerate** for voice, **MusicKit** for Apple Music. Ships for **macOS**,
distributed direct from [melodash.app](https://www.melodash.app/).

> **Deep dive:** [`TECH_REPORT.md`](TECH_REPORT.md) has the full system architecture, the scoring
> formulas, the audio-session choreography, and the design decisions (with diagrams).

## How it scores

Each performance blends **two independent signals**, computed live and entirely on-device:

- **Voice** — realtime pitch (FFT autocorrelation via Accelerate), scored on a *relative* model:
  in-tune-ness to the nearest note, pitch stability, onset timing vs. the lyric lines, and dynamic
  range. No reference melody needed.
- **Expression** — facial emotion (a Core ML classifier + a Vision-landmark smile score) compared
  against the target *"vibe"* of the song's genre via cosine similarity.

`overall = 0.4 · expression + 0.6 · voice`, and it **degrades gracefully** — no camera scores on
voice alone, no mic scores on expression alone. Live during the song: a pitch needle (note +
cents), an energy meter, lyric highlighting synced to the audio, and an emotion badge.

## Song sources

Every song plays through one seam (`PlaybackSource`) so the rest of the app is identical:

| Source | Playback | Vocal-suppress | Lyrics |
|---|---|---|---|
| **Bundled** (`.m4a` in the app) | `AVAudioEngine` | ✅ center-channel | bundled `.lrc` |
| **Imported** (user's own file) | `AVAudioEngine` | ✅ center-channel | — |
| **Apple Music** (MusicKit) | `ApplicationMusicPlayer` | ❌ (DRM — no sample access) | fetched at runtime |

For local songs the backing track and the mic share one `AVAudioEngine`, so voice-processing
**echo cancellation** keeps the captured voice clean on speaker. Apple Music plays the full mix
(no vocal dimming is possible on DRM audio) — **headphones recommended** so the mic hears only you.

## Architecture

SwiftUI + SwiftData. Two roots — a `BattleController` (the game state machine) and a
`MelodashEngine` (the per-turn scoring coordinator that drives lyric sync, scoring, and progress
off a **single audio clock**). Protocol seams keep the hardware/ML boundaries swappable:

- **`PlaybackSource`** — `LocalAudioEngine` (local files) vs. `MusicKitPlaybackSource` (Apple Music)
- **`VocalSuppressing`** — the vocal-dim capability, split out so only local sources conform
- **`VocalSeparating`** — `CenterChannelSuppressor` today; an on-device stem separator could drop in later
- **`EmotionAnalyzing`** — the Core ML classifier, with a geometry-based placeholder fallback

```
Melodash/
├─ App/           MelodashApp (@main, ModelContainer), ContentView (screen router)
├─ Models/        Song (+ genres), Emotion, VoiceReading, Player/Avatar, BattleTurn, SampleData, SongImporter
├─ Engine/        MelodashEngine, PlaybackSource + LocalAudioEngine + MusicKitPlaybackSource + VoiceSuppressor,
│                 MicController + PitchDetector, CameraController + EmotionAnalyzing + EmotionFusion,
│                 ScoringMatrix + VoiceScoringMatrix, LyricsLoader + LyricsService
├─ Flow/          BattleController + the battle screens (Home, Setup, AvatarPick, TurnOrder,
│                 RoundIntro, SongPick, Performance, Result, Winners, Lobby) + AppleMusicSearcher
├─ DesignSystem/  Tokens, Theme, SpaceScene, SharedComponents, CameraPreview
└─ Resources/     Info.plist, fonts (Orbitron, Poppins); Assets and the optional
                  MelodashEmotionClassifier.mlmodel live alongside
```

## Requirements

- **Xcode 26+**.
- Targets **macOS 15+**.
- Because the app uses the **camera and microphone**, run it on a real **Mac**.

The project is macOS-only (`SUPPORTED_PLATFORMS = macosx`). The `#if os(iOS)` branches are still in
the source, so restoring an iOS build is one build-setting change — but Sparkle (see
[Distribution](#distribution)) is macOS-only and would have to be excluded.

## Build & run

```sh
open Melodash.xcodeproj
```

Select the **Melodash** scheme and run on My Mac. On first launch the app
seeds a small bundled catalog; grant **camera** and **microphone** permission when prompted.

## The emotion model

The expression classifier is a Create ML image classifier bundled as
`Melodash/MelodashEmotionClassifier.mlmodel` (Xcode compiles it to `.mlmodelc`). It's loaded by
name at runtime; **if it's ever absent, the app falls back to a geometry-based placeholder** so the
whole pipeline still runs. Retraining is a drop-in replacement of that file.

## Apple Music setup

Apple Music playback needs one-time setup:

1. Enable **MusicKit** for the app's App ID in the [Apple Developer portal](https://developer.apple.com/account)
   → Identifiers → *(your bundle ID)* → **MusicKit** → Save. The App ID must match the project's
   bundle identifier exactly.
2. Run signed into an **active Apple Music subscription** (non-subscribers get 30-second previews).

Then use **Search** / the **＋** in the song list to add an Apple Music track. MusicKit works via
the App ID service plus the `NSAppleMusicUsageDescription` string (already set) — no entitlements
file needed.

> **Note on the bundle identifier:** the product is branded *Melodash*, but the bundle id is kept
> as `me.babonoo.kemon` because that is the App ID registered for MusicKit. Changing it requires
> registering a new App ID with MusicKit enabled.

## Distribution

Melodash ships **direct from [melodash.app](https://www.melodash.app/)**, not through the Mac App
Store.

```sh
scripts/release.sh            # archive → Developer ID → notarize → staple → DMG → appcast
scripts/release.sh --dmg-only # resume from an already-notarized app
```

`release.sh` refuses to emit a build that `spctl` rejects. That guard exists because the first
public build was signed but **never notarized** — hardened runtime was off, which notarization
requires — so Gatekeeper blocked it for every user but the developer.

Updates go through **Sparkle**. The app checks `https://www.melodash.app/appcast.xml`, and each
release is signed with an EdDSA key whose private half lives in the developer's login keychain.
**That key is unrecoverable:** lose it and every installed copy becomes permanently un-updatable.

The DMG install window is styled by `scripts/build-dmg.sh`, which drives Finder over AppleScript —
so packaging needs a GUI login session and a one-time Automation permission. The background art is
generated by `scripts/make-dmg-background.swift` and committed under `scripts/dmg-assets/`.

### Verifying a release

Signing, notarization and Gatekeeper all pass happily on a binary that cannot resolve its own
frameworks — an early build shipped crashing at launch on a bad `@rpath` and cleared every one of
those checks. **Always install from the DMG to `/Applications` and launch it** before publishing.

### Why not the App Store

Nothing here is blocked by Apple's *tooling*; the obstacles are content and review-process ones.

1. **Lyrics — the likely blocker.** `Engine/LyricsService.swift` fetches synced lyrics from LRCLIB
   and an aggregator scraping Genius/Musixmatch/NetEase. That is unlicensed distribution of
   licensed content (**guideline 5.2, intellectual property**), and lyrics are on screen during
   every performance, so they appear in any screenshot.
2. **Apple Music terms.** Using catalog playback as karaoke backing while scoring the singer
   stretches the Apple Music API's restrictions on derivative and manipulated use — compounded by
   overlaying third-party lyrics onto Apple's licensed audio.
3. **Reviewability.** A 2–5 player local singing game needs a reviewer to sing into a mic. Without
   a demo video, explicit review notes, and a working **local-import** path that needs no Apple
   Music subscription, the likely outcome is "unable to review."
4. **A Mac App Store build is a fork, not a flag.** The App Sandbox would have to be re-added, and
   **Sparkle removed entirely** — third-party updaters are not allowed; the store handles updates.
5. **Face data** draws reviewer attention. The position is defensible (Vision runs on-device,
   nothing is transmitted), but the privacy nutrition labels must say so and it is worth stating
   up front in the review notes.

**Do not delete the App Store Connect record.** An unsubmitted record costs nothing, and deleting
one **permanently burns its bundle ID** — `me.babonoo.kemon` could never back another record. A
different bundle ID means macOS treats it as a different app, so existing direct-download users
would not upgrade into it. Direct distribution never touches App Store Connect: Developer ID
signing and notarization are separate systems, and the only thing used here is an app-specific
password tied to the Apple ID, not to any app record.

The route to the store, if it is ever wanted, is to license lyrics (Musixmatch has a commercial
API) or drop synced lyrics for Apple Music tracks and ship with imported-audio lyrics only.

## Content & licensing

The songs bundled in the repo are for **development and internal testing only** and are not licensed
for distribution. Shipping a public build with recognizable songs requires the full music-licensing
stack (mechanical + sync + master + performance + lyric-display rights). For a wider beta, swap to
royalty-free/owned content. Apple Music lyrics are fetched at runtime from public providers (LRCLIB
primary, with a fallback aggregator), disambiguated by track duration, since MusicKit exposes no
lyrics API.

## Privacy

Camera and microphone are processed **entirely on-device** and never uploaded or recorded. The only
data leaving the device is a song's title/artist/duration, sent to fetch public synced lyrics. The
app doesn't track users. Because it ships outside the Mac App Store it runs **unsandboxed under
the hardened runtime**, holding only the two entitlements the runtime still gates — camera and
microphone. See [`PrivacyInfo.xcprivacy`](Melodash/PrivacyInfo.xcprivacy).

## Status

Scoring engine, Apple Music search, and remote lyrics are implemented and building on macOS.
On-device validation of the end-to-end singing experience (pitch accuracy, echo cancellation,
MusicKit playback, multi-turn battles) is the ongoing pre-release checklist.
```
