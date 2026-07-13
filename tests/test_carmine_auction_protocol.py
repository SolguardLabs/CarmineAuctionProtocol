from pathlib import Path

import pytest
from eth_tester import PyEVMBackend
from vyper import compile_code
from web3 import EthereumTesterProvider, Web3


ROOT = Path(__file__).resolve().parents[1]
WAD = 10**18
MAX_UINT = 2**256 - 1


def compile_contract(relative_path: str) -> dict:
    path = ROOT / relative_path
    return compile_code(
        path.read_text(encoding="utf-8"),
        output_formats=["abi", "bytecode"],
        contract_path=str(path),
    )


def deploy(w3: Web3, relative_path: str, args=(), sender=None):
    compiled = compile_contract(relative_path)
    acct = sender or w3.eth.accounts[0]
    contract = w3.eth.contract(abi=compiled["abi"], bytecode=compiled["bytecode"])
    tx_hash = contract.constructor(*args).transact({"from": acct, "gas": 12_000_000})
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    assert receipt.status == 1
    return w3.eth.contract(address=receipt.contractAddress, abi=compiled["abi"])


def tx(w3: Web3, fn, sender, gas=8_000_000):
    tx_hash = fn.transact({"from": sender, "gas": gas})
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    assert receipt.status == 1
    return receipt


def must_revert(w3: Web3, fn, sender, gas=8_000_000):
    tx_hash = fn.transact({"from": sender, "gas": gas})
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    assert receipt.status == 0
    return receipt


def time_travel_to(w3: Web3, timestamp: int):
    tester = w3.provider.ethereum_tester
    latest = w3.eth.get_block("latest")["timestamp"]
    if timestamp <= latest:
        timestamp = latest + 1
    tester.time_travel(timestamp)
    tester.mine_blocks(1)


@pytest.fixture()
def w3():
    provider = EthereumTesterProvider(PyEVMBackend())
    web3 = Web3(provider)
    web3.eth.default_account = web3.eth.accounts[0]
    return web3


@pytest.fixture()
def system(w3):
    admin, seller, alice, bob, carol = w3.eth.accounts[:5]
    debt = deploy(w3, "src/tokens/CarmineMintableERC20.vy", ("Carmine USD", "cUSD", 18, admin), admin)
    collateral = deploy(w3, "src/tokens/CarmineMintableERC20.vy", ("Carmine Collateral", "cCOL", 18, admin), admin)
    auction = deploy(w3, "src/core/CarmineAuctionHouse.vy", (admin,), admin)

    for account in [seller, alice, bob, carol]:
        tx(w3, debt.functions.mint(account, 10_000 * WAD), admin)
        tx(w3, debt.functions.approve(auction.address, MAX_UINT), account)
    tx(w3, collateral.functions.mint(seller, 10_000 * WAD), admin)
    tx(w3, collateral.functions.approve(auction.address, MAX_UINT), seller)

    return {
        "admin": admin,
        "seller": seller,
        "alice": alice,
        "bob": bob,
        "carol": carol,
        "debt": debt,
        "collateral": collateral,
        "auction": auction,
    }


def create_default_auction(w3, system, *, duration=3600, partial_claim_bps=3000):
    lot_id = Web3.keccak(text="CARMINE-LOT-1")
    tx(
        w3,
        system["auction"].functions.create_auction(
            system["collateral"].address,
            system["debt"].address,
            lot_id,
            1_000 * WAD,
            900 * WAD,
            duration,
            300,
            900,
            500,
            2000,
            partial_claim_bps,
        ),
        system["seller"],
    )
    return 1


def test_all_vyper_sources_compile():
    for path in sorted((ROOT / "src").rglob("*.vy")):
        compile_code(
            path.read_text(encoding="utf-8"),
            output_formats=["abi", "bytecode"],
            contract_path=str(path),
        )


def test_create_auction_locks_collateral(w3, system):
    auction_id = create_default_auction(w3, system)

    assert system["auction"].functions.min_next_bid(auction_id).call() == 900 * WAD
    assert system["collateral"].functions.balanceOf(system["auction"].address).call() == 1_000 * WAD
    assert system["collateral"].functions.balanceOf(system["seller"]).call() == 9_000 * WAD


def test_bids_and_outbids_refund_previous_guarantee(w3, system):
    auction_id = create_default_auction(w3, system)
    alice = system["alice"]
    bob = system["bob"]
    debt = system["debt"]
    auction = system["auction"]

    alice_start = debt.functions.balanceOf(alice).call()
    bob_start = debt.functions.balanceOf(bob).call()

    tx(w3, auction.functions.bid(auction_id, 900 * WAD), alice)
    assert debt.functions.balanceOf(alice).call() == alice_start - 180 * WAD
    assert auction.functions.guarantee_for_bid(auction_id, 1_000 * WAD).call() == 200 * WAD

    tx(w3, auction.functions.bid(auction_id, 1_000 * WAD), bob)
    assert debt.functions.balanceOf(alice).call() == alice_start
    assert debt.functions.balanceOf(bob).call() == bob_start - 200 * WAD
    assert auction.functions.bidder_refunds(auction_id, alice).call() == 180 * WAD
    assert auction.functions.min_next_bid(auction_id).call() == 1_050 * WAD


