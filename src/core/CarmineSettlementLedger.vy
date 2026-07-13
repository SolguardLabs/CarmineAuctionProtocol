# pragma version ^0.4.3

interface IERC20:
    def transfer(_to: address, _amount: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _amount: uint256) -> bool: nonpayable
    def balanceOf(_owner: address) -> uint256: view

struct Settlement:
    auction: address
    seller: address
    winner: address
    debt_token: address
    collateral_token: address
    debt_paid: uint256
    guarantee_applied: uint256
    collateral_sold: uint256
    partial_units_bps: uint256
    opened_at: uint256
    closed_at: uint256
    status: uint256

event SettlementOpened:
    settlement_id: indexed(uint256)
    auction: indexed(address)
    winner: indexed(address)
    debt_paid: uint256

event SettlementClosed:
    settlement_id: indexed(uint256)
    seller: indexed(address)
    winner: indexed(address)
    debt_paid: uint256

event FeeAccrued:
    token: indexed(address)
    amount: uint256

event FeeWithdrawn:
    token: indexed(address)
    to_account: indexed(address)
    amount: uint256

owner: public(address)
auction_house: public(address)
fee_bps: public(uint256)
next_settlement_id: public(uint256)
settlements: public(HashMap[uint256, Settlement])
fees_accrued: public(HashMap[address, uint256])
seller_revenue: public(HashMap[address, HashMap[address, uint256]])
winner_volume: public(HashMap[address, HashMap[address, uint256]])

STATUS_OPEN: constant(uint256) = 1
STATUS_CLOSED: constant(uint256) = 2
BPS: constant(uint256) = 10_000

@deploy
def __init__(_owner: address, _fee_bps: uint256):
    assert _owner != empty(address), "owner"
    assert _fee_bps <= 1_000, "fee"
    self.owner = _owner
    self.fee_bps = _fee_bps
    self.next_settlement_id = 1

@internal
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
def _only_auction():
    assert msg.sender == self.auction_house, "auction"

@external
def set_auction_house(_auction: address):
    self._only_owner()
    assert _auction != empty(address), "auction"
    self.auction_house = _auction

@external
def set_fee_bps(_fee_bps: uint256):
    self._only_owner()
    assert _fee_bps <= 1_000, "fee"
    self.fee_bps = _fee_bps

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.owner = _new_owner

@external
def open_settlement(
    _seller: address,
    _winner: address,
    _debt_token: address,
    _collateral_token: address,
    _debt_paid: uint256,
    _guarantee_applied: uint256,
    _collateral_sold: uint256,
    _partial_units_bps: uint256
) -> uint256:
    self._only_auction()
    assert _seller != empty(address), "seller"
    assert _winner != empty(address), "winner"
    assert _debt_token != empty(address), "debt"
    assert _collateral_token != empty(address), "collateral"
    settlement_id: uint256 = self.next_settlement_id
    self.next_settlement_id = settlement_id + 1
    self.settlements[settlement_id] = Settlement({
        auction: msg.sender,
        seller: _seller,
        winner: _winner,
        debt_token: _debt_token,
        collateral_token: _collateral_token,
        debt_paid: _debt_paid,
        guarantee_applied: _guarantee_applied,
        collateral_sold: _collateral_sold,
        partial_units_bps: _partial_units_bps,
        opened_at: block.timestamp,
        closed_at: 0,
        status: STATUS_OPEN
    })
    log SettlementOpened(settlement_id=settlement_id, auction=msg.sender, winner=_winner, debt_paid=_debt_paid)
    return settlement_id

@external
def close_settlement(_settlement_id: uint256):
    self._only_auction()
    assert self.settlements[_settlement_id].status == STATUS_OPEN, "open"
    debt: uint256 = self.settlements[_settlement_id].debt_paid
    token: address = self.settlements[_settlement_id].debt_token
    fee: uint256 = debt * self.fee_bps // BPS
    seller_amount: uint256 = debt - fee
    if fee > 0:
        self.fees_accrued[token] += fee
        log FeeAccrued(token=token, amount=fee)
    self.seller_revenue[self.settlements[_settlement_id].seller][token] += seller_amount
    self.winner_volume[self.settlements[_settlement_id].winner][token] += debt
    self.settlements[_settlement_id].status = STATUS_CLOSED
    self.settlements[_settlement_id].closed_at = block.timestamp
    log SettlementClosed(
        settlement_id=_settlement_id,
        seller=self.settlements[_settlement_id].seller,
        winner=self.settlements[_settlement_id].winner,
        debt_paid=debt
    )

@external
def withdraw_fees(_token: address, _to: address, _amount: uint256):
    self._only_owner()
    assert _to != empty(address), "to"
    assert self.fees_accrued[_token] >= _amount, "fees"
    self.fees_accrued[_token] -= _amount
    ok: bool = extcall IERC20(_token).transfer(_to, _amount)
    assert ok, "transfer"
    log FeeWithdrawn(token=_token, to_account=_to, amount=_amount)

@external
@view
def settlement_fee(_debt_paid: uint256) -> uint256:
    return _debt_paid * self.fee_bps // BPS

@external
@view
def seller_amount_after_fee(_debt_paid: uint256) -> uint256:
    return _debt_paid - (_debt_paid * self.fee_bps // BPS)

@external
@view
def is_closed(_settlement_id: uint256) -> bool:
    return self.settlements[_settlement_id].status == STATUS_CLOSED

@external
@view
def settlement_age(_settlement_id: uint256) -> uint256:
    opened: uint256 = self.settlements[_settlement_id].opened_at
    if opened == 0:
        return 0
    if self.settlements[_settlement_id].closed_at > 0:
        return self.settlements[_settlement_id].closed_at - opened
    return block.timestamp - opened
