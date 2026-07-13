# pragma version ^0.4.3

interface IERC20:
    def transfer(_to: address, _amount: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _amount: uint256) -> bool: nonpayable
    def balanceOf(_owner: address) -> uint256: view

interface IRefundReceiver:
    def on_carmine_refund(_auction_id: uint256, _refund_amount: uint256, _new_bidder: address): nonpayable

struct Auction:
    seller: address
    collateral_token: address
    debt_token: address
    lot_id: bytes32
    collateral_amount: uint256
    debt_target: uint256
    start_time: uint256
    end_time: uint256
    extension_window: uint256
    extension_duration: uint256
    min_increment_bps: uint256
    guarantee_bps: uint256
    partial_claim_bps: uint256
    status: uint256
    winning_bidder: address
    winning_bid_amount: uint256
    winning_guarantee: uint256
    last_bid_time: uint256
    extension_count: uint256
    refund_epoch: uint256
    total_partial_units: uint256
    total_partial_claimed: uint256
    debt_settled: bool
    winner_claimed: bool

event AuctionCreated:
    auction_id: indexed(uint256)
    seller: indexed(address)
    collateral_token: address
    debt_token: address
    collateral_amount: uint256
    debt_target: uint256
    end_time: uint256

event BidPlaced:
    auction_id: indexed(uint256)
    bidder: indexed(address)
    amount: uint256
    guarantee: uint256
    previous_bidder: address
    extended: bool

event PreviousBidderRefunded:
    auction_id: indexed(uint256)
    bidder: indexed(address)
    refund_amount: uint256
    refund_epoch: uint256

event LeaderClaimSnapshotted:
    auction_id: indexed(uint256)
    bidder: indexed(address)
    units_bps: uint256
    total_units_bps: uint256

event AuctionSettled:
    auction_id: indexed(uint256)
    winner: indexed(address)
    debt_paid: uint256
    seller: address

event CollateralClaimed:
    auction_id: indexed(uint256)
    claimant: indexed(address)
    amount: uint256
    kind: uint256

event AuctionCancelled:
    auction_id: indexed(uint256)
    seller: indexed(address)
    collateral_returned: uint256

BPS: constant(uint256) = 10_000
STATUS_NONE: constant(uint256) = 0
STATUS_ACTIVE: constant(uint256) = 1
STATUS_SETTLED: constant(uint256) = 2
STATUS_CANCELLED: constant(uint256) = 3
CLAIM_KIND_WINNER: constant(uint256) = 1
CLAIM_KIND_PARTIAL: constant(uint256) = 2

owner: public(address)
next_auction_id: public(uint256)
auctions: public(HashMap[uint256, Auction])
partial_claim_units: public(HashMap[uint256, HashMap[address, uint256]])
partial_claimed: public(HashMap[uint256, HashMap[address, bool]])
bid_count: public(HashMap[uint256, uint256])
bidder_high_water: public(HashMap[uint256, HashMap[address, uint256]])
bidder_refunds: public(HashMap[uint256, HashMap[address, uint256]])
paused: public(bool)

@deploy
def __init__(_owner: address):
    assert _owner != empty(address), "owner"
    self.owner = _owner
    self.next_auction_id = 1

@internal
def _only_owner():
    assert msg.sender == self.owner, "only owner"

@internal
@view
def _is_active(_auction_id: uint256) -> bool:
    return self.auctions[_auction_id].status == STATUS_ACTIVE

@internal
@view
def _current_min_bid(_auction_id: uint256) -> uint256:
    current: uint256 = self.auctions[_auction_id].winning_bid_amount
    if current == 0:
        return self.auctions[_auction_id].debt_target
    inc: uint256 = current * self.auctions[_auction_id].min_increment_bps // BPS
    if inc == 0:
        inc = 1
    return current + inc

@internal
@view
def _guarantee_for(_auction_id: uint256, _amount: uint256) -> uint256:
    g: uint256 = _amount * self.auctions[_auction_id].guarantee_bps // BPS
    if g == 0:
        g = 1
    return g

