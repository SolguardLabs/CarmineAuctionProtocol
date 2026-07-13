# pragma version ^0.4.3

struct MarketConfig:
    collateral_token: address
    debt_token: address
    keeper: address
    duration: uint256
    extension_window: uint256
    extension_duration: uint256
    min_increment_bps: uint256
    guarantee_bps: uint256
    partial_claim_bps: uint256
    liquidation_bonus_bps: uint256
    max_lot_value: uint256
    enabled: bool

event OwnerTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

event GuardianUpdated:
    guardian: indexed(address)
    allowed: bool

event MarketConfigured:
    market_id: indexed(uint256)
    collateral_token: indexed(address)
    debt_token: indexed(address)
    enabled: bool

event MarketToggled:
    market_id: indexed(uint256)
    enabled: bool

event GlobalPauseUpdated:
    paused: bool

BPS: constant(uint256) = 10_000
MAX_MARKETS: constant(uint256) = 256

owner: public(address)
pending_owner: public(address)
paused: public(bool)
next_market_id: public(uint256)
markets: public(HashMap[uint256, MarketConfig])
market_by_pair: public(HashMap[address, HashMap[address, uint256]])
guardians: public(HashMap[address, bool])

@deploy
def __init__(_owner: address):
    assert _owner != empty(address), "owner"
    self.owner = _owner
    self.guardians[_owner] = True
    self.next_market_id = 1
    log OwnerTransferred(previous_owner=empty(address), new_owner=_owner)
    log GuardianUpdated(guardian=_owner, allowed=True)

@internal
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
def _only_guardian():
    assert msg.sender == self.owner or self.guardians[msg.sender], "guardian"

@internal
@view
def _valid_market_terms(
    _duration: uint256,
    _extension_window: uint256,
    _extension_duration: uint256,
    _min_increment_bps: uint256,
    _guarantee_bps: uint256,
    _partial_claim_bps: uint256,
    _liquidation_bonus_bps: uint256
) -> bool:
    if _duration == 0:
        return False
    if _extension_window > _duration:
        return False
    if _extension_duration == 0:
        return False
    if _min_increment_bps == 0 or _min_increment_bps > BPS:
        return False
    if _guarantee_bps == 0 or _guarantee_bps > BPS:
        return False
    if _partial_claim_bps > BPS:
        return False
    if _liquidation_bonus_bps > 5_000:
        return False
    return True

@external
def set_guardian(_guardian: address, _allowed: bool):
    self._only_owner()
    assert _guardian != empty(address), "guardian"
    self.guardians[_guardian] = _allowed
    log GuardianUpdated(guardian=_guardian, allowed=_allowed)

@external
def set_paused(_paused: bool):
    self._only_guardian()
    self.paused = _paused
    log GlobalPauseUpdated(paused=_paused)

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.pending_owner = _new_owner

@external
def accept_ownership():
    assert msg.sender == self.pending_owner, "pending"
    previous: address = self.owner
    self.owner = msg.sender
    self.pending_owner = empty(address)
    self.guardians[msg.sender] = True
    log OwnerTransferred(previous_owner=previous, new_owner=msg.sender)
    log GuardianUpdated(guardian=msg.sender, allowed=True)

@external
def configure_market(
    _collateral_token: address,
    _debt_token: address,
    _keeper: address,
    _duration: uint256,
    _extension_window: uint256,
    _extension_duration: uint256,
    _min_increment_bps: uint256,
    _guarantee_bps: uint256,
    _partial_claim_bps: uint256,
    _liquidation_bonus_bps: uint256,
    _max_lot_value: uint256,
    _enabled: bool
) -> uint256:
    self._only_owner()
    assert _collateral_token != empty(address), "collateral"
    assert _debt_token != empty(address), "debt"
    assert self._valid_market_terms(
        _duration,
        _extension_window,
        _extension_duration,
        _min_increment_bps,
        _guarantee_bps,
        _partial_claim_bps,
        _liquidation_bonus_bps
    ), "terms"
    market_id: uint256 = self.market_by_pair[_collateral_token][_debt_token]
    if market_id == 0:
        market_id = self.next_market_id
        assert market_id <= MAX_MARKETS, "markets"
        self.next_market_id = market_id + 1
        self.market_by_pair[_collateral_token][_debt_token] = market_id
    self.markets[market_id] = MarketConfig({
        collateral_token: _collateral_token,
        debt_token: _debt_token,
        keeper: _keeper,
        duration: _duration,
        extension_window: _extension_window,
        extension_duration: _extension_duration,
        min_increment_bps: _min_increment_bps,
        guarantee_bps: _guarantee_bps,
        partial_claim_bps: _partial_claim_bps,
        liquidation_bonus_bps: _liquidation_bonus_bps,
        max_lot_value: _max_lot_value,
        enabled: _enabled
    })
    log MarketConfigured(
        market_id=market_id,
        collateral_token=_collateral_token,
        debt_token=_debt_token,
        enabled=_enabled
    )
    return market_id

@external
def set_market_enabled(_market_id: uint256, _enabled: bool):
    self._only_guardian()
    assert self.markets[_market_id].collateral_token != empty(address), "market"
    self.markets[_market_id].enabled = _enabled
    log MarketToggled(market_id=_market_id, enabled=_enabled)

@external
def set_market_keeper(_market_id: uint256, _keeper: address):
    self._only_owner()
    assert self.markets[_market_id].collateral_token != empty(address), "market"
    self.markets[_market_id].keeper = _keeper

@external
def set_market_caps(_market_id: uint256, _max_lot_value: uint256, _partial_claim_bps: uint256):
    self._only_owner()
    assert self.markets[_market_id].collateral_token != empty(address), "market"
    assert _partial_claim_bps <= BPS, "partial"
    self.markets[_market_id].max_lot_value = _max_lot_value
    self.markets[_market_id].partial_claim_bps = _partial_claim_bps

@external
@view
def terms_for_pair(_collateral_token: address, _debt_token: address) -> MarketConfig:
    market_id: uint256 = self.market_by_pair[_collateral_token][_debt_token]
    return self.markets[market_id]

@external
@view
def can_start_auction(_market_id: uint256, _lot_value: uint256, _caller: address) -> bool:
    if self.paused:
        return False
    cfg: MarketConfig = self.markets[_market_id]
    if not cfg.enabled:
        return False
    if cfg.collateral_token == empty(address):
        return False
    if cfg.max_lot_value > 0 and _lot_value > cfg.max_lot_value:
        return False
    if cfg.keeper != empty(address) and _caller != cfg.keeper and _caller != self.owner:
        return False
    return True

@external
@view
def preview_liquidation_debt(_oracle_value: uint256, _bonus_bps: uint256) -> uint256:
    assert _bonus_bps <= 5_000, "bonus"
    return _oracle_value * (BPS + _bonus_bps) // BPS

@external
@view
def preview_guarantee(_bid_amount: uint256, _guarantee_bps: uint256) -> uint256:
    assert _guarantee_bps <= BPS, "guarantee"
    result: uint256 = _bid_amount * _guarantee_bps // BPS
    if result == 0 and _bid_amount > 0:
        return 1
    return result

@external
@view
def preview_min_next_bid(_current_bid: uint256, _min_increment_bps: uint256, _debt_target: uint256) -> uint256:
    if _current_bid == 0:
        return _debt_target
    inc: uint256 = _current_bid * _min_increment_bps // BPS
    if inc == 0:
        inc = 1
    return _current_bid + inc