def test_near_close_bid_extends_auction(w3, system):
    auction_id = create_default_auction(w3, system)
    auction = system["auction"]
    alice = system["alice"]
    bob = system["bob"]

    tx(w3, auction.functions.bid(auction_id, 900 * WAD), alice)
    original_end = auction.functions.auctions(auction_id).call()[7]
    time_travel_to(w3, original_end - 10)
    tx(w3, auction.functions.bid(auction_id, 1_000 * WAD), bob)
    updated = auction.functions.auctions(auction_id).call()

    assert updated[7] == original_end + 900
    assert updated[18] == 1
    assert auction.functions.is_near_close(auction_id).call() is False


def test_settlement_and_winner_claim_without_partial(w3, system):
    auction_id = create_default_auction(w3, system, duration=600, partial_claim_bps=0)
    auction = system["auction"]
    debt = system["debt"]
    collateral = system["collateral"]
    seller = system["seller"]
    alice = system["alice"]

    seller_debt_start = debt.functions.balanceOf(seller).call()
    tx(w3, auction.functions.bid(auction_id, 900 * WAD), alice)
    end_time = auction.functions.auctions(auction_id).call()[7]
    time_travel_to(w3, end_time + 1)
    tx(w3, auction.functions.settle(auction_id), alice)
    tx(w3, auction.functions.claim_winner_collateral(auction_id), alice)

    assert debt.functions.balanceOf(seller).call() == seller_debt_start + 900 * WAD
    assert collateral.functions.balanceOf(alice).call() == 1_000 * WAD
    assert auction.functions.preview_winner_collateral(auction_id).call() == 1_000 * WAD


def test_cancel_auction_returns_collateral(w3, system):
    auction_id = create_default_auction(w3, system)
    collateral = system["collateral"]
    seller = system["seller"]
    before = collateral.functions.balanceOf(seller).call()

    tx(w3, system["auction"].functions.cancel_auction(auction_id), seller)

    assert collateral.functions.balanceOf(seller).call() == before + 1_000 * WAD
    assert collateral.functions.balanceOf(system["auction"].address).call() == 0
    must_revert(w3, system["auction"].functions.bid(auction_id, 900 * WAD), system["alice"])


def test_cancel_reverts_after_bid(w3, system):
    auction_id = create_default_auction(w3, system)
    tx(w3, system["auction"].functions.bid(auction_id, 900 * WAD), system["alice"])
    must_revert(w3, system["auction"].functions.cancel_auction(auction_id), system["seller"])


def test_refund_callback_partial_claim_accounting(w3, system):
    admin = system["admin"]
    bob = system["bob"]
    seller = system["seller"]
    debt = system["debt"]
    collateral = system["collateral"]
    auction = system["auction"]
    auction_id = create_default_auction(w3, system, duration=900, partial_claim_bps=3000)

    callback_bidder = deploy(
        w3,
        "src/mocks/CarmineRefundBidder.vy",
        (auction.address, debt.address, collateral.address, admin),
        admin,
    )
    tx(w3, debt.functions.mint(callback_bidder.address, 2_000 * WAD), admin)
    tx(w3, callback_bidder.functions.approve_auction(MAX_UINT), admin)

    seller_debt_start = debt.functions.balanceOf(seller).call()
    tx(w3, callback_bidder.functions.place_bid(auction_id, 900 * WAD, 3000), admin)
    original_end = auction.functions.auctions(auction_id).call()[7]
    time_travel_to(w3, original_end - 5)

    tx(w3, auction.functions.bid(auction_id, 1_000 * WAD), bob)

    assert callback_bidder.functions.callbacks().call() == 1
    assert callback_bidder.functions.last_refund().call() == 180 * WAD
    assert auction.functions.partial_claim_units(auction_id, callback_bidder.address).call() == 3000
    assert auction.functions.preview_partial_collateral(auction_id, callback_bidder.address).call() == 300 * WAD
    assert debt.functions.balanceOf(callback_bidder.address).call() == 2_000 * WAD

    new_end = auction.functions.auctions(auction_id).call()[7]
    time_travel_to(w3, new_end + 1)
    tx(w3, auction.functions.settle(auction_id), bob)
    tx(w3, callback_bidder.functions.claim_partial(auction_id), admin)
    tx(w3, auction.functions.claim_winner_collateral(auction_id), bob)

    assert debt.functions.balanceOf(seller).call() == seller_debt_start + 1_000 * WAD
    assert collateral.functions.balanceOf(callback_bidder.address).call() == 300 * WAD
    assert collateral.functions.balanceOf(bob).call() == 700 * WAD
    assert auction.functions.preview_winner_collateral(auction_id).call() == 700 * WAD
