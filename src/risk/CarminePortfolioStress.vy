# pragma version ^0.4.3

struct StressReport:
    total_obligation: uint256
    total_recovery: uint256
    surplus: uint256
    shortfall: uint256
    coverage_bps: uint256
    weighted_close_seconds: uint256
    concentration_hhi_bps: uint256
    largest_market_share_bps: uint256
    policy_eligible: bool
    report_digest: bytes32

BPS: constant(uint256) = 10_000
MAX_MARKETS: constant(uint256) = 16
MAX_EXECUTION_DISCOUNT_BPS: constant(uint256) = 9_500
MAX_COVERAGE_BPS: constant(uint256) = 1_000_000


@internal
@pure
def _bounded_add(_a: uint256, _b: uint256, _limit: uint256) -> uint256:
    total: uint256 = _a + _b
    if total > _limit:
        return _limit
    return total


@internal
@pure
def _obligation(_debt_target: uint256, _default_addon_bps: uint256) -> uint256:
    assert _default_addon_bps <= BPS, "default addon"
    return _debt_target + _debt_target * _default_addon_bps // BPS


@internal
@pure
def _market_recovery(
    _collateral_value: uint256,
    _shock_bps: uint256,
    _volatility_bps: uint256,
    _slippage_bps: uint256,
    _liquidity_bps: uint256,
    _seconds_to_close: uint256,
    _horizon_seconds: uint256,
) -> uint256:
    assert _shock_bps <= BPS, "shock"
    assert _volatility_bps <= BPS, "volatility"
    assert _slippage_bps <= BPS, "slippage"
    assert _liquidity_bps <= BPS, "liquidity"

    stressed_value: uint256 = _collateral_value * (BPS - _shock_bps) // BPS
    execution_discount: uint256 = self._bounded_add(
        _volatility_bps,
        _slippage_bps,
        MAX_EXECUTION_DISCOUNT_BPS,
    )
    executable_value: uint256 = stressed_value * (BPS - execution_discount) // BPS
    recovered_value: uint256 = executable_value * _liquidity_bps // BPS

    if _seconds_to_close > _horizon_seconds:
        if _horizon_seconds == 0:
            return 0
        recovered_value = recovered_value * _horizon_seconds // _seconds_to_close

    return recovered_value


@external
@pure
def market_recovery(
    _collateral_value: uint256,
    _shock_bps: uint256,
    _volatility_bps: uint256,
    _slippage_bps: uint256,
    _liquidity_bps: uint256,
    _seconds_to_close: uint256,
    _horizon_seconds: uint256,
) -> uint256:
    return self._market_recovery(
        _collateral_value,
        _shock_bps,
        _volatility_bps,
        _slippage_bps,
        _liquidity_bps,
        _seconds_to_close,
        _horizon_seconds,
    )


@external
@pure
def required_bid_guarantee(
    _debt_target: uint256,
    _base_guarantee_bps: uint256,
    _volatility_bps: uint256,
    _concentration_bps: uint256,
    _maximum_guarantee_bps: uint256,
) -> uint256:
    assert _base_guarantee_bps <= BPS, "base"
    assert _volatility_bps <= BPS, "volatility"
    assert _concentration_bps <= BPS, "concentration"
    assert _maximum_guarantee_bps <= BPS, "maximum"

    volatility_addon: uint256 = _volatility_bps // 4
    concentration_addon: uint256 = _concentration_bps // 5
    guarantee_bps: uint256 = self._bounded_add(
        _base_guarantee_bps,
        volatility_addon,
        _maximum_guarantee_bps,
    )
    guarantee_bps = self._bounded_add(
        guarantee_bps,
        concentration_addon,
        _maximum_guarantee_bps,
    )
    return _debt_target * guarantee_bps // BPS


