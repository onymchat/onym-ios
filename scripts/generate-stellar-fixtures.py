"""Regenerate the reference XDR fixtures for `OnymStellar`.

The Stellar transaction codec in `Packages/OnymStellar` is hand-written
(see `XDR.swift` for why). What makes that defensible is this file: every
envelope in `OnymStellarTests/Fixtures/fixtures.json` is produced here by
an independent implementation, and `StellarXDRFixtureTests` checks our
bytes and our transaction hashes against it.

    ~/Developer/onym-bank/.venv/bin/python scripts/generate-stellar-fixtures.py

Requires `stellar-sdk` (15.0.0 when these fixtures were generated); the
onym-bank virtualenv already has it.

Output must be **reproducible** — run it twice and diff. Keys come from
fixed seeds and every time bound is written out explicitly, because
`TransactionBuilder` otherwise applies a default timeout that bakes the
current clock into the fixture. A fixture containing `now` stops being a
reference the moment it is regenerated.
"""

import json
import pathlib
from stellar_sdk import (Account, Asset, Keypair, Network, TransactionBuilder,
                         Transaction, TransactionEnvelope, Preconditions)
from stellar_sdk.operation import CreateAccount, Payment, SetOptions, ChangeTrust
from stellar_sdk.signer import Signer

# Deterministic accounts from fixed seeds.
def kp(b): return Keypair.from_raw_ed25519_seed(bytes([b])*32)
SRC, DST, ISS, CO1, CO2 = kp(1), kp(2), kp(3), kp(4), kp(5)

def build(ops, seq=100, fee=100, memo=None, tb=(0, 1893456000), net=Network.TESTNET_NETWORK_PASSPHRASE):
    acct = Account(SRC.public_key, seq)
    b = TransactionBuilder(acct, network_passphrase=net, base_fee=fee)
    b.set_timeout(0)
    for o in ops: b.append_operation(o)
    if tb: b.add_time_bounds(tb[0], tb[1])
    if memo == "text": b.add_text_memo("treasury")
    if memo == "id": b.add_id_memo(42)
    te = b.build()
    return te

cases = {}

def add(name, te):
    cases[name] = {
        "xdr": te.to_xdr(),
        "hash": te.hash().hex(),
        "passphrase": te.network_passphrase,
    }

add("create_account", build([CreateAccount(DST.public_key, "100.5")]))
add("payment_native", build([Payment(DST.public_key, Asset.native(), "10.0000001")]))
add("payment_alphanum4", build([Payment(DST.public_key, Asset("USDC", ISS.public_key), "1")]))
add("payment_alphanum12", build([Payment(DST.public_key, Asset("LONGASSET123", ISS.public_key), "0.0000001")]))
add("change_trust", build([ChangeTrust(Asset("USDC", ISS.public_key), "922337203685.4775807")]))
add("set_options_signer", build([SetOptions(signer=Signer.ed25519_public_key(CO1.public_key, 1))]))
add("set_options_lockdown", build([SetOptions(master_weight=0, low_threshold=1, med_threshold=2, high_threshold=3)]))
add("memo_text", build([Payment(DST.public_key, Asset.native(), "1")], memo="text"))
add("memo_id", build([Payment(DST.public_key, Asset.native(), "1")], memo="id"))
# PRECOND_NONE, built below the TransactionBuilder: the builder always
# applies a default timeout, which would put `now` into a fixture and
# make it non-reproducible.
_tx = Transaction(
    source=SRC.public_key, sequence=101, fee=100,
    operations=[Payment(DST.public_key, Asset.native(), "1")],
    preconditions=Preconditions(), v1=True)
add("no_timebounds", TransactionEnvelope(_tx, Network.TESTNET_NETWORK_PASSPHRASE))
add("pubnet", build([Payment(DST.public_key, Asset.native(), "1")], net=Network.PUBLIC_NETWORK_PASSPHRASE))

# The treasury creation shape: fund + configure + lock down, one envelope,
# per-operation source accounts.
T = kp(9)
acct = Account(SRC.public_key, 100)
b = TransactionBuilder(acct, network_passphrase=Network.TESTNET_NETWORK_PASSPHRASE, base_fee=100)
b.set_timeout(0)
b.append_operation(CreateAccount(T.public_key, "5"))
b.append_operation(SetOptions(signer=Signer.ed25519_public_key(CO1.public_key, 1), source=T.public_key))
b.append_operation(SetOptions(signer=Signer.ed25519_public_key(CO2.public_key, 1), source=T.public_key))
b.append_operation(SetOptions(master_weight=0, low_threshold=1, med_threshold=2, high_threshold=2, source=T.public_key))
b.add_time_bounds(0, 1893456000)
add("treasury_creation", b.build())

# A signed envelope, to pin decorated-signature encoding.
te = build([Payment(DST.public_key, Asset.native(), "1")])
te.sign(SRC)
te.sign(CO1)
cases["signed_two"] = {"xdr": te.to_xdr(), "hash": te.hash().hex(), "passphrase": te.network_passphrase}

meta = {
    "accounts": {n: k.public_key for n, k in
                 [("src", SRC), ("dst", DST), ("issuer", ISS), ("co1", CO1), ("co2", CO2), ("treasury", T)]},
    "secrets": {"src": SRC.secret, "co1": CO1.secret},
}
# Written to the fixture the test bundle actually loads, resolved from
# this file rather than the working directory. The documented invocation
# is from the repo root, where a bare "fixtures.json" landed next to
# project.yml and left the real fixture untouched — a regeneration that
# silently changed nothing.
OUT = (pathlib.Path(__file__).resolve().parent.parent
       / "Packages/OnymStellar/Tests/OnymStellarTests/Fixtures/fixtures.json")
OUT.parent.mkdir(parents=True, exist_ok=True)
with OUT.open("w") as handle:
    json.dump({"meta": meta, "cases": cases}, handle, indent=2)
print("wrote", OUT)
print(json.dumps(meta["accounts"], indent=2))
print("cases:", len(cases))