@internal
@view
def _near_close(_auction_id: uint256) -> bool:
    end_time: uint256 = self.auctions[_auction_id].end_time
    window: uint256 = self.auctions[_auction_id].extension_window
    if block.timestamp >= end_time:
        return True
    return block.timestamp + window >= end_time

@internal
@view
def _partial_collateral_for_units(_auction_id: uint256, _units: uint256) -> uint256:
    return self.auctions[_auction_id].collateral_amount * _units // BPS

@external
def set_paused(_paused: bool):
    self._only_owner()
    self.paused = _paused

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.owner = _new_owner

@external
def create_auction(
    _collateral_token: address,
    _debt_token: address,
    _lot_id: bytes32,
    _collateral_amount: uint256,
    _debt_target: uint256,
    _duration: uint256,
    _extension_window: uint256,
    _extension_duration: uint256,
    _min_increment_bps: uint256,
    _guarantee_bps: uint256,
    _partial_claim_bps: uint256
) -> uint256:
    assert not self.paused, "paused"
    assert _collateral_token != empty(address), "collateral"
    assert _debt_token != empty(address), "debt"
    assert _collateral_amount > 0, "lot"
    assert _debt_target > 0, "target"
    assert _duration > 0, "duration"
    assert _extension_window <= _duration, "window"
    assert _extension_duration > 0, "extension"
    assert _min_increment_bps > 0 and _min_increment_bps <= BPS, "increment"
    assert _guarantee_bps > 0 and _guarantee_bps <= BPS, "guarantee"
    assert _partial_claim_bps <= BPS, "partial"
    ok: bool = extcall IERC20(_collateral_token).transferFrom(msg.sender, self, _collateral_amount)
    assert ok, "collateral transfer"
    auction_id: uint256 = self.next_auction_id
    self.next_auction_id = auction_id + 1
    self.auctions[auction_id] = Auction({
        seller: msg.sender,
        collateral_token: _collateral_token,
        debt_token: _debt_token,
        lot_id: _lot_id,
        collateral_amount: _collateral_amount,
        debt_target: _debt_target,
        start_time: block.timestamp,
        end_time: block.timestamp + _duration,
        extension_window: _extension_window,
        extension_duration: _extension_duration,
        min_increment_bps: _min_increment_bps,
        guarantee_bps: _guarantee_bps,
        partial_claim_bps: _partial_claim_bps,
        status: STATUS_ACTIVE,
        winning_bidder: empty(address),
        winning_bid_amount: 0,
        winning_guarantee: 0,
        last_bid_time: 0,
        extension_count: 0,
        refund_epoch: 0,
        total_partial_units: 0,
        total_partial_claimed: 0,
        debt_settled: False,
        winner_claimed: False
    })
    log AuctionCreated(
        auction_id=auction_id,
        seller=msg.sender,
        collateral_token=_collateral_token,
        debt_token=_debt_token,
        collateral_amount=_collateral_amount,
        debt_target=_debt_target,
        end_time=block.timestamp + _duration
    )
    return auction_id

