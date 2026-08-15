from test_carmine_auction_protocol import deploy, must_revert
from web3 import Web3


def stress_arguments():
    markets = sorted(
        [
            (Web3.keccak(text="ETH"), 1_800_000, 1_000_000, 1_200, 9_000, 3_600),
            (Web3.keccak(text="WBTC"), 900_000, 600_000, 1_800, 7_500, 14_400),
            (Web3.keccak(text="RWA"), 700_000, 400_000, 700, 8_500, 86_400),
        ],
        key=lambda market: int.from_bytes(market[0]),
    )
    return (
        [market[0] for market in markets],
        [market[1] for market in markets],
        [market[2] for market in markets],
        [market[3] for market in markets],
        [market[4] for market in markets],
        [market[5] for market in markets],
        2_000,
        500,
        500,
        86_400,
        7_500,
        5_000,
    )


def expected_report(args):
    (
        _,
        collateral_values,
        debt_targets,
        volatility_bps,
        liquidity_bps,
        seconds_to_close,
        shock_bps,
        slippage_bps,
        default_addon_bps,
        horizon_seconds,
        minimum_coverage_bps,
        maximum_hhi_bps,
    ) = args

    obligations = []
    recoveries = []
    for collateral, debt, volatility, liquidity, close in zip(
        collateral_values,
        debt_targets,
        volatility_bps,
        liquidity_bps,
        seconds_to_close,
    ):
        obligation = debt + debt * default_addon_bps // 10_000
        stressed = collateral * (10_000 - shock_bps) // 10_000
        discount = min(volatility + slippage_bps, 9_500)
        recovery = stressed * (10_000 - discount) // 10_000
        recovery = recovery * liquidity // 10_000
        if close > horizon_seconds:
            recovery = recovery * horizon_seconds // close
        obligations.append(obligation)
        recoveries.append(min(recovery, obligation))

    total_obligation = sum(obligations)
    total_recovery = sum(recoveries)
    shares = [obligation * 10_000 // total_obligation for obligation in obligations]
    coverage = total_recovery * 10_000 // total_obligation
    hhi = sum(share * share // 10_000 for share in shares)
    weighted_close = (
        sum(obligation * close for obligation, close in zip(obligations, seconds_to_close))
        // total_obligation
    )
    shortfall = max(total_obligation - total_recovery, 0)
    eligible = coverage >= minimum_coverage_bps and hhi <= maximum_hhi_bps and shortfall == 0
    return {
        "total_obligation": total_obligation,
        "total_recovery": total_recovery,
        "coverage": coverage,
        "weighted_close": weighted_close,
        "hhi": hhi,
        "largest_share": max(shares),
        "shortfall": shortfall,
        "eligible": eligible,
    }


def test_portfolio_stress_reconciles_recovery_concentration_and_maturity(w3):
    engine = deploy(w3, "src/risk/CarminePortfolioStress.vy")
    args = stress_arguments()
    report = engine.functions.evaluate(*args).call()
    expected = expected_report(args)

    assert report[0] == expected["total_obligation"]
    assert report[1] == expected["total_recovery"]
    assert report[3] == expected["shortfall"]
    assert report[4] == expected["coverage"]
    assert report[5] == expected["weighted_close"]
    assert report[6] == expected["hhi"]
    assert report[7] == expected["largest_share"]
    assert report[8] is expected["eligible"]
    assert report[9] != bytes(32)


def test_horizon_discount_reduces_late_market_recovery(w3):
    engine = deploy(w3, "src/risk/CarminePortfolioStress.vy")
    immediate = engine.functions.market_recovery(
        1_000_000,
        1_000,
        500,
        500,
        10_000,
        3_600,
        3_600,
    ).call()
    delayed = engine.functions.market_recovery(
        1_000_000,
        1_000,
        500,
        500,
        10_000,
        14_400,
        3_600,
    ).call()

    assert immediate == 810_000
    assert delayed == 202_500


def test_required_guarantee_combines_volatility_and_concentration(w3):
    engine = deploy(w3, "src/risk/CarminePortfolioStress.vy")
    guarantee = engine.functions.required_bid_guarantee(
        1_000_000,
        1_500,
        2_000,
        4_000,
        3_000,
    ).call()
    capped = engine.functions.required_bid_guarantee(
        1_000_000,
        2_900,
        10_000,
        10_000,
        3_000,
    ).call()

    assert guarantee == 280_000
    assert capped == 300_000


def test_evaluate_requires_canonical_market_order(w3):
    engine = deploy(w3, "src/risk/CarminePortfolioStress.vy")
    args = list(stress_arguments())
    args[0] = [args[0][1], args[0][0], args[0][2]]

    must_revert(w3, engine.functions.evaluate(*args), w3.eth.accounts[0])
