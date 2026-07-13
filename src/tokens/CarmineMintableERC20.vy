# pragma version ^0.4.3

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

event MinterUpdated:
    account: indexed(address)
    allowed: bool

event OwnerTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

name: public(String[64])
symbol: public(String[16])
decimals: public(uint8)
total_supply: public(uint256)
owner: public(address)
minters: public(HashMap[address, bool])
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

UINT256_MAX_VALUE: constant(uint256) = max_value(uint256)

@deploy
def __init__(_name: String[64], _symbol: String[16], _decimals: uint8, _owner: address):
    assert _owner != empty(address), "owner"
    self.name = _name
    self.symbol = _symbol
    self.decimals = _decimals
    self.owner = _owner
    self.minters[_owner] = True
    log MinterUpdated(account=_owner, allowed=True)
    log OwnerTransferred(previous_owner=empty(address), new_owner=_owner)

@internal
def _only_owner():
    assert msg.sender == self.owner, "only owner"

@internal
def _only_minter():
    assert self.minters[msg.sender], "only minter"

@internal
def _transfer(_from: address, _to: address, _amount: uint256):
    assert _to != empty(address), "receiver"
    assert self.balanceOf[_from] >= _amount, "balance"
    self.balanceOf[_from] -= _amount
    self.balanceOf[_to] += _amount
    log Transfer(sender=_from, receiver=_to, value=_amount)

@external
def transfer(_to: address, _amount: uint256) -> bool:
    self._transfer(msg.sender, _to, _amount)
    return True

@external
def transferFrom(_from: address, _to: address, _amount: uint256) -> bool:
    current_allowance: uint256 = self.allowance[_from][msg.sender]
    if current_allowance != UINT256_MAX_VALUE:
        assert current_allowance >= _amount, "allowance"
        self.allowance[_from][msg.sender] = current_allowance - _amount
        log Approval(owner=_from, spender=msg.sender, value=self.allowance[_from][msg.sender])
    self._transfer(_from, _to, _amount)
    return True

@external
def approve(_spender: address, _amount: uint256) -> bool:
    assert _spender != empty(address), "spender"
    self.allowance[msg.sender][_spender] = _amount
    log Approval(owner=msg.sender, spender=_spender, value=_amount)
    return True

@external
def increaseAllowance(_spender: address, _amount: uint256) -> bool:
    assert _spender != empty(address), "spender"
    self.allowance[msg.sender][_spender] += _amount
    log Approval(owner=msg.sender, spender=_spender, value=self.allowance[msg.sender][_spender])
    return True

@external
def decreaseAllowance(_spender: address, _amount: uint256) -> bool:
    assert _spender != empty(address), "spender"
    current_allowance: uint256 = self.allowance[msg.sender][_spender]
    assert current_allowance >= _amount, "allowance"
    self.allowance[msg.sender][_spender] = current_allowance - _amount
    log Approval(owner=msg.sender, spender=_spender, value=self.allowance[msg.sender][_spender])
    return True

@external
def set_minter(_account: address, _allowed: bool):
    self._only_owner()
    assert _account != empty(address), "account"
    self.minters[_account] = _allowed
    log MinterUpdated(account=_account, allowed=_allowed)

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    previous: address = self.owner
    self.owner = _new_owner
    self.minters[_new_owner] = True
    log MinterUpdated(account=_new_owner, allowed=True)
    log OwnerTransferred(previous_owner=previous, new_owner=_new_owner)

@external
def mint(_to: address, _amount: uint256):
    self._only_minter()
    assert _to != empty(address), "receiver"
    self.total_supply += _amount
    self.balanceOf[_to] += _amount
    log Transfer(sender=empty(address), receiver=_to, value=_amount)

@external
def burn(_amount: uint256):
    assert self.balanceOf[msg.sender] >= _amount, "balance"
    self.balanceOf[msg.sender] -= _amount
    self.total_supply -= _amount
    log Transfer(sender=msg.sender, receiver=empty(address), value=_amount)

@external
def burn_from(_from: address, _amount: uint256):
    current_allowance: uint256 = self.allowance[_from][msg.sender]
    if current_allowance != UINT256_MAX_VALUE:
        assert current_allowance >= _amount, "allowance"
        self.allowance[_from][msg.sender] = current_allowance - _amount
        log Approval(owner=_from, spender=msg.sender, value=self.allowance[_from][msg.sender])
    assert self.balanceOf[_from] >= _amount, "balance"
    self.balanceOf[_from] -= _amount
    self.total_supply -= _amount
    log Transfer(sender=_from, receiver=empty(address), value=_amount)

@external
@view
def spendable_balance(_account: address, _spender: address) -> uint256:
    bal: uint256 = self.balanceOf[_account]
    allowed: uint256 = self.allowance[_account][_spender]
    if allowed < bal:
        return allowed
    return bal

@external
@view
def preview_transfer_after_fee(_amount: uint256, _fee_bps: uint256) -> uint256:
    assert _fee_bps <= 10_000, "fee"
    return _amount - (_amount * _fee_bps // 10_000)

@external
@view
def preview_fee(_amount: uint256, _fee_bps: uint256) -> uint256:
    assert _fee_bps <= 10_000, "fee"
    return _amount * _fee_bps // 10_000
