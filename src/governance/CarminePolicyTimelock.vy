# pragma version ^0.4.3

struct Operation:
    target: address
    call_hash: bytes32
    ready_at: uint256
    expires_at: uint256
    predecessor: bytes32
    executed: bool
    cancelled: bool

event GovernorConfigured:
    governor: indexed(address)
    enabled: bool

event GuardianConfigured:
    guardian: indexed(address)
    enabled: bool

event QuorumConfigured:
    quorum: uint256

event OperationScheduled:
    operation_id: indexed(bytes32)
    target: indexed(address)
    call_hash: bytes32
    ready_at: uint256
    expires_at: uint256
    predecessor: bytes32

event OperationApproved:
    operation_id: indexed(bytes32)
    governor: indexed(address)

event OperationCancelled:
    operation_id: indexed(bytes32)
    actor: indexed(address)

event OperationExecuted:
    operation_id: indexed(bytes32)
    executor: indexed(address)
    result_hash: bytes32

MAX_GOVERNORS: constant(uint256) = 16
MAX_RETURN_BYTES: constant(uint256) = 4096

admin: public(address)
domain_separator: public(bytes32)
minimum_delay: public(uint256)
maximum_delay: public(uint256)
grace_period: public(uint256)
approval_quorum: public(uint256)
last_operation_id: public(bytes32)
operation_count: public(uint256)
governor_list: DynArray[address, 16]
is_governor: public(HashMap[address, bool])
known_governor: HashMap[address, bool]
is_guardian: public(HashMap[address, bool])
operations: public(HashMap[bytes32, Operation])
approved: public(HashMap[bytes32, HashMap[address, bool]])
entered: bool


@deploy
def __init__(
    _admin: address,
    _second_governor: address,
    _guardian: address,
    _approval_quorum: uint256,
    _minimum_delay: uint256,
    _maximum_delay: uint256,
    _grace_period: uint256,
    _domain_separator: bytes32,
):
    assert _admin != empty(address), "admin"
    assert _second_governor != empty(address), "governor"
    assert _guardian != empty(address), "guardian"
    assert _second_governor != _admin, "distinct governor"
    assert _approval_quorum > 0 and _approval_quorum <= 2, "quorum"
    assert _minimum_delay > 0, "minimum delay"
    assert _maximum_delay >= _minimum_delay, "maximum delay"
    assert _grace_period > 0, "grace"
    assert _domain_separator != empty(bytes32), "domain"

    self.admin = _admin
    self.domain_separator = _domain_separator
    self.minimum_delay = _minimum_delay
    self.maximum_delay = _maximum_delay
    self.grace_period = _grace_period
    self.approval_quorum = _approval_quorum
    self.governor_list.append(_admin)
    self.governor_list.append(_second_governor)
    self.is_governor[_admin] = True
    self.is_governor[_second_governor] = True
    self.known_governor[_admin] = True
    self.known_governor[_second_governor] = True
    self.is_guardian[_guardian] = True


@internal
def _only_admin():
    assert msg.sender == self.admin, "admin"


@internal
@view
def _active_governor_count() -> uint256:
    count: uint256 = 0
    for governor: address in self.governor_list:
        if self.is_governor[governor]:
            count += 1
    return count


@internal
@view
def _active_approval_count(_operation_id: bytes32) -> uint256:
    count: uint256 = 0
    for governor: address in self.governor_list:
        if self.is_governor[governor] and self.approved[_operation_id][governor]:
            count += 1
    return count


@external
def configure_governor(_governor: address, _enabled: bool):
    self._only_admin()
    assert _governor != empty(address), "governor"
    if _enabled and not self.known_governor[_governor]:
        assert len(self.governor_list) < MAX_GOVERNORS, "governor capacity"
        self.governor_list.append(_governor)
        self.known_governor[_governor] = True
    self.is_governor[_governor] = _enabled
    log GovernorConfigured(governor=_governor, enabled=_enabled)


@external
def configure_guardian(_guardian: address, _enabled: bool):
    self._only_admin()
    assert _guardian != empty(address), "guardian"
    self.is_guardian[_guardian] = _enabled
    log GuardianConfigured(guardian=_guardian, enabled=_enabled)


@external
def configure_quorum(_approval_quorum: uint256):
    self._only_admin()
    assert _approval_quorum > 0, "quorum"
    assert _approval_quorum <= self._active_governor_count(), "quorum capacity"
    self.approval_quorum = _approval_quorum
    log QuorumConfigured(quorum=_approval_quorum)


