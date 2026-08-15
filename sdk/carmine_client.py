from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import Request, urlopen
from uuid import uuid4

VERSION = "1.0.0"
BPS = 10_000
MAX_DISCOUNT_BPS = 9_500


class CarmineClientError(RuntimeError):
    pass


class ValidationError(CarmineClientError):
    pass


class TransportError(CarmineClientError):
    pass


class Transport(Protocol):
    def request(
        self,
        method: str,
        path: str,
        *,
        headers: Mapping[str, str],
        body: Mapping[str, Any] | None,
        timeout_seconds: float,
    ) -> Mapping[str, Any]: ...


class UrllibTransport:
    def __init__(self, base_url: str):
        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValidationError("base_url must be an absolute HTTP URL")
        self._base_url = base_url.rstrip("/") + "/"

    def request(
        self,
        method: str,
        path: str,
        *,
        headers: Mapping[str, str],
        body: Mapping[str, Any] | None,
        timeout_seconds: float,
    ) -> Mapping[str, Any]:
        payload = None
        request_headers = dict(headers)
        if body is not None:
            payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        request = Request(
            urljoin(self._base_url, path.lstrip("/")),
            data=payload,
            headers=request_headers,
            method=method,
        )
        try:
            with urlopen(request, timeout=timeout_seconds) as response:
                raw = response.read()
        except HTTPError as error:
            raise TransportError(f"HTTP {error.code} from Carmine API") from error
        except (URLError, TimeoutError, OSError) as error:
            raise TransportError("Carmine API request failed") from error
        try:
            decoded = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise TransportError("Carmine API returned invalid JSON") from error
        if not isinstance(decoded, dict):
            raise TransportError("Carmine API response must be a JSON object")
        return decoded


@dataclass(frozen=True, slots=True)
class HealthStatus:
    version: str
    chain_id: int
    synchronized: bool
    block_number: int


@dataclass(frozen=True, slots=True)
class AuctionSnapshot:
    auction_id: int
    status: str
    seller: str
    collateral_token: str
    debt_token: str
    collateral_amount: int
    debt_target: int
    end_time: int
    minimum_next_bid: int
    winning_bidder: str | None
    winning_bid_amount: int
    winning_guarantee: int
    extension_count: int


@dataclass(frozen=True, slots=True)
class BidQuote:
    auction_id: int
    amount: int
    guarantee: int
    minimum_next_bid: int
    valid_until: int
    quote_digest: str


@dataclass(frozen=True, slots=True)
class OperationReceipt:
    operation_id: str
    transaction_hash: str
    accepted_at: int
    status: str


@dataclass(frozen=True, slots=True)
class MarketStressInput:
    market_id: str
    collateral_value: int
    debt_target: int
    volatility_bps: int
    liquidity_bps: int
    seconds_to_close: int


@dataclass(frozen=True, slots=True)
class PortfolioStressReport:
    total_obligation: int
    total_recovery: int
    surplus: int
    shortfall: int
    coverage_bps: int
    weighted_close_seconds: int
    concentration_hhi_bps: int
    largest_market_share_bps: int
    policy_eligible: bool


def _integer(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"{field} must be an integer")
    if value < minimum:
        raise ValidationError(f"{field} must be at least {minimum}")
    return value