@external
def bid(_auction_id: uint256, _amount: uint256):
    assert not self.paused, "paused"
    assert self._is_active(_auction_id), "auction"
    assert block.timestamp < self.auctions[_auction_id].end_time, "ended"
    min_bid: uint256 = self._current_min_bid(_auction_id)
    assert _amount >= min_bid, "bid low"
    guarantee: uint256 = self._guarantee_for(_auction_id, _amount)
    token: address = self.auctions[_auction_id].debt_token
    ok: bool = extcall IERC20(token).transferFrom(msg.sender, self, guarantee)
    assert ok, "guarantee"
    previous_bidder: address = self.auctions[_auction_id].winning_bidder
    previous_guarantee: uint256 = self.auctions[_auction_id].winning_guarantee
    was_extended: bool = False
    if previous_bidder != empty(address):
        refund_ok: bool = extcall IERC20(token).transfer(previous_bidder, previous_guarantee)
        assert refund_ok, "refund"
        self.auctions[_auction_id].refund_epoch += 1
        self.bidder_refunds[_auction_id][previous_bidder] += previous_guarantee
        log PreviousBidderRefunded(
            auction_id=_auction_id,
            bidder=previous_bidder,
            refund_amount=previous_guarantee,
            refund_epoch=self.auctions[_auction_id].refund_epoch
        )
        callback_success: bool = raw_call(
            previous_bidder,
            abi_encode(
                _auction_id,
                previous_guarantee,
                msg.sender,
                method_id=method_id("on_carmine_refund(uint256,uint256,address)")
            ),
            max_outsize=0,
            revert_on_failure=False
        )
    self.auctions[_auction_id].winning_bidder = msg.sender
    self.auctions[_auction_id].winning_bid_amount = _amount
    self.auctions[_auction_id].winning_guarantee = guarantee
    self.auctions[_auction_id].last_bid_time = block.timestamp
    self.bid_count[_auction_id] += 1
    if _amount > self.bidder_high_water[_auction_id][msg.sender]:
        self.bidder_high_water[_auction_id][msg.sender] = _amount
    if self._near_close(_auction_id):
        self.auctions[_auction_id].end_time += self.auctions[_auction_id].extension_duration
        self.auctions[_auction_id].extension_count += 1
        was_extended = True
    log BidPlaced(
        auction_id=_auction_id,
        bidder=msg.sender,
        amount=_amount,
        guarantee=guarantee,
        previous_bidder=previous_bidder,
        extended=was_extended
    )

@external
def snapshot_leader_claim(_auction_id: uint256, _units_bps: uint256):
    assert self._is_active(_auction_id), "auction"
    assert msg.sender == self.auctions[_auction_id].winning_bidder, "leader"
    assert self._near_close(_auction_id), "window"
    assert _units_bps > 0, "units"
    current: uint256 = self.partial_claim_units[_auction_id][msg.sender]
    new_units: uint256 = current + _units_bps
    assert new_units <= self.auctions[_auction_id].partial_claim_bps, "bidder cap"
    assert self.auctions[_auction_id].total_partial_units + _units_bps <= BPS, "lot cap"
    self.partial_claim_units[_auction_id][msg.sender] = new_units
    self.auctions[_auction_id].total_partial_units += _units_bps
    log LeaderClaimSnapshotted(
        auction_id=_auction_id,
        bidder=msg.sender,
        units_bps=_units_bps,
        total_units_bps=self.auctions[_auction_id].total_partial_units
    )

@external
def settle(_auction_id: uint256):
    assert self._is_active(_auction_id), "auction"
    assert block.timestamp >= self.auctions[_auction_id].end_time, "not ended"
    winner: address = self.auctions[_auction_id].winning_bidder
    assert winner != empty(address), "no bids"
    assert msg.sender == winner, "winner"
    assert not self.auctions[_auction_id].debt_settled, "settled"
    token: address = self.auctions[_auction_id].debt_token
    due: uint256 = self.auctions[_auction_id].winning_bid_amount - self.auctions[_auction_id].winning_guarantee
    if due > 0:
        pull_ok: bool = extcall IERC20(token).transferFrom(msg.sender, self, due)
        assert pull_ok, "debt pull"
    pay_ok: bool = extcall IERC20(token).transfer(self.auctions[_auction_id].seller, self.auctions[_auction_id].winning_bid_amount)
    assert pay_ok, "debt pay"
    self.auctions[_auction_id].debt_settled = True
    self.auctions[_auction_id].status = STATUS_SETTLED
    log AuctionSettled(
        auction_id=_auction_id,
        winner=winner,
        debt_paid=self.auctions[_auction_id].winning_bid_amount,
        seller=self.auctions[_auction_id].seller
    )

