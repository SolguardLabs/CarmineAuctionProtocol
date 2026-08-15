from test_carmine_auction_protocol import deploy, must_revert, time_travel_to, tx
from web3 import Web3

MINIMUM_DELAY = 3_600
MAXIMUM_DELAY = 7 * 24 * 3_600
GRACE_PERIOD = 2 * 24 * 3_600


def deploy_governance(w3):
    admin, governor, guardian = w3.eth.accounts[:3]
    timelock = deploy(
        w3,
        "src/governance/CarminePolicyTimelock.vy",
        (
            admin,
            governor,
            guardian,
            2,
            MINIMUM_DELAY,
            MAXIMUM_DELAY,
            GRACE_PERIOD,
            Web3.keccak(text="CARMINE_POLICY_V1"),
        ),
        admin,
    )
    target = deploy(w3, "src/mocks/CarmineGovernedTarget.vy", (timelock.address,), admin)
    return admin, governor, guardian, timelock, target


def encoded_set_value(target, value):
    encoded = target.functions.set_value(value)._encode_transaction_data()
    return bytes.fromhex(encoded[2:])


def schedule(w3, timelock, target, payload, sender, *, salt, predecessor=bytes(32)):
    tx(
        w3,
        timelock.functions.schedule(
            target.address,
            Web3.keccak(payload),
            MINIMUM_DELAY,
            predecessor,
            salt,
        ),
        sender,
    )
    return timelock.functions.last_operation_id().call()


def approve_two(w3, timelock, operation_id, admin, governor):
    tx(w3, timelock.functions.approve(operation_id), admin)
    tx(w3, timelock.functions.approve(operation_id), governor)


def ready_at(timelock, operation_id):
    return timelock.functions.operations(operation_id).call()[2]


def test_executes_only_after_current_quorum_and_delay(w3):
    admin, governor, _, timelock, target = deploy_governance(w3)
    payload = encoded_set_value(target, 42)
    operation_id = schedule(
        w3,
        timelock,
        target,
        payload,
        admin,
        salt=Web3.keccak(text="set-42"),
    )
    approve_two(w3, timelock, operation_id, admin, governor)

    must_revert(w3, timelock.functions.execute(operation_id, payload), w3.eth.accounts[7])
    time_travel_to(w3, ready_at(timelock, operation_id))
    tx(w3, timelock.functions.execute(operation_id, payload), w3.eth.accounts[7])

    assert target.functions.value().call() == 42
    assert target.functions.revision().call() == 1
    assert timelock.functions.operation_state(operation_id).call() == 4


def test_revoked_governor_stops_counting_toward_quorum(w3):
    admin, governor, _, timelock, target = deploy_governance(w3)
    payload = encoded_set_value(target, 77)
    operation_id = schedule(
        w3,
        timelock,
        target,
        payload,
        admin,
        salt=Web3.keccak(text="set-77"),
    )
    approve_two(w3, timelock, operation_id, admin, governor)
    tx(w3, timelock.functions.configure_governor(governor, False), admin)
    time_travel_to(w3, ready_at(timelock, operation_id))

    assert timelock.functions.active_approval_count(operation_id).call() == 1
    must_revert(w3, timelock.functions.execute(operation_id, payload), w3.eth.accounts[8])


def test_guardian_cancellation_is_final(w3):
    admin, governor, guardian, timelock, target = deploy_governance(w3)
    payload = encoded_set_value(target, 99)
    operation_id = schedule(
        w3,
        timelock,
        target,
        payload,
        admin,
        salt=Web3.keccak(text="cancel-99"),
    )
    approve_two(w3, timelock, operation_id, admin, governor)
    tx(w3, timelock.functions.cancel(operation_id), guardian)
    time_travel_to(w3, ready_at(timelock, operation_id))

    must_revert(w3, timelock.functions.execute(operation_id, payload), w3.eth.accounts[9])
    assert target.functions.value().call() == 0
    assert timelock.functions.operation_state(operation_id).call() == 5


def test_predecessor_must_execute_before_dependent_operation(w3):
    admin, governor, _, timelock, target = deploy_governance(w3)
    first_payload = encoded_set_value(target, 11)
    first_id = schedule(
        w3,
        timelock,
        target,
        first_payload,
        admin,
        salt=Web3.keccak(text="first"),
    )
    second_payload = encoded_set_value(target, 22)
    second_id = schedule(
        w3,
        timelock,
        target,
        second_payload,
        governor,
        salt=Web3.keccak(text="second"),
        predecessor=first_id,
    )
    approve_two(w3, timelock, first_id, admin, governor)
    approve_two(w3, timelock, second_id, admin, governor)
    time_travel_to(w3, max(ready_at(timelock, first_id), ready_at(timelock, second_id)))

    must_revert(w3, timelock.functions.execute(second_id, second_payload), w3.eth.accounts[6])
    tx(w3, timelock.functions.execute(first_id, first_payload), w3.eth.accounts[6])
    tx(w3, timelock.functions.execute(second_id, second_payload), w3.eth.accounts[6])

    assert target.functions.value().call() == 22
    assert target.functions.revision().call() == 2