def _string(value: Any, field: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise ValidationError(f"{field} must be a string")
    if not allow_empty and not value:
        raise ValidationError(f"{field} must not be empty")
    return value


def _boolean(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise ValidationError(f"{field} must be a boolean")
    return value


def _address(value: Any, field: str) -> str:
    address = _string(value, field)
    if len(address) != 42 or not address.startswith("0x"):
        raise ValidationError(f"{field} must be a 20-byte hex address")
    try:
        int(address[2:], 16)
    except ValueError as error:
        raise ValidationError(f"{field} must be hexadecimal") from error
    return address


def _digest(value: Any, field: str) -> str:
    digest = _string(value, field)
    if len(digest) != 66 or not digest.startswith("0x"):
        raise ValidationError(f"{field} must be a 32-byte hex digest")
    try:
        int(digest[2:], 16)
    except ValueError as error:
        raise ValidationError(f"{field} must be hexadecimal") from error
    return digest


def _mapping(value: Any, field: str = "response") -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ValidationError(f"{field} must be an object")
    return value


def _optional_address(value: Any, field: str) -> str | None:
    if value is None:
        return None
    return _address(value, field)


def atomic(value: str | int, decimals: int) -> int:
    if isinstance(value, bool) or isinstance(value, float):
        raise ValidationError("atomic values must use int or decimal string")
    _integer(decimals, "decimals")
    if decimals > 36:
        raise ValidationError("decimals must not exceed 36")
    if isinstance(value, int):
        if value < 0:
            raise ValidationError("atomic value must be non-negative")
        return value * 10**decimals
    if not isinstance(value, str) or not value:
        raise ValidationError("atomic value must be an int or decimal string")
    try:
        parsed = Decimal(value)
    except InvalidOperation as error:
        raise ValidationError("atomic value is not decimal") from error
    if not parsed.is_finite() or parsed < 0:
        raise ValidationError("atomic value must be finite and non-negative")
    scaled = parsed * Decimal(10**decimals)
    if scaled != scaled.to_integral_value():
        raise ValidationError("atomic value has excess decimal precision")
    return int(scaled)


def minimum_next_bid(current_bid: int, debt_target: int, increment_bps: int) -> int:
    current_bid = _integer(current_bid, "current_bid")
    debt_target = _integer(debt_target, "debt_target", minimum=1)
    increment_bps = _integer(increment_bps, "increment_bps", minimum=1)
    if increment_bps > BPS:
        raise ValidationError("increment_bps must not exceed 10000")
    if current_bid == 0:
        return debt_target
    increment = current_bid * increment_bps // BPS
    return current_bid + max(increment, 1)


def bid_guarantee(amount: int, guarantee_bps: int) -> int:
    amount = _integer(amount, "amount", minimum=1)
    guarantee_bps = _integer(guarantee_bps, "guarantee_bps", minimum=1)
    if guarantee_bps > BPS:
        raise ValidationError("guarantee_bps must not exceed 10000")
    return max(amount * guarantee_bps // BPS, 1)


def claim_allocation(collateral_amount: int, partial_units_bps: int) -> tuple[int, int]:
    collateral_amount = _integer(collateral_amount, "collateral_amount", minimum=1)
    partial_units_bps = _integer(partial_units_bps, "partial_units_bps")
    if partial_units_bps > BPS:
        raise ValidationError("partial_units_bps must not exceed 10000")
    partial = collateral_amount * partial_units_bps // BPS
    return collateral_amount - partial, partial


def portfolio_stress(
    markets: Sequence[MarketStressInput],
    *,
    shock_bps: int,
    slippage_bps: int,
    default_addon_bps: int,
    horizon_seconds: int,
    minimum_coverage_bps: int,
    maximum_hhi_bps: int,
) -> PortfolioStressReport:
    if not markets or len(markets) > 16:
        raise ValidationError("markets must contain between 1 and 16 entries")
    shock_bps = _integer(shock_bps, "shock_bps")
    slippage_bps = _integer(slippage_bps, "slippage_bps")
    default_addon_bps = _integer(default_addon_bps, "default_addon_bps")
    horizon_seconds = _integer(horizon_seconds, "horizon_seconds")
    minimum_coverage_bps = _integer(minimum_coverage_bps, "minimum_coverage_bps")
    maximum_hhi_bps = _integer(maximum_hhi_bps, "maximum_hhi_bps")
    if any(value > BPS for value in (shock_bps, slippage_bps, default_addon_bps)):
        raise ValidationError("stress basis points must not exceed 10000")
    if maximum_hhi_bps > BPS:
        raise ValidationError("maximum_hhi_bps must not exceed 10000")
    identifiers = [market.market_id for market in markets]
    if identifiers != sorted(identifiers) or len(set(identifiers)) != len(identifiers):
        raise ValidationError("markets must use unique canonical identifiers")

    obligations: list[int] = []
    recoveries: list[int] = []
    for market in markets:
        _string(market.market_id, "market_id")
        collateral = _integer(market.collateral_value, "collateral_value")
        debt = _integer(market.debt_target, "debt_target", minimum=1)
        volatility = _integer(market.volatility_bps, "volatility_bps")
        liquidity = _integer(market.liquidity_bps, "liquidity_bps")
        close = _integer(market.seconds_to_close, "seconds_to_close")
        if volatility > BPS or liquidity > BPS:
            raise ValidationError("market basis points must not exceed 10000")
        obligation = debt + debt * default_addon_bps // BPS
        stressed = collateral * (BPS - shock_bps) // BPS
        discount = min(volatility + slippage_bps, MAX_DISCOUNT_BPS)
        recovery = stressed * (BPS - discount) // BPS
        recovery = recovery * liquidity // BPS
        if close > horizon_seconds:
            recovery = 0 if horizon_seconds == 0 else recovery * horizon_seconds // close
        obligations.append(obligation)
        recoveries.append(min(recovery, obligation))

    total_obligation = sum(obligations)
    total_recovery = sum(recoveries)
    shares = [obligation * BPS // total_obligation for obligation in obligations]
    shortfall = max(total_obligation - total_recovery, 0)
    surplus = max(total_recovery - total_obligation, 0)
    coverage = total_recovery * BPS // total_obligation
    hhi = sum(share * share // BPS for share in shares)
    weighted_close = (
        sum(
            obligation * market.seconds_to_close
            for obligation, market in zip(obligations, markets, strict=True)
        )
        // total_obligation
    )
    return PortfolioStressReport(
        total_obligation=total_obligation,
        total_recovery=total_recovery,
        surplus=surplus,
        shortfall=shortfall,
        coverage_bps=coverage,
        weighted_close_seconds=weighted_close,
        concentration_hhi_bps=hhi,
        largest_market_share_bps=max(shares),
        policy_eligible=(
            coverage >= minimum_coverage_bps and hhi <= maximum_hhi_bps and shortfall == 0
        ),
    )


class CarmineClient:
    def __init__(
        self,
        base_url: str,
        *,
        api_key: str | None = None,
        timeout_seconds: float = 10.0,
        transport: Transport | None = None,
    ):
        if timeout_seconds <= 0 or timeout_seconds > 120:
            raise ValidationError("timeout_seconds must be in (0, 120]")
        self._base_url = base_url
        self._api_key = api_key
        self._timeout_seconds = timeout_seconds
        self._transport = transport or UrllibTransport(base_url)

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: Mapping[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> Mapping[str, Any]:
        if not path.startswith("/") or ".." in path:
            raise ValidationError("path must be absolute and canonical")
        headers = {"Accept": "application/json", "User-Agent": f"carmine-python/{VERSION}"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        response = self._transport.request(
            method,
            path,
            headers=headers,
            body=body,
            timeout_seconds=self._timeout_seconds,
        )
        return _mapping(response)

    def health(self) -> HealthStatus:
        data = self._request("GET", "/v1/health")
        return HealthStatus(
            version=_string(data.get("version"), "version"),
            chain_id=_integer(data.get("chainId"), "chainId", minimum=1),
            synchronized=_boolean(data.get("synchronized"), "synchronized"),
            block_number=_integer(data.get("blockNumber"), "blockNumber"),
        )

    def auction(self, auction_id: int) -> AuctionSnapshot:
        auction_id = _integer(auction_id, "auction_id", minimum=1)
        data = self._request("GET", f"/v1/auctions/{auction_id}")
        response_id = _integer(data.get("auctionId"), "auctionId", minimum=1)
        if response_id != auction_id:
            raise ValidationError("auctionId does not match request")
        return AuctionSnapshot(
            auction_id=response_id,
            status=_string(data.get("status"), "status"),
            seller=_address(data.get("seller"), "seller"),
            collateral_token=_address(data.get("collateralToken"), "collateralToken"),
            debt_token=_address(data.get("debtToken"), "debtToken"),
            collateral_amount=_integer(data.get("collateralAmount"), "collateralAmount", minimum=1),
            debt_target=_integer(data.get("debtTarget"), "debtTarget", minimum=1),
            end_time=_integer(data.get("endTime"), "endTime", minimum=1),
            minimum_next_bid=_integer(data.get("minimumNextBid"), "minimumNextBid", minimum=1),
            winning_bidder=_optional_address(data.get("winningBidder"), "winningBidder"),
            winning_bid_amount=_integer(data.get("winningBidAmount"), "winningBidAmount"),
            winning_guarantee=_integer(data.get("winningGuarantee"), "winningGuarantee"),
            extension_count=_integer(data.get("extensionCount"), "extensionCount"),
        )

    def quote_bid(self, auction_id: int, bidder: str, amount: int) -> BidQuote:
        auction_id = _integer(auction_id, "auction_id", minimum=1)
        bidder = _address(bidder, "bidder")
        amount = _integer(amount, "amount", minimum=1)
        query = urlencode({"bidder": bidder, "amount": str(amount)})
        data = self._request("GET", f"/v1/auctions/{auction_id}/quote?{query}")
        return BidQuote(
            auction_id=_integer(data.get("auctionId"), "auctionId", minimum=1),
            amount=_integer(data.get("amount"), "amount", minimum=1),
            guarantee=_integer(data.get("guarantee"), "guarantee", minimum=1),
            minimum_next_bid=_integer(data.get("minimumNextBid"), "minimumNextBid", minimum=1),
            valid_until=_integer(data.get("validUntil"), "validUntil", minimum=1),
            quote_digest=_digest(data.get("quoteDigest"), "quoteDigest"),
        )

    def create_auction(
        self,
        *,
        market: str,
        collateral_amount: int,
        debt_target: int,
        lot_id: str,
        idempotency_key: str | None = None,
    ) -> OperationReceipt:
        market = _string(market, "market")
        collateral_amount = _integer(collateral_amount, "collateral_amount", minimum=1)
        debt_target = _integer(debt_target, "debt_target", minimum=1)
        lot_id = _digest(lot_id, "lot_id")
        return self._operation(
            "/v1/auctions",
            {
                "market": market,
                "collateralAmount": collateral_amount,
                "debtTarget": debt_target,
                "lotId": lot_id,
            },
            idempotency_key,
        )

    def bid(
        self,
        auction_id: int,
        *,
        amount: int,
        quote_digest: str,
        idempotency_key: str | None = None,
    ) -> OperationReceipt:
        auction_id = _integer(auction_id, "auction_id", minimum=1)
        amount = _integer(amount, "amount", minimum=1)
        quote_digest = _digest(quote_digest, "quote_digest")
        return self._operation(
            f"/v1/auctions/{auction_id}/bids",
            {"amount": amount, "quoteDigest": quote_digest},
            idempotency_key,
        )

    def settle(self, auction_id: int, *, idempotency_key: str | None = None) -> OperationReceipt:
        auction_id = _integer(auction_id, "auction_id", minimum=1)
        return self._operation(
            f"/v1/auctions/{auction_id}/settlement",
            {},
            idempotency_key,
        )

    def claim(
        self,
        auction_id: int,
        *,
        claim_kind: str,
        idempotency_key: str | None = None,
    ) -> OperationReceipt:
        auction_id = _integer(auction_id, "auction_id", minimum=1)
        if claim_kind not in {"winner", "partial"}:
            raise ValidationError("claim_kind must be winner or partial")
        return self._operation(
            f"/v1/auctions/{auction_id}/claims",
            {"kind": claim_kind},
            idempotency_key,
        )

    def _operation(
        self,
        path: str,
        body: Mapping[str, Any],
        idempotency_key: str | None,
    ) -> OperationReceipt:
        key = idempotency_key or str(uuid4())
        if len(key) < 8 or len(key) > 128:
            raise ValidationError("idempotency_key must contain 8 to 128 characters")
        data = self._request("POST", path, body=body, idempotency_key=key)
        return OperationReceipt(
            operation_id=_digest(data.get("operationId"), "operationId"),
            transaction_hash=_digest(data.get("transactionHash"), "transactionHash"),
            accepted_at=_integer(data.get("acceptedAt"), "acceptedAt", minimum=1),
            status=_string(data.get("status"), "status"),
        )
