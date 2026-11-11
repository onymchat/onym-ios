# Onym Bluetooth mesh, v1

Broadcast-only delivery of sealed Onym envelopes over Bluetooth LE, for
when there's no internet. Nodes that broadcast never learn who heard
them; nodes that listen never transmit.

Status: v1 is implemented on iOS as a **receive-only listener**
(`Packages/OnymMesh`, opt-in under Settings → Privacy → "Listen over
Bluetooth"). Broadcasters — Android phones and ESP32 stations — are not
built yet. This document is what they build against.

## 1. Roles

| Role | Who | Transmits | Learns |
|---|---|---|---|
| Broadcaster | Android phone, ESP32 station | Non-connectable, non-scannable advertisements | Nothing about listeners |
| Listener | Any phone (iOS: always this role) | Nothing | Only frames addressed to it |

There are no Bluetooth connections anywhere in v1. Uploading to a
station is out of scope for this version.

## 2. Addressing and privacy

A frame never names its recipient, its sender, or any key. It carries a
3-byte **tag** that only the sender and the recipient can compute, and
which changes every 15 minutes.

```
pairKey = HKDF-SHA256(
            ikm  = X25519(own inbox private key, peer inbox public key),
            salt = "onym-mesh-pair-v1",
            info = "",
            L    = 32)

epoch   = floor(unix_seconds / 900)                      # UInt32

tag     = HMAC-SHA256(pairKey, "onym-mesh-tag-v1" ‖ epoch as UInt32 big-endian)[0..<3]
```

- X25519 is symmetric, so both sides derive the same `pairKey`.
- The inbox **public** key is not secret: it's in every share-my-key QR
  code. The tag needs the X25519 shared secret, so holding someone's QR
  code doesn't let you compute their tags.
- Three bytes on purpose. Unrelated frames collide often enough that a
  match says little; a collision costs one failed decrypt, because the
  envelope authenticates its sender.
- A listener only has pair keys for people it shares a group with, so
  frames from strangers never match.

## 3. Radio requirements for broadcasters

- **Non-connectable and non-scannable** (Android:
  `setConnectable(false)`, `setScannable(false)`). A scannable
  advertisement makes listeners send scan requests, which would reveal
  them. This is mandatory.
- Service UUID **`76797324-4B57-4664-8E4D-53F4C3D38BC4`**:
  - in the Complete List of 128-bit Service UUIDs (iOS scan filters
    match only this list), and
  - as the key of 128-bit Service Data, whose value is one frame (§4).
- Extended advertising (Bluetooth 5) when the chip supports it. A
  legacy 31-byte advertisement can't hold the UUID list, the Service
  Data header and a useful frame together.
- Restart the advertising set at every epoch boundary, so the random
  device address rotates together with the tags. Otherwise one address
  links two epochs' tags.
- Loop every envelope it holds, for up to 24 hours after its epoch. No
  delivery feedback exists, so repetition is the only reliability.

## 4. Frame format

```
offset  size  field
     0     1  version      0x01
     1     4  epoch        UInt32 big-endian
     5     3  tag          for that epoch
     8     8  envelopeID   random per envelope; groups its fragments
    16     1  index        0-based
    17     1  count        1...255, index < count
    18     …  chunk        at least 1 byte
```

- The envelope is the exact sealed-envelope bytes Onym would send over
  Nostr (`InboxTransport.send`), at most 16 KiB.
- Every fragment repeats the tag, so a listener drops other people's
  fragments without buffering them.

## 5. Listener behaviour (what iOS does)

1. Scan for the service UUID, read only its Service Data. Never connect.
2. Drop anything that isn't a well-formed v1 frame.
3. Accept epochs from 24 hours ago up to one epoch ahead (clock drift).
4. Look the tag up in a table computed for that epoch from every
   (local identity, group member) pair key. No match: drop.
5. Reassemble by `envelopeID`: any order, duplicates ignored,
   incomplete envelopes forgotten after 10 minutes, at most 64 pending,
   a delivered envelope ignored for 30 minutes (a looping broadcaster
   comes round again).
6. Decrypt with the matching identity. Accept **chat messages only**;
   drop everything else, including anything that fails to decrypt.
7. Store the message. **Send no receipt** — not over Bluetooth, and not
   later over a relay. If the same message also arrives through a relay,
   that delivery acknowledges as usual.
8. Messages for an unknown group or sender are dropped, not queued; the
   relay copy catches up.
9. If the app isn't in the foreground, raise a content-free local
   notification.

## 6. What this does and doesn't protect

**Protected**
- Listeners can't be detected or probed through Onym: they transmit
  nothing, and nothing is acknowledged.
- Passive observers can't link frames to people or to each other across
  epochs, and holding someone's public QR code doesn't help them.

**Not protected**
- A broadcaster is visible as an Onym node while it broadcasts.
- A phone's other Bluetooth emissions (AirDrop, Continuity, Find My) are
  outside Onym's control.
- Traffic timing: when a broadcaster transmits, and roughly how much.

## 7. Open questions a device test must answer

1. **Extended advertising on iOS.** Do current iPhones deliver extended
   advertisements' Service Data to apps (`CBCentralManager.supports(.extendedScanAndConnect)`)?
   v1 depends on it.
2. **Background reception.** A backgrounded iOS scan is filtered to the
   service UUID and coalesces repeat sightings of one advertiser. How
   many fragments of a looping broadcaster get through in the
   background?
3. **Android fragment rate.** How fast can `setAdvertisingData` cycle
   fragments before listeners start missing them?

## 8. Test vectors

`Packages/OnymMesh/Tests/OnymMeshTests/Fixtures/mesh-v1-vectors.json`:
fixed X25519 keys, the pair key, tags for three epochs, and a 12-byte
envelope split into three frames. It was generated by an implementation
separate from `OnymMesh`, and `MeshVectorsTests` checks the package
against it. Android and the station firmware should check against the
same file.
