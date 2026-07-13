# pragma version ^0.4.3

struct RiskTerms:
    collateral_factor_bps: uint256
    liquidation_threshold_bps: uint256
    keeper_discount_bps: uint256
    max_discount_bps: uint256
    volatility_bps: uint256
    stale_after: uint256
    min_debt: uint256
    enabled: bool

event RiskTermsSet:
    market_id: indexed(uint256)
    collateral_factor_bps: uint256
    liquidation_threshold_bps: uint256
    volatility_bps: uint256

event OracleSampleStored:
    market_id: indexed(uint256)
    price: uint256
    timestamp: uint256

BPS: constant(uint256) = 10_000
RAY: constant(uint256) = 10**27

owner: public(address)
terms: public(HashMap[uint256, RiskTerms])
last_price: public(HashMap[uint256, uint256])
last_price_time: public(HashMap[uint256, uint256])
market_debt: public(HashMap[uint256, uint256])
market_collateral: public(HashMap[uint256, uint256])

@deploy
def __init__(_owner: address):
    assert _owner != empty(address), "owner"
    self.owner = _owner

@internal
def _only_owner():
    assert msg.sender == self.owner, "owner"

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.owner = _new_owner

@external
def set_terms(
    _market_id: uint256,
    _collateral_factor_bps: uint256,
    _liquidation_threshold_bps: uint256,
    _keeper_discount_bps: uint256,
    _max_discount_bps: uint256,
    _volatility_bps: uint256,
    _stale_after: uint256,
    _min_debt: uint256,
    _enabled: bool
):
    self._only_owner()
    assert _collateral_factor_bps <= BPS, "factor"
    assert _liquidation_threshold_bps <= BPS, "threshold"
    assert _collateral_factor_bps <= _liquidation_threshold_bps, "order"
    assert _keeper_discount_bps <= _max_discount_bps, "discount"
    assert _max_discount_bps <= 5_000, "max"
    assert _stale_after > 0, "stale"
    self.terms[_market_id] = RiskTerms({
        collateral_factor_bps: _collateral_factor_bps,
        liquidation_threshold_bps: _liquidation_threshold_bps,
        keeper_discount_bps: _keeper_discount_bps,
        max_discount_bps: _max_discount_bps,
        volatility_bps: _volatility_bps,
        stale_after: _stale_after,
        min_debt: _min_debt,
        enabled: _enabled
    })
    log RiskTermsSet(
        market_id=_market_id,
        collateral_factor_bps=_collateral_factor_bps,
        liquidation_threshold_bps=_liquidation_threshold_bps,
        volatility_bps=_volatility_bps
    )

@external
def store_oracle_sample(_market_id: uint256, _price: uint256):
    self._only_owner()
    assert _price > 0, "price"
    self.last_price[_market_id] = _price
    self.last_price_time[_market_id] = block.timestamp
    log OracleSampleStored(market_id=_market_id, price=_price, timestamp=block.timestamp)

@external
def set_market_exposure(_market_id: uint256, _collateral: uint256, _debt: uint256):
    self._only_owner()
    self.market_collateral[_market_id] = _collateral
    self.market_debt[_market_id] = _debt

@external
@view
def collateral_value(_collateral_amount: uint256, _price: uint256) -> uint256:
    return _collateral_amount * _price // 10**18

@external
@view
def borrow_capacity(_market_id: uint256, _collateral_amount: uint256, _price: uint256) -> uint256:
    value: uint256 = _collateral_amount * _price // 10**18
    return value * self.terms[_market_id].collateral_factor_bps // BPS

@external
@view
def liquidation_value(_market_id: uint256, _collateral_amount: uint256, _price: uint256) -> uint256:
    value: uint256 = _collateral_amount * _price // 10**18
    return value * self.terms[_market_id].liquidation_threshold_bps // BPS

