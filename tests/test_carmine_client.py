from collections.abc import Mapping
from dataclasses import asdict
from typing import Any

import pytest

from sdk import (
    CarmineClient,
    MarketStressInput,
    ValidationError,
    atomic,
    bid_guarantee,
    claim_allocation,
    minimum_next_bid,
    portfolio_stress,
)

ADDRESS = "0x" + "12" * 20
DIGEST = "0x" + "ab" * 32


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def request(
        self,
        method: str,
        path: str,
        *,
        headers: Mapping[str, str],
        body: Mapping[str, Any] | None,
        timeout_seconds: float,
    ) -> Mapping[str, Any]:
        self.calls.append((method, path, dict(headers), body, timeout_seconds))
        return self.responses.pop(0)


def operation_response():
    return {
        "operationId": DIGEST,
        "transactionHash": "0x" + "cd" * 32,
        "acceptedAt": 1_750_000_000,
        "status": "accepted",
    }


def test_health_validates_response_and_authenticates_request():
    transport = FakeTransport(
        [{"version": "1.0.0", "chainId": 1, "synchronized": True, "blockNumber": 22}]
    )
    client = CarmineClient("https://api.carmine.test", api_key="secret", transport=transport)

    health = client.health()

    assert asdict(health) == {
        "version": "1.0.0",
        "chain_id": 1,
        "synchronized": True,
        "block_number": 22,
    }
    assert transport.calls[0][0:2] == ("GET", "/v1/health")
    assert transport.calls[0][2]["Authorization"] == "Bearer secret"


def test_auction_fails_closed_when_identifier_does_not_match():
    transport = FakeTransport(
        [
            {
                "auctionId": 8,
                "status": "active",
                "seller": ADDRESS,
                "collateralToken": ADDRESS,
                "debtToken": ADDRESS,
                "collateralAmount": 100,
                "debtTarget": 90,
                "endTime": 1_750_000_000,
                "minimumNextBid": 90,
                "winningBidder": None,
                "winningBidAmount": 0,
                "winningGuarantee": 0,
                "extensionCount": 0,
            }
        ]
    )
    client = CarmineClient("https://api.carmine.test", transport=transport)

    with pytest.raises(ValidationError, match="does not match"):
        client.auction(7)


def test_quote_uses_encoded_query_and_atomic_amounts():
    transport = FakeTransport(
        [
            {
                "auctionId": 7,
                "amount": 1_000,
                "guarantee": 200,
                "minimumNextBid": 950,
                "validUntil": 1_750_000_100,
                "quoteDigest": DIGEST,
            }
        ]
    )
    client = CarmineClient("https://api.carmine.test", transport=transport)

    quote = client.quote_bid(7, ADDRESS, 1_000)

    assert quote.guarantee == 200
    assert transport.calls[0][1].startswith("/v1/auctions/7/quote?")
    assert "amount=1000" in transport.calls[0][1]


def test_bid_carries_explicit_idempotency_key():
    transport = FakeTransport([operation_response()])
    client = CarmineClient("https://api.carmine.test", transport=transport)

    receipt = client.bid(7, amount=1_000, quote_digest=DIGEST, idempotency_key="bid-00000001")

    assert receipt.status == "accepted"
    assert transport.calls[0][0:2] == ("POST", "/v1/auctions/7/bids")
    assert transport.calls[0][2]["Idempotency-Key"] == "bid-00000001"
    assert transport.calls[0][3] == {"amount": 1_000, "quoteDigest": DIGEST}


def test_operation_response_rejects_malformed_digest():
    response = operation_response()
    response["transactionHash"] = "0x1234"
    client = CarmineClient("https://api.carmine.test", transport=FakeTransport([response]))

    with pytest.raises(ValidationError, match="32-byte"):
        client.settle(9, idempotency_key="settle-0001")


def test_claim_restricts_known_claim_kinds():
    client = CarmineClient("https://api.carmine.test", transport=FakeTransport([]))

    with pytest.raises(ValidationError, match="winner or partial"):
        client.claim(1, claim_kind="unknown")


def test_atomic_rejects_floats_and_excess_precision():
    assert atomic("123.456", 6) == 123_456_000
    assert atomic(9, 18) == 9 * 10**18
    with pytest.raises(ValidationError, match="int or decimal string"):
        atomic(1.5, 18)
    with pytest.raises(ValidationError, match="excess decimal precision"):
        atomic("0.0000001", 6)


def test_auction_math_matches_integer_contract_rules():
    assert minimum_next_bid(0, 900, 500) == 900
    assert minimum_next_bid(1_000, 900, 500) == 1_050
    assert bid_guarantee(1_000, 2_000) == 200
    assert bid_guarantee(1, 1) == 1
    assert claim_allocation(1_000, 3_000) == (700, 300)


def test_portfolio_stress_is_deterministic_and_integer_only():
    markets = [
        MarketStressInput("ETH", 1_800_000, 1_000_000, 1_200, 9_000, 3_600),
        MarketStressInput("RWA", 700_000, 400_000, 700, 8_500, 86_400),
        MarketStressInput("WBTC", 900_000, 600_000, 1_800, 7_500, 14_400),
    ]

    report = portfolio_stress(
        markets,
        shock_bps=2_000,
        slippage_bps=500,
        default_addon_bps=500,
        horizon_seconds=86_400,
        minimum_coverage_bps=7_500,
        maximum_hhi_bps=5_000,
    )

    assert report.total_obligation == 2_100_000
    assert report.total_recovery <= report.total_obligation
    assert report.shortfall == report.total_obligation - report.total_recovery
    assert 0 < report.concentration_hhi_bps <= 10_000
    assert report.weighted_close_seconds > 0


def test_portfolio_stress_requires_canonical_unique_markets():
    markets = [
        MarketStressInput("WBTC", 1_000, 500, 100, 9_000, 100),
        MarketStressInput("ETH", 1_000, 500, 100, 9_000, 100),
    ]

    with pytest.raises(ValidationError, match="canonical"):
        portfolio_stress(
            markets,
            shock_bps=100,
            slippage_bps=100,
            default_addon_bps=100,
            horizon_seconds=1_000,
            minimum_coverage_bps=8_000,
            maximum_hhi_bps=6_000,
        )


def test_client_rejects_unsafe_timeout_and_base_url():
    with pytest.raises(ValidationError, match="timeout"):
        CarmineClient("https://api.carmine.test", timeout_seconds=0)
    with pytest.raises(ValidationError, match="absolute HTTP"):
        CarmineClient("file:///tmp/carmine")
