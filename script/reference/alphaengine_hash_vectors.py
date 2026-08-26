#!/usr/bin/env python3
"""Dependency-free reference generator for AlphaEngine V1 hash vectors."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


MASK_64 = (1 << 64) - 1
RATE_BYTES = 136
ROTATION = (
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14,
)
ROUND_CONSTANTS = (
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
)


def _rotate_left(value: int, shift: int) -> int:
    if shift == 0:
        return value
    return ((value << shift) | (value >> (64 - shift))) & MASK_64


def _keccak_f1600(state: list[int]) -> None:
    for round_constant in ROUND_CONSTANTS:
        columns = [
            state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            for x in range(5)
        ]
        deltas = [columns[(x - 1) % 5] ^ _rotate_left(columns[(x + 1) % 5], 1) for x in range(5)]
        for y in range(5):
            for x in range(5):
                state[x + 5 * y] ^= deltas[x]

        rotated = [0] * 25
        for y in range(5):
            for x in range(5):
                new_x = y
                new_y = (2 * x + 3 * y) % 5
                rotated[new_x + 5 * new_y] = _rotate_left(
                    state[x + 5 * y], ROTATION[x + 5 * y]
                )

        for y in range(5):
            row = rotated[5 * y : 5 * y + 5]
            for x in range(5):
                state[x + 5 * y] = row[x] ^ ((~row[(x + 1) % 5]) & row[(x + 2) % 5])
                state[x + 5 * y] &= MASK_64

        state[0] ^= round_constant


def keccak256(data: bytes) -> bytes:
    padded = bytearray(data)
    padded.append(0x01)
    padded.extend(b"\x00" * ((RATE_BYTES - len(padded) % RATE_BYTES) % RATE_BYTES))
    padded[-1] ^= 0x80

    state = [0] * 25
    for block_start in range(0, len(padded), RATE_BYTES):
        block = padded[block_start : block_start + RATE_BYTES]
        for lane in range(RATE_BYTES // 8):
            state[lane] ^= int.from_bytes(block[lane * 8 : lane * 8 + 8], "little")
        _keccak_f1600(state)

    output = bytearray()
    while len(output) < 32:
        for lane in range(RATE_BYTES // 8):
            output.extend(state[lane].to_bytes(8, "little"))
            if len(output) >= 32:
                return bytes(output[:32])
        _keccak_f1600(state)
    raise AssertionError("unreachable")


def word(value: int) -> bytes:
    if value < 0 or value >= 1 << 256:
        raise ValueError(f"uint256 out of range: {value}")
    return value.to_bytes(32, "big")


def address(value: str) -> bytes:
    raw = bytes.fromhex(value.removeprefix("0x"))
    if len(raw) != 20:
        raise ValueError(f"address must be 20 bytes: {value}")
    return b"\x00" * 12 + raw


def bytes32(value: str | bytes) -> bytes:
    raw = bytes.fromhex(value.removeprefix("0x")) if isinstance(value, str) else value
    if len(raw) != 32:
        raise ValueError(f"bytes32 must be 32 bytes, got {len(raw)}")
    return raw


def encode_bytes32_array(values: list[bytes]) -> bytes:
    return word(32) + word(len(values)) + b"".join(bytes32(value) for value in values)


def hash_type(type_string: str) -> bytes:
    return keccak256(type_string.encode("utf-8"))


def hex32(value: bytes) -> str:
    return "0x" + bytes32(value).hex()


def fixed_hash(*encoded_words: bytes) -> bytes:
    for encoded_word in encoded_words:
        if len(encoded_word) != 32:
            raise ValueError("fixed ABI words must each be 32 bytes")
    return keccak256(b"".join(encoded_words))


def generate_vectors() -> dict[str, str]:
    chain_id = 421_614
    manager = "0x1111111111111111111111111111111111111111"
    controller = "0x2222222222222222222222222222222222222222"
    trader = "0x3333333333333333333333333333333333333333"
    rules_hash = keccak256(b"alphaengine-rules-v1")
    timeframe_key = keccak256(b"1h")
    market_handle = bytes.fromhex("aa" * 32)
    component_handles = [bytes.fromhex("01" * 32), bytes.fromhex("02" * 32), bytes.fromhex("03" * 32)]

    type_strings = {
        "competitionIdTypehash": "AlphaEngineCompetitionIdV1(uint256 chainId,address manager,uint64 competitionNonce,bytes32 rulesHash)",
        "competitionSubmissionIdTypehash": "AlphaEngineCompetitionSubmissionIdV1(uint256 chainId,address manager,bytes32 competitionId,address trader,uint64 traderNonce)",
        "capitalIntentIdTypehash": "AlphaEngineCapitalIntentIdV1(uint256 chainId,address manager,address trader,uint64 traderNonce)",
        "swapIntentIdTypehash": "AlphaEngineSwapIntentIdV1(uint256 chainId,address controller,address trader,uint64 traderNonce)",
        "competitionPayloadTypehash": "AlphaEngineCompetitionPayloadV1(uint256 chainId,address manager,bytes32 submissionId,bytes32 competitionId,address trader,uint64 traderNonce,bytes32 marketIdHandle,bytes32 timeframeKey,uint40 evaluationDeadline,bytes32 componentsHash)",
        "capitalPayloadTypehash": "AlphaEngineCapitalPayloadV1(uint256 chainId,address manager,bytes32 intentId,address trader,uint64 traderNonce,uint64 qualificationVersion,bytes32 marketIdHandle,bytes32 timeframeKey,uint40 deadline,bytes32 componentsHash)",
        "swapPayloadTypehash": "AlphaEngineSwapPayloadV1(uint256 chainId,address controller,bytes32 intentId,address trader,uint64 traderNonce,address escrow,address executor,address inputWrapper,address outputWrapper,bytes32 routeKey,bytes32 executionDataHash,bytes32 minimumOutputCommitment,uint40 deadline,bytes32 lockedAmountHandle,bytes32 unshieldRequestHandle)",
        "callTypehash": "AlphaEngineCallV1(uint256 index,address decoder,address target,uint256 value,bytes32 targetDataHash)",
        "callsTypehash": "AlphaEngineCallsV1(uint256 callCount,bytes32 callHashesHash)",
        "assetDeltaLimitTypehash": "AlphaEngineAssetDeltaLimitV1(uint256 index,address asset,uint256 maxSpend,uint256 minReceive)",
        "riskEnvelopeTypehash": "AlphaEngineRiskEnvelopeV1(uint256 limitCount,bytes32 assetLimitHashesHash,uint256 maxNativeValue)",
        "executionCommitmentTypehash": "AlphaEngineExecutionCommitmentV1(uint256 chainId,address capitalStrategyManager,address vaultExecutionManager,address fundVault,bytes32 intentId,address trader,uint64 qualificationVersion,address executor,uint64 authorizationNonce,uint40 validAfter,uint40 deadline,bytes32 policyRoot,uint64 policyVersion,bytes32 callsHash,bytes32 riskEnvelopeHash,uint64 riskPolicyVersion,bytes32 submissionPayloadHash,bytes32 evaluationEvidenceHash)",
        "swapMinimumOutputTypehash": "AlphaEngineSwapMinimumOutputV1(bytes32 intentId,uint256 minimumOutput,bytes32 salt)",
    }
    typehashes = {name: hash_type(value) for name, value in type_strings.items()}

    competition_id = fixed_hash(
        typehashes["competitionIdTypehash"],
        word(chain_id),
        address(manager),
        word(7),
        rules_hash,
    )
    submission_id = fixed_hash(
        typehashes["competitionSubmissionIdTypehash"],
        word(chain_id),
        address(manager),
        competition_id,
        address(trader),
        word(11),
    )
    capital_intent_id = fixed_hash(
        typehashes["capitalIntentIdTypehash"],
        word(chain_id),
        address(manager),
        address(trader),
        word(13),
    )
    swap_intent_id = fixed_hash(
        typehashes["swapIntentIdTypehash"],
        word(chain_id),
        address(controller),
        address(trader),
        word(17),
    )
    components_hash = keccak256(encode_bytes32_array(component_handles))
    competition_payload_hash = fixed_hash(
        typehashes["competitionPayloadTypehash"],
        word(chain_id),
        address(manager),
        submission_id,
        competition_id,
        address(trader),
        word(11),
        market_handle,
        timeframe_key,
        word(2_000_000_000),
        components_hash,
    )
    capital_payload_hash = fixed_hash(
        typehashes["capitalPayloadTypehash"],
        word(chain_id),
        address(manager),
        capital_intent_id,
        address(trader),
        word(13),
        word(4),
        market_handle,
        timeframe_key,
        word(1_900_004_000),
        components_hash,
    )

    approval_data = bytes.fromhex("095ea7b3") + address("0x6666666666666666666666666666666666666666") + word(12_345)
    pendle_data = bytes.fromhex("12345678") + word(98_765)
    calls = [
        ("0x4444444444444444444444444444444444444444", "0x5555555555555555555555555555555555555555", approval_data),
        ("0x7777777777777777777777777777777777777777", "0x8888888888888888888888888888888888888888", pendle_data),
    ]
    call_hashes = [
        fixed_hash(
            typehashes["callTypehash"],
            word(index),
            address(decoder),
            address(target),
            word(0),
            keccak256(target_data),
        )
        for index, (decoder, target, target_data) in enumerate(calls)
    ]
    calls_hash = fixed_hash(
        typehashes["callsTypehash"],
        word(len(call_hashes)),
        keccak256(encode_bytes32_array(call_hashes)),
    )

    limits = [
        ("0x0000000000000000000000000000000000000010", 1_000_000, 0),
        ("0x0000000000000000000000000000000000000020", 0, 900_000),
    ]
    limit_hashes = [
        fixed_hash(
            typehashes["assetDeltaLimitTypehash"],
            word(index),
            address(asset),
            word(max_spend),
            word(min_receive),
        )
        for index, (asset, max_spend, min_receive) in enumerate(limits)
    ]
    risk_envelope_hash = fixed_hash(
        typehashes["riskEnvelopeTypehash"],
        word(len(limit_hashes)),
        keccak256(encode_bytes32_array(limit_hashes)),
        word(0),
    )

    execution_commitment = fixed_hash(
        typehashes["executionCommitmentTypehash"],
        word(chain_id),
        address(manager),
        address("0x9999999999999999999999999999999999999999"),
        address("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        capital_intent_id,
        address(trader),
        word(4),
        address("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        word(19),
        word(1_900_000_000),
        word(1_900_003_600),
        keccak256(b"policy-root-v1"),
        word(2),
        calls_hash,
        risk_envelope_hash,
        word(3),
        capital_payload_hash,
        keccak256(b"evaluation-evidence-v1"),
    )
    minimum_output_commitment = fixed_hash(
        typehashes["swapMinimumOutputTypehash"],
        swap_intent_id,
        word(99_000),
        bytes.fromhex("cc" * 32),
    )
    swap_payload_hash = fixed_hash(
        typehashes["swapPayloadTypehash"],
        word(chain_id),
        address(controller),
        swap_intent_id,
        address(trader),
        word(17),
        address("0x4444444444444444444444444444444444444444"),
        address("0x5555555555555555555555555555555555555555"),
        address("0x6666666666666666666666666666666666666666"),
        address("0x7777777777777777777777777777777777777777"),
        keccak256(b"uniswap-v4-exact-input"),
        keccak256(b"encoded-v4-route"),
        minimum_output_commitment,
        word(1_900_000_000),
        bytes.fromhex("dd" * 32),
        bytes.fromhex("ee" * 32),
    )

    vectors = {name: hex32(value) for name, value in typehashes.items()}
    vectors.update(
        {
            "keccakEmpty": hex32(keccak256(b"")),
            "rulesHash": hex32(rules_hash),
            "timeframeKey": hex32(timeframe_key),
            "competitionId": hex32(competition_id),
            "competitionSubmissionId": hex32(submission_id),
            "capitalIntentId": hex32(capital_intent_id),
            "swapIntentId": hex32(swap_intent_id),
            "componentsHash": hex32(components_hash),
            "competitionPayloadHash": hex32(competition_payload_hash),
            "capitalPayloadHash": hex32(capital_payload_hash),
            "swapPayloadHash": hex32(swap_payload_hash),
            "call0Hash": hex32(call_hashes[0]),
            "call1Hash": hex32(call_hashes[1]),
            "callsHash": hex32(calls_hash),
            "assetLimit0Hash": hex32(limit_hashes[0]),
            "assetLimit1Hash": hex32(limit_hashes[1]),
            "riskEnvelopeHash": hex32(risk_envelope_hash),
            "executionCommitment": hex32(execution_commitment),
            "swapMinimumOutputCommitment": hex32(minimum_output_commitment),
        }
    )
    return vectors


def rendered_vectors() -> str:
    vectors = generate_vectors()
    expected_empty = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    if vectors["keccakEmpty"] != expected_empty:
        raise RuntimeError("reference Keccak-256 implementation failed its empty-input vector")
    return json.dumps(vectors, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", type=Path)
    mode.add_argument("--write", type=Path)
    args = parser.parse_args()
    rendered = rendered_vectors()

    if args.check is not None:
        existing = args.check.read_text(encoding="utf-8")
        if existing != rendered:
            print(f"hash vector drift: {args.check}", file=sys.stderr)
            return 1
        return 0
    if args.write is not None:
        args.write.write_text(rendered, encoding="utf-8")
        return 0
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
