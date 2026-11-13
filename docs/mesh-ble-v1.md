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
- **Legacy advertising with compact frames (§4b) is required.** It's
  the only kind iPhones are known to hand to apps: Apple documents no
  app-level support for receiving extended advertising, and developer
  reports of it working are rare.
- Extended advertising with v1 frames (§4) is optional, alongside it.
  When used, put service UUID **`76797324-4B57-4664-8E4D-53F4C3D38BC4`**:
  - in the Complete List of 128-bit Service UUIDs (iOS scan filters
    match only this list), and
  - as the key of 128-bit Service Data, whose value is one frame.
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

## 4b. Compact frames (legacy advertising)

A v1 header plus a 128-bit UUID doesn't fit 31 bytes, so legacy
advertisements carry this instead, in **Manufacturer Specific Data**
under company ID **`0xFFFF`** (little-endian `FF FF` on the air). That's
the Bluetooth SIG's ID for testing; production needs Onym's own.

```
offset  size  field
     0     1  kind        0xC1
     1     1  epochLow    epoch & 0xFF
     2     3  tag         for that epoch
     5     2  envelopeID  UInt16 big-endian
     7     1  index       0-based
     8     1  count       1...255, index < count
     9     …  chunk       1...15 bytes
```

- **Epoch:** a receiver recovers the full epoch from `epochLow` as the
  only epoch in its window (24 hours back to one ahead, 98 epochs) with
  that low byte.
- **Envelope ID:** only distinguishes envelopes that share a tag and an
  epoch. Receivers reassemble by (epoch, tag, envelopeID).
- **Chunk size:** 15 bytes. 31 bytes, less 4 for the AD header and company
  ID, less 3 for a Flags AD some Android stacks add even when not
  connectable, less the 9-byte header.
- **Size limit:** 255 × 15 = 3,825 bytes, enough for text messages.

## 4c. Coded frames (legacy advertising, current)

What broadcasters send now. Three changes over compact frames, each
cutting how long a message takes to cross:

1. **Binary envelope.** The sealed envelope's fixed fields travel raw
   instead of base64 inside JSON: format byte `0x01`, ephemeral public
   key (32), its signature (64), sender Ed25519 key (32), nonce (12),
   authentication tag (16), then the ciphertext. A receiver rebuilds the
   exact JSON envelope the inbox already opens.
2. **Compressed plaintext.** The sender seals `0x01 ‖ raw DEFLATE(payload
   JSON)`. JSON starts with `{`, so the marker is unambiguous; a receiver
   inflates after decrypting (capped at 64 KiB) and passes unmarked
   plaintext through.
3. **Erasure coding.** The envelope, prefixed with its 2-byte length and
   zero-padded, is split into K symbols of 17 bytes. Frame indices
   `0…K−1` carry the symbols; every index `≥ K` carries a GF(2⁸)
   combination of all K (polynomial `0x11D`) with coefficients from
   xorshift32 seeded by `(envelopeID << 16 | index) × 0x9E3779B1 ⊕
   0x6D2B79F5` (zero seed → 1; each step `x ^= x<<13; x ^= x>>17; x ^=
   x<<5`; low byte, zero → 1). Any K independent frames rebuild the
   envelope — no waiting for one particular missing fragment.

```
offset  size  field
     0     1  kind        0xC2
     1     1  epochLow    epoch & 0xFF
     2     3  tag         for that epoch
     5     2  envelopeID  UInt16 big-endian
     7     1  k           source symbols, 1...255
     8     2  index       UInt16 big-endian; < k source, ≥ k repair
    10    17  symbol
```

27 bytes, in Manufacturer Specific Data under `0xFFFF`: exactly a
non-connectable legacy advertisement (non-connectable sets carry no
Flags). Up to 255 × 17 − 2 = 4,333 envelope bytes. Listeners still read
v1 and compact frames.

Broadcasters should send the source frames, then an unending run of
fresh repair indices, and give the newest envelope most of the airtime
while it is new.

## 5. Listener behaviour (what iOS does)

1. Read v1 frames from the mesh Service Data and compact frames from
   Manufacturer Specific Data under `0xFFFF` whose first byte is `0xC1`.
   Never connect. On iOS, seeing manufacturer data needs an unfiltered
   scan, which iOS allows only in the foreground. In the background the
   scan narrows to the service UUID, so only v1 frames can arrive.
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
   advertisements' Service Data to apps? Background reception depends on
   it; compact frames work only in the foreground.
2. **Background reception.** A backgrounded iOS scan is filtered to the
   service UUID and coalesces repeat sightings of one advertiser. How
   many fragments of a looping broadcaster get through in the
   background?
3. **Android fragment rate.** How fast can `setAdvertisingData` cycle
   fragments before listeners start missing them?

## 8. Test vectors

`Packages/OnymMesh/Tests/OnymMeshTests/Fixtures/mesh-v1-vectors.json`:
fixed X25519 keys, the pair key, tags for three epochs, and a 12-byte
envelope split into three v1 frames and into three compact frames; and,
under `coded`, coefficients, coded frames, a binary/JSON envelope pair
and a DEFLATE-compressed plaintext — generated by a separate Python
implementation. It was generated by an implementation
separate from `OnymMesh`, and `MeshVectorsTests` checks the package
against it. Android and the station firmware should check against the
same file.
