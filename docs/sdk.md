# SDK Python

## Objetivo

El SDK ofrece una capa tipada para consultar auctions, solicitar quotes y
transmitir create, bid, settlement y claim. La aritmetica offline replica las
reglas enteras del contrato.

## Requisitos

- Python 3.12 o superior.
- URL HTTP o HTTPS absoluta.
- timeout entre 0 y 120 segundos.
- API key solo en memoria o secret manager.
- cantidades expresadas como `int` o decimal `str`.

## Cliente

```python
from sdk import CarmineClient

client = CarmineClient(
    "https://api.carmine.example",
    api_key="runtime-secret",
    timeout_seconds=8,
)
```

El transporte por defecto usa `urllib`, no ejecuta shell y solo acepta objetos
JSON como respuesta.

## Health

```python
health = client.health()
assert health.synchronized
print(health.chain_id, health.block_number)
```

Campos obligatorios:

- `version`: string no vacio;
- `chainId`: entero positivo;
- `synchronized`: boolean real;
- `blockNumber`: entero no negativo.

## Lectura De Auction

```python
auction = client.auction(42)
print(auction.minimum_next_bid)
print(auction.winning_guarantee)
```

El SDK exige que el `auctionId` devuelto coincida con la ruta solicitada y
valida direcciones, cantidades, timestamps y estado.

## Quote

```python
quote = client.quote_bid(
    42,
    "0x" + "12" * 20,
    1_250 * 10**18,
)
```

La query se codifica mediante `urlencode`. `quoteDigest` debe ser un digest hex
de 32 bytes y `validUntil` un timestamp positivo.

## Escrituras

```python
receipt = client.bid(
    42,
    amount=quote.amount,
    quote_digest=quote.quote_digest,
    idempotency_key="auction-42-bid-0001",
)
```

Cada escritura lleva `Idempotency-Key`. Si no se proporciona, el cliente crea
un UUID. En jobs reintentables se recomienda proporcionar una clave estable.

Metodos:

| Metodo | Ruta | Cuerpo |
| --- | --- | --- |
| `create_auction` | `POST /v1/auctions` | mercado, lote, collateral y target |
| `bid` | `POST /v1/auctions/{id}/bids` | amount y quote digest |
| `settle` | `POST /v1/auctions/{id}/settlement` | vacio |
| `claim` | `POST /v1/auctions/{id}/claims` | winner o partial |

## Unidades Atomicas

```python
from sdk import atomic

amount = atomic("123.456", 6)
assert amount == 123_456_000
```

No se admiten floats. Una precision superior a los decimales del token produce
`ValidationError`.

## Calculos Offline

```python
from sdk import bid_guarantee, claim_allocation, minimum_next_bid

assert minimum_next_bid(1_000, 900, 500) == 1_050
assert bid_guarantee(1_000, 2_000) == 200
assert claim_allocation(1_000, 3_000) == (700, 300)
```

Estos calculos sirven para preflight; el estado on-chain continua siendo la
fuente de autorizacion.

## Stress Offline

```python
from sdk import MarketStressInput, portfolio_stress

markets = [
    MarketStressInput("ETH", 1_800_000, 1_000_000, 1_200, 9_000, 3_600),
    MarketStressInput("WBTC", 900_000, 600_000, 1_800, 7_500, 14_400),
]

report = portfolio_stress(
    markets,
    shock_bps=2_000,
    slippage_bps=500,
    default_addon_bps=500,
    horizon_seconds=86_400,
    minimum_coverage_bps=7_500,
    maximum_hhi_bps=6_000,
)
```

Los identificadores deben ser unicos y estar ordenados. El resultado contiene
obligacion, recuperacion, surplus, shortfall, coverage, cierre ponderado, HHI,
mayor share y veredicto de politica.

## Errores

- `ValidationError`: input o respuesta fuera del contrato.
- `TransportError`: HTTP, timeout, red o JSON no valido.
- `CarmineClientError`: base comun para captura controlada.

No conviertas estos errores en valores por defecto. Una respuesta parcial debe
detener la operacion.

## Transporte Inyectable

El constructor acepta un objeto con metodo `request`. Esto permite pruebas sin
red, observabilidad corporativa y politicas especificas de retry.

```python
class Transport:
    def request(self, method, path, *, headers, body, timeout_seconds):
        ...
```

Un retry de escritura debe conservar la misma clave de idempotencia.

## Seguridad De Credenciales

- No escribas API keys en archivos versionados.
- No registres headers Authorization.
- Rota credenciales expuestas.
- Limita permisos por entorno.
- Usa un timeout finito y circuit breaker externo.