@external
def claim_winner_collateral(_auction_id: uint256):
    assert self.auctions[_auction_id].status == STATUS_SETTLED, "settled"
    assert msg.sender == self.auctions[_auction_id].winning_bidder, "winner"
    assert not self.auctions[_auction_id].winner_claimed, "claimed"
    reserved: uint256 = self._partial_collateral_for_units(_auction_id, self.auctions[_auction_id].total_partial_units)
    amount: uint256 = self.auctions[_auction_id].collateral_amount - reserved
    self.auctions[_auction_id].winner_claimed = True
    ok: bool = extcall IERC20(self.auctions[_auction_id].collateral_token).transfer(msg.sender, amount)
    assert ok, "collateral"
    log CollateralClaimed(auction_id=_auction_id, claimant=msg.sender, amount=amount, kind=CLAIM_KIND_WINNER)

@external
def claim_partial_collateral(_auction_id: uint256):
    assert self.auctions[_auction_id].status == STATUS_SETTLED, "settled"
    assert not self.partial_claimed[_auction_id][msg.sender], "claimed"
    units: uint256 = self.partial_claim_units[_auction_id][msg.sender]
    assert units > 0, "units"
    amount: uint256 = self._partial_collateral_for_units(_auction_id, units)
    self.partial_claimed[_auction_id][msg.sender] = True
    self.auctions[_auction_id].total_partial_claimed += amount
    ok: bool = extcall IERC20(self.auctions[_auction_id].collateral_token).transfer(msg.sender, amount)
    assert ok, "partial collateral"
    log CollateralClaimed(auction_id=_auction_id, claimant=msg.sender, amount=amount, kind=CLAIM_KIND_PARTIAL)

@external
def cancel_auction(_auction_id: uint256):
    assert self._is_active(_auction_id), "auction"
    assert msg.sender == self.auctions[_auction_id].seller or msg.sender == self.owner, "auth"
    assert self.auctions[_auction_id].winning_bidder == empty(address), "has bid"
    self.auctions[_auction_id].status = STATUS_CANCELLED
    ok: bool = extcall IERC20(self.auctions[_auction_id].collateral_token).transfer(
        self.auctions[_auction_id].seller,
        self.auctions[_auction_id].collateral_amount
    )
    assert ok, "return"
    log AuctionCancelled(
        auction_id=_auction_id,
        seller=self.auctions[_auction_id].seller,
        collateral_returned=self.auctions[_auction_id].collateral_amount
    )

@external
@view
def min_next_bid(_auction_id: uint256) -> uint256:
    return self._current_min_bid(_auction_id)

@external
@view
def guarantee_for_bid(_auction_id: uint256, _amount: uint256) -> uint256:
    return self._guarantee_for(_auction_id, _amount)

@external
@view
def is_near_close(_auction_id: uint256) -> bool:
    return self._near_close(_auction_id)

@external
@view
def preview_winner_collateral(_auction_id: uint256) -> uint256:
    reserved: uint256 = self._partial_collateral_for_units(_auction_id, self.auctions[_auction_id].total_partial_units)
    return self.auctions[_auction_id].collateral_amount - reserved

@external
@view
def preview_partial_collateral(_auction_id: uint256, _bidder: address) -> uint256:
    return self._partial_collateral_for_units(_auction_id, self.partial_claim_units[_auction_id][_bidder])

@external
@view
def unpaid_settlement_amount(_auction_id: uint256) -> uint256:
    if self.auctions[_auction_id].winning_bid_amount <= self.auctions[_auction_id].winning_guarantee:
        return 0
    return self.auctions[_auction_id].winning_bid_amount - self.auctions[_auction_id].winning_guarantee

@external
@view
def auction_phase(_auction_id: uint256) -> uint256:
    status: uint256 = self.auctions[_auction_id].status
    if status != STATUS_ACTIVE:
        return status
    if block.timestamp < self.auctions[_auction_id].end_time:
        return STATUS_ACTIVE
    return 4

@external
@view
def collateral_balance() -> uint256:
    return 0
