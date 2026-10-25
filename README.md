# EP Samples (iOS)

A native iOS/iPadOS rewrite of the sample-library part of Teenage Engineering's web-based
EP Sample Tool, for the EP-133 K.O. II, EP-1320 Medieval and EP-40 Riddim.

Connect the device to an iPhone or iPad with a USB-C cable. The app lets you:

- browse the device's sound library (slots 001–999)
- import audio files (WAV, AIFF, MP3, M4A, CAF, FLAC… anything iOS can decode), convert them
  to the device format and upload them into the next free slots
- preview a sound on the device, rename it, or delete it

Not ported yet: backup/restore (`.pak`), factory restore, project archives, downloading sounds,
moving sounds between slots, and assigning sounds to pads.

## Build

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open EPSampleTool.xcodeproj
```

The Simulator can't see USB MIDI devices, so Simulator builds use `MockEPDevice`, an in-memory
EP-133 that speaks the same protocol. Run on a real device to talk to hardware.

Tests (protocol vectors + end-to-end flows against the mock):

```bash
xcodebuild -scheme EPSampleTool -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

## Layout

| Folder | What's there |
|---|---|
| `EPSampleTool/MIDI` | `CoreMIDITransport` (USB MIDI, SysEx send/receive), `MockEPDevice` |
| `EPSampleTool/Protocol` | TE SysEx framing and 7-bit packing, request/response client, file-system commands |
| `EPSampleTool/Device` | `DeviceService` (sound library operations), `AppModel` (discovery and UI state) |
| `EPSampleTool/Audio` | AVFoundation conversion to 16-bit PCM, sample name normalization |
| `EPSampleTool/Views` | SwiftUI screens |
| `tools/vectors.mjs` | Generates `EPSampleToolTests/Resources/vectors.json` from the original JS functions |

## Protocol notes

Recovered from the web app's JavaScript bundle (v1.2.0). All multi-byte fields are big-endian.

**Discovery.** Send the universal identity request `F0 7E 7F 06 01 F7`. EP devices answer with a
17-byte reply whose bytes 5–7 are `00 20 76` (TE's manufacturer ID); bytes 8–11 encode the SKU
(`TE032AS001` = EP-133, `…005` = EP-1320, `…006` = EP-40). Then send GREET (command 1); the reply
is `key:value;…` text with `os_version`, `serial`, `sku`, etc.

**Framing.**
Request `F0 00 20 76 <dev> 40 <0x60 | id>>7> <id & 7F> <cmd> <packed payload> F7`.
Responses clear bit `0x40` in byte 6 and put a status byte before the payload
(0 ok, 1 error, 2 not found, 3 bad request, 16–63 command error, 64 "still working, keep waiting").
Payloads are 7-bit packed: each group of 7 bytes is preceded by one byte holding their high bits.
Request IDs are 12-bit and wrap.

**File system** is command 5. The first payload byte is the operation:

| Op | Name | Request after op byte |
|---|---|---|
| 1 | init | flags(1: subscribe to events), maxResponseLength u32 → reply has chunk size u32 at offset 1 |
| 2 | put | init: `00 flags id u16 parent u16 size u32 name\0 metadataJSON`; data: `01 page u16 bytes…`; an empty data page ends the file |
| 3 | get | init: `00 id u16 offset u32`; data: `01 page u16` |
| 4 | list | `page u16 node u16` → `page u16` + repeated `id u16 flags u8 size u32 name\0` |
| 5 | playback | `action(1 start, 2 stop) id u16 offset u32 length u32` |
| 6 | delete | `id u16` |
| 7 | metadata | set `01 id u16 json\0`; get `02 id u16 page u16`; paged set `04 00 id u16 size u32` then `04 01 page u16 bytes…` |
| 11 | info | `id u16` → `id parent flags size name\0` |
| 12 | move | `id u16 parent u16 newId u16` |

Node 0 is the root, which contains `sounds/` and `projects/`. A sound's node ID is its slot number.
Sounds are stored as raw interleaved signed 16-bit little-endian PCM. The `sounds` folder's
metadata lists supported formats; the default rate is 46 875 Hz. Sound metadata is JSON:
`channels`, `samplerate`, `name`, plus optional `sound.loopstart`, `sound.rootnote`, `sound.bpm`, etc.
PUT data pages hold `n - 1 - ⌊n/8⌋` bytes, where `n = chunkSize - 6 - 1 - 11`.