@external
@pure
def evaluate(
    _market_ids: DynArray[bytes32, 16],
    _collateral_values: DynArray[uint256, 16],
    _debt_targets: DynArray[uint256, 16],
    _volatility_bps: DynArray[uint256, 16],
    _liquidity_bps: DynArray[uint256, 16],
    _seconds_to_close: DynArray[uint256, 16],
    _shock_bps: uint256,
    _slippage_bps: uint256,
    _default_addon_bps: uint256,
    _horizon_seconds: uint256,
    _minimum_coverage_bps: uint256,
    _maximum_hhi_bps: uint256,
) -> StressReport:
    market_count: uint256 = len(_market_ids)
    assert market_count > 0, "markets"
    assert market_count == len(_collateral_values), "collateral length"
    assert market_count == len(_debt_targets), "debt length"
    assert market_count == len(_volatility_bps), "volatility length"
    assert market_count == len(_liquidity_bps), "liquidity length"
    assert market_count == len(_seconds_to_close), "close length"
    assert _shock_bps <= BPS, "shock"
    assert _slippage_bps <= BPS, "slippage"
    assert _default_addon_bps <= BPS, "default addon"
    assert _minimum_coverage_bps <= MAX_COVERAGE_BPS, "coverage policy"
    assert _maximum_hhi_bps <= BPS, "hhi policy"

    total_obligation: uint256 = 0
    total_recovery: uint256 = 0
    weighted_close_numerator: uint256 = 0

    for i: uint256 in range(MAX_MARKETS):
        if i >= market_count:
            break
        if i > 0:
            assert convert(_market_ids[i], uint256) > convert(_market_ids[i - 1], uint256), "market order"
        assert _debt_targets[i] > 0, "debt"
        obligation: uint256 = self._obligation(_debt_targets[i], _default_addon_bps)
        recovery: uint256 = self._market_recovery(
            _collateral_values[i],
            _shock_bps,
            _volatility_bps[i],
            _slippage_bps,
            _liquidity_bps[i],
            _seconds_to_close[i],
            _horizon_seconds,
        )
        if recovery > obligation:
            recovery = obligation
        total_obligation += obligation
        total_recovery += recovery
        weighted_close_numerator += obligation * _seconds_to_close[i]

    coverage_bps: uint256 = 0
    weighted_close_seconds: uint256 = 0
    if total_obligation > 0:
        coverage_bps = total_recovery * BPS // total_obligation
        if coverage_bps > MAX_COVERAGE_BPS:
            coverage_bps = MAX_COVERAGE_BPS
        weighted_close_seconds = weighted_close_numerator // total_obligation

    concentration_hhi_bps: uint256 = 0
    largest_market_share_bps: uint256 = 0
    for i: uint256 in range(MAX_MARKETS):
        if i >= market_count:
            break
        obligation: uint256 = self._obligation(_debt_targets[i], _default_addon_bps)
        share_bps: uint256 = obligation * BPS // total_obligation
        concentration_hhi_bps += share_bps * share_bps // BPS
        if share_bps > largest_market_share_bps:
            largest_market_share_bps = share_bps

    surplus: uint256 = 0
    shortfall: uint256 = 0
    if total_recovery >= total_obligation:
        surplus = total_recovery - total_obligation
    else:
        shortfall = total_obligation - total_recovery

    policy_eligible: bool = (
        coverage_bps >= _minimum_coverage_bps
        and concentration_hhi_bps <= _maximum_hhi_bps
        and shortfall == 0
    )
    report_digest: bytes32 = keccak256(
        abi_encode(
            _market_ids,
            _collateral_values,
            _debt_targets,
            _volatility_bps,
            _liquidity_bps,
            _seconds_to_close,
            _shock_bps,
            _slippage_bps,
            _default_addon_bps,
            _horizon_seconds,
            total_obligation,
            total_recovery,
            coverage_bps,
            concentration_hhi_bps,
        )
    )

    return StressReport(
        total_obligation=total_obligation,
        total_recovery=total_recovery,
        surplus=surplus,
        shortfall=shortfall,
        coverage_bps=coverage_bps,
        weighted_close_seconds=weighted_close_seconds,
        concentration_hhi_bps=concentration_hhi_bps,
        largest_market_share_bps=largest_market_share_bps,
        policy_eligible=policy_eligible,
        report_digest=report_digest,
    )