@external
def transfer_admin(_new_admin: address):
    self._only_admin()
    assert _new_admin != empty(address), "new admin"
    assert self.is_governor[_new_admin], "governor"
    self.admin = _new_admin


@external
def schedule(
    _target: address,
    _call_hash: bytes32,
    _delay: uint256,
    _predecessor: bytes32,
    _salt: bytes32,
) -> bytes32:
    assert self.is_governor[msg.sender], "governor"
    assert _target != empty(address), "target"
    assert _call_hash != empty(bytes32), "call hash"
    assert _delay >= self.minimum_delay, "delay low"
    assert _delay <= self.maximum_delay, "delay high"

    ready_at: uint256 = block.timestamp + _delay
    expires_at: uint256 = ready_at + self.grace_period
    operation_id: bytes32 = keccak256(
        abi_encode(
            self.domain_separator,
            chain.id,
            _target,
            _call_hash,
            ready_at,
            expires_at,
            _predecessor,
            _salt,
        )
    )
    assert self.operations[operation_id].ready_at == 0, "operation exists"
    self.operations[operation_id] = Operation(
        target=_target,
        call_hash=_call_hash,
        ready_at=ready_at,
        expires_at=expires_at,
        predecessor=_predecessor,
        executed=False,
        cancelled=False,
    )
    self.last_operation_id = operation_id
    self.operation_count += 1
    log OperationScheduled(
        operation_id=operation_id,
        target=_target,
        call_hash=_call_hash,
        ready_at=ready_at,
        expires_at=expires_at,
        predecessor=_predecessor,
    )
    return operation_id


@external
def approve(_operation_id: bytes32):
    assert self.is_governor[msg.sender], "governor"
    assert self.operations[_operation_id].ready_at > 0, "operation"
    assert not self.operations[_operation_id].executed, "executed"
    assert not self.operations[_operation_id].cancelled, "cancelled"
    assert not self.approved[_operation_id][msg.sender], "approved"
    self.approved[_operation_id][msg.sender] = True
    log OperationApproved(operation_id=_operation_id, governor=msg.sender)


@external
def cancel(_operation_id: bytes32):
    assert msg.sender == self.admin or self.is_guardian[msg.sender], "canceller"
    assert self.operations[_operation_id].ready_at > 0, "operation"
    assert not self.operations[_operation_id].executed, "executed"
    assert not self.operations[_operation_id].cancelled, "cancelled"
    self.operations[_operation_id].cancelled = True
    log OperationCancelled(operation_id=_operation_id, actor=msg.sender)


@external
def execute(_operation_id: bytes32, _payload: Bytes[4096]) -> bytes32:
    assert not self.entered, "reentrant"
    current: Operation = self.operations[_operation_id]
    assert current.ready_at > 0, "operation"
    assert not current.executed, "executed"
    assert not current.cancelled, "cancelled"
    assert block.timestamp >= current.ready_at, "not ready"
    assert block.timestamp <= current.expires_at, "expired"
    assert keccak256(_payload) == current.call_hash, "payload"
    assert self._active_approval_count(_operation_id) >= self.approval_quorum, "approvals"
    if current.predecessor != empty(bytes32):
        assert self.operations[current.predecessor].executed, "predecessor"

    self.operations[_operation_id].executed = True
    self.entered = True
    result: Bytes[4096] = raw_call(
        current.target,
        _payload,
        max_outsize=MAX_RETURN_BYTES,
        revert_on_failure=True,
    )
    self.entered = False
    result_hash: bytes32 = keccak256(result)
    log OperationExecuted(operation_id=_operation_id, executor=msg.sender, result_hash=result_hash)
    return result_hash


@external
@view
def active_approval_count(_operation_id: bytes32) -> uint256:
    return self._active_approval_count(_operation_id)


@external
@view
def operation_state(_operation_id: bytes32) -> uint256:
    current: Operation = self.operations[_operation_id]
    if current.ready_at == 0:
        return 0
    if current.executed:
        return 4
    if current.cancelled:
        return 5
    if block.timestamp > current.expires_at:
        return 6
    if block.timestamp < current.ready_at:
        return 1
    if self._active_approval_count(_operation_id) < self.approval_quorum:
        return 2
    return 3
