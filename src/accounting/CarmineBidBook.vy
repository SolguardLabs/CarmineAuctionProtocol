# pragma version ^0.4.3

struct BidRecord:
    auction_id: uint256
    bidder: address
    amount: uint256
    guarantee: uint256
    timestamp: uint256
    refund_epoch: uint256
    was_winner: bool
    was_refunded: bool

event RecorderUpdated:
    recorder: indexed(address)
    allowed: bool

event BidRecorded:
    record_id: indexed(uint256)
    auction_id: indexed(uint256)
    bidder: indexed(address)
    amount: uint256
    guarantee: uint256

event BidRefundMarked:
    record_id: indexed(uint256)
    bidder: indexed(address)
    guarantee: uint256

owner: public(address)
next_record_id: public(uint256)
recorders: public(HashMap[address, bool])
records: public(HashMap[uint256, BidRecord])
latest_record_for_bidder: public(HashMap[uint256, HashMap[address, uint256]])
auction_record_count: public(HashMap[uint256, uint256])
auction_total_bid_amount: public(HashMap[uint256, uint256])
auction_total_guarantees: public(HashMap[uint256, uint256])
auction_total_refunded: public(HashMap[uint256, uint256])
bidder_total_bid_amount: public(HashMap[address, uint256])
bidder_total_refunded: public(HashMap[address, uint256])

@deploy
def __init__(_owner: address):
    assert _owner != empty(address), "owner"
    self.owner = _owner
    self.next_record_id = 1
    self.recorders[_owner] = True
    log RecorderUpdated(recorder=_owner, allowed=True)

@internal
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
def _only_recorder():
    assert self.recorders[msg.sender], "recorder"

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.owner = _new_owner
    self.recorders[_new_owner] = True
    log RecorderUpdated(recorder=_new_owner, allowed=True)

@external
def set_recorder(_recorder: address, _allowed: bool):
    self._only_owner()
    assert _recorder != empty(address), "recorder"
    self.recorders[_recorder] = _allowed
    log RecorderUpdated(recorder=_recorder, allowed=_allowed)

@external
def record_bid(
    _auction_id: uint256,
    _bidder: address,
    _amount: uint256,
    _guarantee: uint256,
    _refund_epoch: uint256,
    _was_winner: bool
) -> uint256:
    self._only_recorder()
    assert _auction_id > 0, "auction"
    assert _bidder != empty(address), "bidder"
    assert _amount > 0, "amount"
    record_id: uint256 = self.next_record_id
    self.next_record_id = record_id + 1
    self.records[record_id] = BidRecord({
        auction_id: _auction_id,
        bidder: _bidder,
        amount: _amount,
        guarantee: _guarantee,
        timestamp: block.timestamp,
        refund_epoch: _refund_epoch,
        was_winner: _was_winner,
        was_refunded: False
    })
    self.latest_record_for_bidder[_auction_id][_bidder] = record_id
    self.auction_record_count[_auction_id] += 1
    self.auction_total_bid_amount[_auction_id] += _amount
    self.auction_total_guarantees[_auction_id] += _guarantee
    self.bidder_total_bid_amount[_bidder] += _amount
    log BidRecorded(
        record_id=record_id,
        auction_id=_auction_id,
        bidder=_bidder,
        amount=_amount,
        guarantee=_guarantee
    )
    return record_id

@external
def mark_refunded(_record_id: uint256):
    self._only_recorder()
    assert self.records[_record_id].bidder != empty(address), "record"
    assert not self.records[_record_id].was_refunded, "refunded"
    self.records[_record_id].was_refunded = True
    self.auction_total_refunded[self.records[_record_id].auction_id] += self.records[_record_id].guarantee
    self.bidder_total_refunded[self.records[_record_id].bidder] += self.records[_record_id].guarantee
    log BidRefundMarked(
        record_id=_record_id,
        bidder=self.records[_record_id].bidder,
        guarantee=self.records[_record_id].guarantee
    )

@external
def mark_latest_refunded(_auction_id: uint256, _bidder: address):
    self._only_recorder()
    record_id: uint256 = self.latest_record_for_bidder[_auction_id][_bidder]
    assert record_id != 0, "record"
    assert not self.records[record_id].was_refunded, "refunded"
    self.records[record_id].was_refunded = True
    self.auction_total_refunded[_auction_id] += self.records[record_id].guarantee
    self.bidder_total_refunded[_bidder] += self.records[record_id].guarantee
    log BidRefundMarked(record_id=record_id, bidder=_bidder, guarantee=self.records[record_id].guarantee)

@external
@view
def auction_average_bid(_auction_id: uint256) -> uint256:
    count: uint256 = self.auction_record_count[_auction_id]
    if count == 0:
        return 0
    return self.auction_total_bid_amount[_auction_id] // count

@external
@view
def auction_average_guarantee(_auction_id: uint256) -> uint256:
    count: uint256 = self.auction_record_count[_auction_id]
    if count == 0:
        return 0
    return self.auction_total_guarantees[_auction_id] // count

@external
@view
def auction_refund_ratio_bps(_auction_id: uint256) -> uint256:
    total: uint256 = self.auction_total_guarantees[_auction_id]
    if total == 0:
        return 0
    return self.auction_total_refunded[_auction_id] * 10_000 // total

@external
@view
def bidder_refund_ratio_bps(_bidder: address) -> uint256:
    total: uint256 = self.bidder_total_bid_amount[_bidder]
    if total == 0:
        return 0
    return self.bidder_total_refunded[_bidder] * 10_000 // total

@external
@view
def bidder_latest_amount(_auction_id: uint256, _bidder: address) -> uint256:
    record_id: uint256 = self.latest_record_for_bidder[_auction_id][_bidder]
    return self.records[record_id].amount

@external
@view
def bidder_latest_guarantee(_auction_id: uint256, _bidder: address) -> uint256:
    record_id: uint256 = self.latest_record_for_bidder[_auction_id][_bidder]
    return self.records[record_id].guarantee

@external
@view
def bidder_latest_was_refunded(_auction_id: uint256, _bidder: address) -> bool:
    record_id: uint256 = self.latest_record_for_bidder[_auction_id][_bidder]
    return self.records[record_id].was_refunded

