# pragma version ^0.4.3

event ValueUpdated:
    previous_value: uint256
    new_value: uint256
    revision: uint256

controller: public(address)
value: public(uint256)
revision: public(uint256)
last_payload_hash: public(bytes32)


@deploy
def __init__(_controller: address):
    assert _controller != empty(address), "controller"
    self.controller = _controller


@external
def set_value(_value: uint256) -> bytes32:
    assert msg.sender == self.controller, "controller"
    previous: uint256 = self.value
    self.value = _value
    self.revision += 1
    self.last_payload_hash = keccak256(abi_encode(_value))
    log ValueUpdated(previous_value=previous, new_value=_value, revision=self.revision)
    return self.last_payload_hash


@external
def set_controller(_controller: address):
    assert msg.sender == self.controller, "controller"
    assert _controller != empty(address), "new controller"
    self.controller = _controller