@external
@view
def health_factor_ray(_market_id: uint256, _collateral_amount: uint256, _debt: uint256, _price: uint256) -> uint256:
    if _debt == 0:
        return max_value(uint256)
    liq_value: uint256 = _collateral_amount * _price // 10**18
    adjusted: uint256 = liq_value * self.terms[_market_id].liquidation_threshold_bps // BPS
    return adjusted * RAY // _debt

@external
@view
def is_liquidatable(_market_id: uint256, _collateral_amount: uint256, _debt: uint256, _price: uint256) -> bool:
    if not self.terms[_market_id].enabled:
        return False
    if _debt < self.terms[_market_id].min_debt:
        return False
    liq_value: uint256 = _collateral_amount * _price // 10**18
    adjusted: uint256 = liq_value * self.terms[_market_id].liquidation_threshold_bps // BPS
    return adjusted < _debt

@external
@view
def auction_debt_target(_market_id: uint256, _collateral_amount: uint256, _debt: uint256, _price: uint256) -> uint256:
    value: uint256 = _collateral_amount * _price // 10**18
    discount: uint256 = self.terms[_market_id].keeper_discount_bps + self.terms[_market_id].volatility_bps // 10
    if discount > self.terms[_market_id].max_discount_bps:
        discount = self.terms[_market_id].max_discount_bps
    discounted_value: uint256 = value * (BPS - discount) // BPS
    if discounted_value < _debt:
        return discounted_value
    return _debt

@external
@view
def stale_oracle(_market_id: uint256) -> bool:
    t: uint256 = self.last_price_time[_market_id]
    if t == 0:
        return True
    return block.timestamp > t + self.terms[_market_id].stale_after

@external
@view
def exposure_utilization_bps(_market_id: uint256) -> uint256:
    collateral: uint256 = self.market_collateral[_market_id]
    if collateral == 0:
        return 0
    return self.market_debt[_market_id] * BPS // collateral

@external
@view
def risk_bucket(_market_id: uint256, _health_factor_ray: uint256) -> uint256:
    if not self.terms[_market_id].enabled:
        return 0
    if _health_factor_ray < RAY:
        return 5
    if _health_factor_ray < RAY * 105 // 100:
        return 4
    if _health_factor_ray < RAY * 125 // 100:
        return 3
    if _health_factor_ray < RAY * 175 // 100:
        return 2
    return 1

@external
@view
def bid_safety_margin_bps(_market_id: uint256, _bid_amount: uint256, _debt_target: uint256) -> uint256:
    if _debt_target == 0:
        return 0
    if _bid_amount <= _debt_target:
        return 0
    excess: uint256 = _bid_amount - _debt_target
    raw: uint256 = excess * BPS // _debt_target
    if raw > BPS:
        return BPS
    return raw

@external
@view
def expected_guarantee_loss(_guarantee: uint256, _default_probability_bps: uint256) -> uint256:
    assert _default_probability_bps <= BPS, "probability"
    return _guarantee * _default_probability_bps // BPS

@external
@view
def partial_claim_value(_collateral_amount: uint256, _units_bps: uint256, _price: uint256) -> uint256:
    assert _units_bps <= BPS, "units"
    claim_collateral: uint256 = _collateral_amount * _units_bps // BPS
    return claim_collateral * _price // 10**18

@external
@view
def settlement_shortfall(_winner_payment: uint256, _partial_claim_value: uint256, _debt_target: uint256) -> uint256:
    total_value: uint256 = _winner_payment + _partial_claim_value
    if total_value >= _debt_target:
        return 0
    return _debt_target - total_value

@external
@view
def normalize_price(_raw_price: uint256, _raw_decimals: uint256) -> uint256:
    assert _raw_decimals <= 36, "decimals"
    if _raw_decimals == 18:
        return _raw_price
    if _raw_decimals < 18:
        return _raw_price * 10 ** (18 - _raw_decimals)
    return _raw_price // 10 ** (_raw_decimals - 18)

