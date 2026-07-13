# pragma version ^0.4.3

interface IERC20:
    def approve(_spender: address, _amount: uint256) -> bool: nonpayable
    def transfer(_to: address, _amount: uint256) -> bool: nonpayable
    def balanceOf(_owner: address) -> uint256: view

interface ICarmineAuctionHouse:
    def bid(_auction_id: uint256, _amount: uint256): nonpayable
    def snapshot_leader_claim(_auction_id: uint256, _units_bps: uint256): nonpayable
    def claim_partial_collateral(_auction_id: uint256): nonpayable

event Armed:
    auction_id: indexed(uint256)
    units_bps: uint256

event CallbackObserved:
    auction_id: indexed(uint256)
    refund_amount: uint256
    new_bidder: address
    snapshotted: bool

operator: public(address)
auction: public(address)
debt_token: public(address)
collateral_token: public(address)
target_auction: public(uint256)
snapshot_units_bps: public(uint256)
armed: public(bool)
callbacks: public(uint256)
last_refund: public(uint256)
last_new_bidder: public(address)

@deploy
def __init__(_auction: address, _debt_token: address, _collateral_token: address, _operator: address):
    assert _auction != empty(address), "auction"
    assert _debt_token != empty(address), "debt"
    assert _collateral_token != empty(address), "collateral"
    assert _operator != empty(address), "operator"
    self.auction = _auction
    self.debt_token = _debt_token
    self.collateral_token = _collateral_token
    self.operator = _operator

@internal
def _only_operator():
    assert msg.sender == self.operator, "operator"

@external
def approve_auction(_amount: uint256):
    self._only_operator()
    ok: bool = extcall IERC20(self.debt_token).approve(self.auction, _amount)
    assert ok, "approve"

@external
def approve_token(_token: address, _spender: address, _amount: uint256):
    self._only_operator()
    ok: bool = extcall IERC20(_token).approve(_spender, _amount)
    assert ok, "approve"

@external
def place_bid(_auction_id: uint256, _amount: uint256, _units_bps: uint256):
    self._only_operator()
    self.target_auction = _auction_id
    self.snapshot_units_bps = _units_bps
    self.armed = True
    log Armed(auction_id=_auction_id, units_bps=_units_bps)
    extcall ICarmineAuctionHouse(self.auction).bid(_auction_id, _amount)

@external
def disarm():
    self._only_operator()
    self.armed = False

@external
def on_carmine_refund(_auction_id: uint256, _refund_amount: uint256, _new_bidder: address):
    assert msg.sender == self.auction, "auction"
    self.callbacks += 1
    self.last_refund = _refund_amount
    self.last_new_bidder = _new_bidder
    did_snapshot: bool = False
    if self.armed and _auction_id == self.target_auction:
        extcall ICarmineAuctionHouse(self.auction).snapshot_leader_claim(_auction_id, self.snapshot_units_bps)
        self.armed = False
        did_snapshot = True
    log CallbackObserved(
        auction_id=_auction_id,
        refund_amount=_refund_amount,
        new_bidder=_new_bidder,
        snapshotted=did_snapshot
    )

@external
def claim_partial(_auction_id: uint256):
    self._only_operator()
    extcall ICarmineAuctionHouse(self.auction).claim_partial_collateral(_auction_id)

@external
def sweep(_token: address, _to: address, _amount: uint256):
    self._only_operator()
    ok: bool = extcall IERC20(_token).transfer(_to, _amount)
    assert ok, "sweep"

@external
@view
def debt_balance() -> uint256:
    return staticcall IERC20(self.debt_token).balanceOf(self)

@external
@view
def collateral_balance() -> uint256:
    return staticcall IERC20(self.collateral_token).balanceOf(self)

