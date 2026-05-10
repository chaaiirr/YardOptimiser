# YardOptimiser

A Mixed-Integer Linear Programming (MILP) system for optimal container slot allocation across multiple yard locations at PTC (Poh Tiong Choon) port terminal.

Given an incoming container's attributes (yard, size, laden status, ETA, customer ID), the solver recommends the best available slot using:
- Physical stacking feasibility constraints (20ft / 40ft pairing)
- ETA-based tier targeting with historical reshifting data
- Customer grouping preference
- Yard-specific laden penalty coefficients

## Project Structure

```
YardOptimiser/
├── milp_server.jl          Julia HTTP server (MILP solver + REST API)
├── index.html              Web dashboard with chat widget (Power BI src not included)
├── MultiYard Optimiser.ipynb  Development notebook (same MILP logic)
├── Project.toml            Julia package dependencies
├── Manifest.toml           Julia dependency lock file
├── Historic/               Per-yard historical container movement CSVs
└── Yards/                  Per-yard current slot and occupancy state CSVs
```

## Prerequisites

- [Julia](https://julialang.org/downloads/) 1.9 or later
- [ngrok](https://ngrok.com/) (optional — only needed to expose the server externally)

## Power BI Dashboard

The background dashboard iframe in `index.html` has its `src` removed from this repo. To restore it, set the `src` attribute of `#dashboard-frame` to your Power BI publish-to-web embed URL.

## Running the Server

```bash
julia milp_server.jl
```

On first run, Julia will automatically install all dependencies via `Pkg.instantiate()`. This may take a few minutes.

The server starts on `http://localhost:8080` and exposes:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/solve` | POST | Run the MILP and return the recommended slot |
| `/health` | GET | Server health check |

## Configuring the API URL

By default `index.html` points to `http://localhost:8080` for local use. To expose the server externally, start an ngrok tunnel:

```bash
ngrok http 8080
```

Then update line 752 of `index.html` with your tunnel URL:

```js
const API_BASE = 'https://your-tunnel-id.ngrok-free.app';
```

See `.env.example` for the config template.

## POST /solve — Request Format

```json
{
  "yard":        "One",
  "eta":         240,
  "width":       1,
  "laden":       1,
  "customer_id": 42
}
```

| Field | Type | Description |
|-------|------|-------------|
| `yard` | string | Yard name: `One`, `Two`, `Three`, `R`, or `M` |
| `eta` | number | Estimated time of arrival in hours |
| `width` | integer | `1` = 20ft container, `2` = 40ft container |
| `laden` | integer | `1` = laden (full), `0` = empty |
| `customer_id` | integer | Customer identifier for grouping preference |

## Data File Formats

Data files are not tracked in version control. Place them in the correct directories before starting the server.

**`Yards/<YardName>Slots.csv`** — physical slot definitions for each yard:
`Location, Block, Column, Tier, OccupiedNow, Cost, AdjCost`

**`Yards/<YardName>State.csv`** — current container occupancy snapshot:
`MovementId, CustomerId, ContainerSize, Laden, Location, ETA_hours, WidthUnits, ShiftCount`

**`Historic/<YardName>Historic.csv`** — historical movements for KNN-based shift prediction:
`Laden, ContainerSize, Location, LocationList, Dwell, ShiftCount`

## Yards

| Name | Key |
|------|-----|
| Yard One | `One` |
| Yard Two | `Two` |
| Yard Three | `Three` |
| Yard R | `R` |
| Yard M | `M` |
