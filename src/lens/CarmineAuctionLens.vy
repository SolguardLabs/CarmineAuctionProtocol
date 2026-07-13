# pragma version ^0.4.3

interface IAuctionHouse:
    def min_next_bid(_auction_id: uint256) -> uint256: view
    def guarantee_for_bid(_auction_id: uint256, _amount: uint256) -> uint256: view
    def is_near_close(_auction_id: uint256) -> bool: view
    def preview_winner_collateral(_auction_id: uint256) -> uint256: view
    def preview_partial_collateral(_auction_id: uint256, _bidder: address) -> uint256: view
    def unpaid_settlement_amount(_auction_id: uint256) -> uint256: view
    def bid_count(_auction_id: uint256) -> uint256: view
    def partial_claim_units(_auction_id: uint256, _bidder: address) -> uint256: view
    def bidder_refunds(_auction_id: uint256, _bidder: address) -> uint256: view
    def bidder_high_water(_auction_id: uint256, _bidder: address) -> uint256: view

struct BidderView:
    high_water_bid: uint256
    refunded_guarantee: uint256
    partial_units_bps: uint256
    partial_collateral: uint256
    next_bid_guarantee: uint256
    can_snapshot_near_close: bool

struct AuctionView:
    min_next_bid: uint256
    bid_count: uint256
    unpaid_settlement: uint256
    winner_collateral: uint256
    near_close: bool
    sample_bid_guarantee: uint256

owner: public(address)
trusted_auction: public(address)
last_sampled_auction: public(uint256)
last_sampled_bid: public(uint256)
last_sampled_guarantee: public(uint256)

event TrustedAuctionUpdated:
    auction: indexed(address)

event SampleStored:
    auction_id: indexed(uint256)
    bid_amount: uint256
    guarantee: uint256

@deploy
def __init__(_owner: address):
    assert _owner != empty(address), "owner"
    self.owner = _owner

@internal
def _only_owner():
    assert msg.sender == self.owner, "owner"

@external
def set_trusted_auction(_auction: address):
    self._only_owner()
    assert _auction != empty(address), "auction"
    self.trusted_auction = _auction
    log TrustedAuctionUpdated(auction=_auction)

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.owner = _new_owner

@external
def store_sample(_auction_id: uint256, _bid_amount: uint256):
    assert self.trusted_auction != empty(address), "auction"
    guarantee: uint256 = staticcall IAuctionHouse(self.trusted_auction).guarantee_for_bid(_auction_id, _bid_amount)
    self.last_sampled_auction = _auction_id
    self.last_sampled_bid = _bid_amount
    self.last_sampled_guarantee = guarantee
    log SampleStored(auction_id=_auction_id, bid_amount=_bid_amount, guarantee=guarantee)

@external
@view
def auction_view(_auction: address, _auction_id: uint256, _sample_bid: uint256) -> AuctionView:
    return AuctionView({
        min_next_bid: staticcall IAuctionHouse(_auction).min_next_bid(_auction_id),
        bid_count: staticcall IAuctionHouse(_auction).bid_count(_auction_id),
        unpaid_settlement: staticcall IAuctionHouse(_auction).unpaid_settlement_amount(_auction_id),
        winner_collateral: staticcall IAuctionHouse(_auction).preview_winner_collateral(_auction_id),
        near_close: staticcall IAuctionHouse(_auction).is_near_close(_auction_id),
        sample_bid_guarantee: staticcall IAuctionHouse(_auction).guarantee_for_bid(_auction_id, _sample_bid)
    })

@external
@view
def bidder_view(_auction: address, _auction_id: uint256, _bidder: address, _sample_bid: uint256) -> BidderView:
    return BidderView({
        high_water_bid: staticcall IAuctionHouse(_auction).bidder_high_water(_auction_id, _bidder),
        refunded_guarantee: staticcall IAuctionHouse(_auction).bidder_refunds(_auction_id, _bidder),
        partial_units_bps: staticcall IAuctionHouse(_auction).partial_claim_units(_auction_id, _bidder),
        partial_collateral: staticcall IAuctionHouse(_auction).preview_partial_collateral(_auction_id, _bidder),
        next_bid_guarantee: staticcall IAuctionHouse(_auction).guarantee_for_bid(_auction_id, _sample_bid),
        can_snapshot_near_close: staticcall IAuctionHouse(_auction).is_near_close(_auction_id)
    })

@external
@view
def guarantee_delta(_auction: address, _auction_id: uint256, _low_bid: uint256, _high_bid: uint256) -> int256:
    low: uint256 = staticcall IAuctionHouse(_auction).guarantee_for_bid(_auction_id, _low_bid)
    high: uint256 = staticcall IAuctionHouse(_auction).guarantee_for_bid(_auction_id, _high_bid)
    if high >= low:
        return convert(high - low, int256)
    return -convert(low - high, int256)

@external
@view
def partial_claim_pressure_bps(_auction: address, _auction_id: uint256, _bidder: address, _collateral_amount: uint256) -> uint256:
    if _collateral_amount == 0:
        return 0
    partial: uint256 = staticcall IAuctionHouse(_auction).preview_partial_collateral(_auction_id, _bidder)
    return partial * 10_000 // _collateral_amount

@external
@view
def can_settle_from_lens(_auction: address, _auction_id: uint256) -> bool:
    return staticcall IAuctionHouse(_auction).unpaid_settlement_amount(_auction_id) > 0

