# Politica De Seguridad

## Versiones Mantenidas

| Version | Estado | Canal |
| --- | --- | --- |
| 1.0.x | mantenida | `main`, `production` y tags `v1.0.x` |
| anteriores | sin soporte | solo referencia historica |

Las evaluaciones deben realizarse contra el tag anotado mas reciente. Un SHA de
branch sin tag no constituye una version publicada.

## Comunicacion Privada

Utiliza **GitHub Security Advisory** en la pestaña Security del repositorio.
No abras issues, discusiones ni pull requests con detalles sensibles.

Incluye:

- version, commit y red utilizados;
- contratos y funciones afectados;
- precondiciones y secuencia minima reproducible;
- impacto economico cuantificado en unidades atomicas;
- estado contable antes y despues;
- propuesta de contencion y expectativas de regresion.

No adjuntes credenciales, claves privadas, seeds, tokens de acceso ni datos de
terceros. Revoca cualquier secreto que haya quedado expuesto durante la
investigacion.

## Limites De Prueba

- Trabaja con despliegues propios y cuentas bajo tu control.
- No interrumpas servicios compartidos ni automatizaciones de terceros.
- No realices ingenieria social, phishing o acceso fisico.
- Evita volumen que pueda degradar RPC, indexadores o proveedores.
- Conserva logs, hashes y timestamps suficientes para reproducir el resultado.

## Invariantes Economicas

Custodia:

```text
balanceFisico(collateral) >= lotesActivos + claimsPendientes
```

Settlement:

```text
sellerCredit == winningBidAmount
winnerDebtPaid == winningBidAmount
```

Distribucion:

```text
winnerCollateral + sum(partialCollateral) <= collateralAmount
```

Garantias:

```text
guarantee == max(1, floor(bidAmount * guaranteeBps / 10_000))
```

Gobierno:

```text
execute => delayCumplido && quorumVigente && payloadComprometido
```

## Superficies Prioritarias

- orden entre efectos de estado e interacciones ERC-20;
- callbacks de bidders y tokens con comportamiento no estandar;
- redondeos en incrementos, garantias y distribucion de lotes;
- extensiones repetidas cerca del cierre;
- conciliacion entre AuctionHouse, vault, ledger e indexador;
- cambios de rol durante la ventana de gobierno;
- expiracion, cancelacion y dependencias entre operaciones;
- respuestas HTTP parciales, stale o con identificadores inconsistentes.

## Proceso De Respuesta

1. Se acusa recibo y se fija un identificador privado.
2. Se reproduce en un entorno aislado con el commit indicado.
3. Se cuantifican saldos, obligaciones y alcance.
4. Se prepara contencion, cambio y prueba de regresion.
5. Se ejecuta el gate completo en Ubuntu y Windows.
6. Se publica una version anotada y se verifica su integridad.
7. Se coordina cualquier comunicacion posterior.

Los tiempos dependen de reproducibilidad, impacto y complejidad. La ausencia de
respuesta automatica no autoriza divulgacion inmediata.

## Controles Automatizados

```powershell
.\.venv\Scripts\python.exe scripts\ci.py
```

```bash
python scripts/ci.py
```

El gate regenera artefactos deterministas, compila Vyper, ejecuta tests,
comprueba formato, lint, limites de fuente, metadata, documentacion y banner.

## Dependencias Y Cadena De Suministro

- Las dependencias Python permanecen fijadas por version.
- Dependabot revisa `pip` y GitHub Actions semanalmente.
- Los workflows declaran permisos de solo lectura por defecto.
- La release exige tag anotado y paridad entre `main`, `production` y el objeto
  pelado del tag.
- No se aceptan binarios generados sin fuente y procedimiento reproducible.

## Reconocimiento

El reconocimiento se acuerda durante la coordinacion privada y depende de que
la comunicacion respete esta politica y permita completar la respuesta tecnica.
