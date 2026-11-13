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
   zero-padded, is split into K symbols of 13 bytes. Frame indices
   `0…K−1` carry the symbols; every index `≥ K` carries a GF(2⁸)
   combination of all K (polynomial `0x11D`) — a Cauchy row: the
   coefficient for symbol `m` is `1 / (x ⊕ m)` with `x = K + (index − K)
   mod (256 − K)`. Sources occupy field elements `0…K−1` and repairs
   `K…255`, disjoint, so **any K distinct frames** rebuild the envelope
   — never one wasted, and no waiting for one particular fragment. Index
   values past 255 repeat earlier rows. (A pseudo-random generator was
   tried first; xorshift is linear over GF(2), so its rows span at most
   33 dimensions and envelopes over 33 symbols could never decode from
   repairs.)

```
offset  size  field
     0     1  kind        0xC2
     1     1  epochLow    epoch & 0xFF
     2     3  tag         for that epoch
     5     2  envelopeID  UInt16 big-endian
     7     1  k           source symbols, 1...255
     8     2  index       UInt16 big-endian; < k source, ≥ k repair
    10    13  symbol
```

23 bytes, in Service Data under the 16-bit UUID `0x4F4E`, with the same
UUID in a Complete List of 16-bit Service UUIDs:

```
04 03 4E 4F                  16-bit service UUID list: 0x4F4E
1A 16 4E 4F <23-byte frame>  Service Data, 16-bit UUID 0x4F4E
```

31 bytes: exactly a non-connectable legacy advertisement (non-connectable
sets carry no Flags). Up to 255 × 13 − 2 = 3,313 envelope bytes.

The list is what makes this format reach a **locked iPhone**. A
backgrounded iOS app may only scan filtered to service UUIDs, and the
filter matches the UUID list — not manufacturer data, and not Service
Data alone. A 128-bit UUID would leave no room for the frame, hence the
16-bit one. `0x4F4E` ("ON") is not assigned by the Bluetooth SIG; it is
chosen outside the ranges the SIG allocates from. It marks an
advertisement as an Onym broadcast exactly as compact frames' company ID
and kind byte did — no more.

A backgrounded iOS scan also reports each advertiser once, however often
its data changes. Broadcasters should therefore start a fresh
advertising set — a fresh random address — for every frame or every few
frames, and a backgrounded listener restarts its scan after frames
arrive.

Listeners still read v1 and compact frames.

Broadcasters should send the source frames, then repair indices
`K…255` in turn, round and round, and give the newest envelope most of the airtime
while it is new.

## 5. Listener behaviour (what iOS does)

1. Read coded frames from Service Data under `0x4F4E` (first byte
   `0xC2`), v1 frames from the 128-bit mesh Service Data, and compact
   frames from Manufacturer Specific Data under `0xFFFF` whose first
   byte is `0xC1`. Never connect. On iOS the foreground scan is
   unfiltered; in the background it narrows to the two service UUIDs,
   so coded and v1 frames still arrive, and the scan restarts after
   frames arrive so iOS doesn't swallow repeat sightings.
2. Drop anything that isn't a well-formed v1 frame.
3. Accept epochs from 24 hours ago up to one epoch ahead (clock drift).
4. Look the tag up in a table computed for that epoch from every
   (local identity, group member) pair key. No match: drop.
5. Reassemble by `envelopeID`: any order, duplicates ignored,
   incomplete envelopes forgotten after 30 minutes, at most 64 pending,
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
   notification. On a locked iPhone the message store (Complete file
   protection) can't be written: the message waits in memory, the
   notification goes out anyway, and the message is stored on unlock.

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
