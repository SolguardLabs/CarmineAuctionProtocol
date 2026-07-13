# pragma version ^0.4.3

interface IERC20:
    def transfer(_to: address, _amount: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _amount: uint256) -> bool: nonpayable
    def balanceOf(_owner: address) -> uint256: view

struct Reserve:
    token: address
    total_deposited: uint256
    total_released: uint256
    locked_for_auctions: uint256
    liquidation_buffer: uint256
    enabled: bool

event ReserveRegistered:
    reserve_id: indexed(uint256)
    token: indexed(address)

event CollateralDeposited:
    reserve_id: indexed(uint256)
    from_account: indexed(address)
    amount: uint256

event CollateralLocked:
    reserve_id: indexed(uint256)
    auction: indexed(address)
    amount: uint256

event CollateralReleased:
    reserve_id: indexed(uint256)
    to_account: indexed(address)
    amount: uint256

event BufferAdjusted:
    reserve_id: indexed(uint256)
    amount: uint256

owner: public(address)
auction_house: public(address)
next_reserve_id: public(uint256)
reserves: public(HashMap[uint256, Reserve])
reserve_by_token: public(HashMap[address, uint256])
account_deposits: public(HashMap[uint256, HashMap[address, uint256]])
account_releases: public(HashMap[uint256, HashMap[address, uint256]])

@deploy
def __init__(_owner: address):
    assert _owner != empty(address), "owner"
    self.owner = _owner
    self.next_reserve_id = 1

@internal
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
def _only_auction():
    assert msg.sender == self.auction_house, "auction"

@internal
@view
def _available_liquidity(_reserve_id: uint256) -> uint256:
    token: address = self.reserves[_reserve_id].token
    if token == empty(address):
        return 0
    bal: uint256 = staticcall IERC20(token).balanceOf(self)
    locked: uint256 = self.reserves[_reserve_id].locked_for_auctions
    if bal <= locked:
        return 0
    return bal - locked

@external
def set_auction_house(_auction: address):
    self._only_owner()
    assert _auction != empty(address), "auction"
    self.auction_house = _auction

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.owner = _new_owner

@external
def register_reserve(_token: address) -> uint256:
    self._only_owner()
    assert _token != empty(address), "token"
    assert self.reserve_by_token[_token] == 0, "exists"
    reserve_id: uint256 = self.next_reserve_id
    self.next_reserve_id = reserve_id + 1
    self.reserves[reserve_id] = Reserve({
        token: _token,
        total_deposited: 0,
        total_released: 0,
        locked_for_auctions: 0,
        liquidation_buffer: 0,
        enabled: True
    })
    self.reserve_by_token[_token] = reserve_id
    log ReserveRegistered(reserve_id=reserve_id, token=_token)
    return reserve_id

@external
def set_enabled(_reserve_id: uint256, _enabled: bool):
    self._only_owner()
    assert self.reserves[_reserve_id].token != empty(address), "reserve"
    self.reserves[_reserve_id].enabled = _enabled

@external
def deposit(_reserve_id: uint256, _amount: uint256):
    assert self.reserves[_reserve_id].enabled, "disabled"
    assert _amount > 0, "amount"
    token: address = self.reserves[_reserve_id].token
    ok: bool = extcall IERC20(token).transferFrom(msg.sender, self, _amount)
    assert ok, "transfer"
    self.reserves[_reserve_id].total_deposited += _amount
    self.account_deposits[_reserve_id][msg.sender] += _amount
    log CollateralDeposited(reserve_id=_reserve_id, from_account=msg.sender, amount=_amount)

@external
def lock_for_auction(_reserve_id: uint256, _amount: uint256):
    self._only_auction()
    assert self.reserves[_reserve_id].enabled, "disabled"
    assert _amount > 0, "amount"
    assert self._available_liquidity(_reserve_id) >= _amount, "available"
    self.reserves[_reserve_id].locked_for_auctions += _amount
    log CollateralLocked(reserve_id=_reserve_id, auction=msg.sender, amount=_amount)

@external
def release_to(_reserve_id: uint256, _to: address, _amount: uint256):
    self._only_auction()
    assert _to != empty(address), "to"
    assert self.reserves[_reserve_id].locked_for_auctions >= _amount, "locked"
    self.reserves[_reserve_id].locked_for_auctions -= _amount
    self.reserves[_reserve_id].total_released += _amount
    self.account_releases[_reserve_id][_to] += _amount
    ok: bool = extcall IERC20(self.reserves[_reserve_id].token).transfer(_to, _amount)
    assert ok, "release"
    log CollateralReleased(reserve_id=_reserve_id, to_account=_to, amount=_amount)

@external
def add_buffer(_reserve_id: uint256, _amount: uint256):
    self._only_owner()
    assert self.reserves[_reserve_id].token != empty(address), "reserve"
    ok: bool = extcall IERC20(self.reserves[_reserve_id].token).transferFrom(msg.sender, self, _amount)
    assert ok, "buffer"
    self.reserves[_reserve_id].liquidation_buffer += _amount
    self.reserves[_reserve_id].total_deposited += _amount
    log BufferAdjusted(reserve_id=_reserve_id, amount=self.reserves[_reserve_id].liquidation_buffer)

@external
def remove_buffer(_reserve_id: uint256, _amount: uint256, _to: address):
    self._only_owner()
    assert _to != empty(address), "to"
    assert self.reserves[_reserve_id].liquidation_buffer >= _amount, "buffer"
    assert self._available_liquidity(_reserve_id) >= _amount, "available"
    self.reserves[_reserve_id].liquidation_buffer -= _amount
    self.reserves[_reserve_id].total_released += _amount
    ok: bool = extcall IERC20(self.reserves[_reserve_id].token).transfer(_to, _amount)
    assert ok, "remove"
    log BufferAdjusted(reserve_id=_reserve_id, amount=self.reserves[_reserve_id].liquidation_buffer)

@external
@view
def available_liquidity(_reserve_id: uint256) -> uint256:
    return self._available_liquidity(_reserve_id)

@external
@view
def solvency_ratio_bps(_reserve_id: uint256) -> uint256:
    locked: uint256 = self.reserves[_reserve_id].locked_for_auctions
    if locked == 0:
        return 10_000
    token: address = self.reserves[_reserve_id].token
    bal: uint256 = staticcall IERC20(token).balanceOf(self)
    return bal * 10_000 // locked

@external
@view
def net_account_flow(_reserve_id: uint256, _account: address) -> int256:
    deposited: uint256 = self.account_deposits[_reserve_id][_account]
    released: uint256 = self.account_releases[_reserve_id][_account]
    if deposited >= released:
        return convert(deposited - released, int256)
    return -convert(released - deposited, int256)
