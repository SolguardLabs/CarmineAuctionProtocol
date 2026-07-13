# pragma version ^0.4.3

interface IERC20:
    def transferFrom(_from: address, _to: address, _amount: uint256) -> bool: nonpayable
    def approve(_spender: address, _amount: uint256) -> bool: nonpayable

interface IAuctionHouse:
    def create_auction(
        _collateral_token: address,
        _debt_token: address,
        _lot_id: bytes32,
        _collateral_amount: uint256,
        _debt_target: uint256,
        _duration: uint256,
        _extension_window: uint256,
        _extension_duration: uint256,
        _min_increment_bps: uint256,
        _guarantee_bps: uint256,
        _partial_claim_bps: uint256
    ) -> uint256: nonpayable
    def bid(_auction_id: uint256, _amount: uint256): nonpayable
    def settle(_auction_id: uint256): nonpayable
    def claim_winner_collateral(_auction_id: uint256): nonpayable

struct RouteTerms:
    auction_house: address
    collateral_token: address
    debt_token: address
    duration: uint256
    extension_window: uint256
    extension_duration: uint256
    min_increment_bps: uint256
    guarantee_bps: uint256
    partial_claim_bps: uint256
    enabled: bool

event RouteConfigured:
    route_id: indexed(uint256)
    auction_house: indexed(address)
    collateral_token: indexed(address)
    debt_token: address

event RoutedAuctionStarted:
    route_id: indexed(uint256)
    auction_id: indexed(uint256)
    seller: indexed(address)
    collateral_amount: uint256
    debt_target: uint256

event RoutedBid:
    route_id: indexed(uint256)
    auction_id: indexed(uint256)
    bidder: indexed(address)
    amount: uint256

owner: public(address)
next_route_id: public(uint256)
routes: public(HashMap[uint256, RouteTerms])
route_by_pair: public(HashMap[address, HashMap[address, uint256]])
auction_route: public(HashMap[uint256, uint256])
auction_starter: public(HashMap[uint256, address])

@deploy
def __init__(_owner: address):
    assert _owner != empty(address), "owner"
    self.owner = _owner
    self.next_route_id = 1

@internal
def _only_owner():
    assert msg.sender == self.owner, "owner"

@external
def transfer_ownership(_new_owner: address):
    self._only_owner()
    assert _new_owner != empty(address), "new owner"
    self.owner = _new_owner

@external
def configure_route(
    _auction_house: address,
    _collateral_token: address,
    _debt_token: address,
    _duration: uint256,
    _extension_window: uint256,
    _extension_duration: uint256,
    _min_increment_bps: uint256,
    _guarantee_bps: uint256,
    _partial_claim_bps: uint256,
    _enabled: bool
) -> uint256:
    self._only_owner()
    assert _auction_house != empty(address), "auction"
    assert _collateral_token != empty(address), "collateral"
    assert _debt_token != empty(address), "debt"
    assert _duration > 0, "duration"
    assert _extension_window <= _duration, "window"
    route_id: uint256 = self.route_by_pair[_collateral_token][_debt_token]
    if route_id == 0:
        route_id = self.next_route_id
        self.next_route_id = route_id + 1
        self.route_by_pair[_collateral_token][_debt_token] = route_id
    self.routes[route_id] = RouteTerms({
        auction_house: _auction_house,
        collateral_token: _collateral_token,
        debt_token: _debt_token,
        duration: _duration,
        extension_window: _extension_window,
        extension_duration: _extension_duration,
        min_increment_bps: _min_increment_bps,
        guarantee_bps: _guarantee_bps,
        partial_claim_bps: _partial_claim_bps,
        enabled: _enabled
    })
    log RouteConfigured(
        route_id=route_id,
        auction_house=_auction_house,
        collateral_token=_collateral_token,
        debt_token=_debt_token
    )
    return route_id

@external
def set_route_enabled(_route_id: uint256, _enabled: bool):
    self._only_owner()
    assert self.routes[_route_id].auction_house != empty(address), "route"
    self.routes[_route_id].enabled = _enabled

@external
def start_routed_auction(
    _route_id: uint256,
    _lot_id: bytes32,
    _collateral_amount: uint256,
    _debt_target: uint256
) -> uint256:
    terms: RouteTerms = self.routes[_route_id]
    assert terms.enabled, "route"
    assert _collateral_amount > 0, "collateral"
    assert _debt_target > 0, "target"
    pull_ok: bool = extcall IERC20(terms.collateral_token).transferFrom(msg.sender, self, _collateral_amount)
    assert pull_ok, "pull"
    approve_ok: bool = extcall IERC20(terms.collateral_token).approve(terms.auction_house, _collateral_amount)
    assert approve_ok, "approve"
    auction_id: uint256 = extcall IAuctionHouse(terms.auction_house).create_auction(
        terms.collateral_token,
        terms.debt_token,
        _lot_id,
        _collateral_amount,
        _debt_target,
        terms.duration,
        terms.extension_window,
        terms.extension_duration,
        terms.min_increment_bps,
        terms.guarantee_bps,
        terms.partial_claim_bps
    )
    self.auction_route[auction_id] = _route_id
    self.auction_starter[auction_id] = msg.sender
    log RoutedAuctionStarted(
        route_id=_route_id,
        auction_id=auction_id,
        seller=msg.sender,
        collateral_amount=_collateral_amount,
        debt_target=_debt_target
    )
    return auction_id

@external
def bid_through_route(_auction_id: uint256, _amount: uint256):
    route_id: uint256 = self.auction_route[_auction_id]
    terms: RouteTerms = self.routes[route_id]
    assert terms.enabled, "route"
    guarantee: uint256 = _amount * terms.guarantee_bps // 10_000
    if guarantee == 0:
        guarantee = 1
    pull_ok: bool = extcall IERC20(terms.debt_token).transferFrom(msg.sender, self, guarantee)
    assert pull_ok, "pull"
    approve_ok: bool = extcall IERC20(terms.debt_token).approve(terms.auction_house, guarantee)
    assert approve_ok, "approve"
    extcall IAuctionHouse(terms.auction_house).bid(_auction_id, _amount)
    log RoutedBid(route_id=route_id, auction_id=_auction_id, bidder=msg.sender, amount=_amount)

@external
def settle_and_claim(_auction_id: uint256):
    route_id: uint256 = self.auction_route[_auction_id]
    terms: RouteTerms = self.routes[route_id]
    assert terms.auction_house != empty(address), "route"
    extcall IAuctionHouse(terms.auction_house).settle(_auction_id)
    extcall IAuctionHouse(terms.auction_house).claim_winner_collateral(_auction_id)

@external
@view
def route_for_pair(_collateral_token: address, _debt_token: address) -> uint256:
    return self.route_by_pair[_collateral_token][_debt_token]

@external
@view
def preview_route_guarantee(_route_id: uint256, _amount: uint256) -> uint256:
    guarantee: uint256 = _amount * self.routes[_route_id].guarantee_bps // 10_000
    if guarantee == 0 and _amount > 0:
        return 1
    return guarantee

@external
@view
def preview_route_end(_route_id: uint256, _start: uint256) -> uint256:
    return _start + self.routes[_route_id].duration

