# YardOptimiser

A **Mixed-Integer Linear Programming (MILP)** system for optimal container slot allocation across multiple yard locations at PTC (Poh Tiong Choon) port terminal. Given an incoming container, the solver finds the single best available slot — minimising reshifting, respecting physical stacking rules, and grouping containers by customer.

## The Optimisation Model

### Problem
Assigning an incoming container to the wrong slot creates costly reshifting operations later — containers stacked on top must be moved to access one below. The goal is to assign each incoming container to the slot that minimises expected future disruption.

### Decision Variable
A binary assignment vector **X ∈ {0,1}ⁿ** over all feasible candidate slots, with the constraint that exactly one slot is selected:

```
min   Σ score(i) · X(i)
s.t.  Σ X(i) = 1
      X(i) ∈ {0, 1}
```

### Feasibility Constraints
Candidate slots are filtered before the MILP is built:

- **20ft containers**: the slot must be unoccupied, and all tiers below it must be occupied (no floating containers)
- **40ft containers**: two horizontally adjacent slots across consecutive blocks must both be unoccupied, at the same tier, with all tiers below both occupied

### Objective Function
Each candidate slot is scored as:

```
score = 1000 × tier_preference + slot_cost
```

**Tier preference** is derived from the container's ETA and historical reshifting data:
- Short ETA (< 120h) → target higher tiers (container leaves soon, needs to be accessible)
- Long ETA (≥ 120h) → target lower tiers (container stays long, stack above it)
- A KNN lookup over historical movements (k=10 nearest by ETA) infers the target tier and adjusts it up or down based on average past reshifting

**Slot cost** is the base repositioning cost from the yard layout, used as a tiebreaker within the same tier preference band.

### Laden Penalty
For laden (full) containers, yard-specific regression coefficients add a penalty based on tier:

```
laden_penalty = (laden_coef + laden_tier_coef × tier) × 100
```

Coefficients are empirically derived per yard from historical data.

### Customer Grouping
If the incoming customer already has containers in the yard, the solver prioritises slots in the same or adjacent blocks (within distance 3). Exact same-block placements with zero tier penalty take absolute priority.

### Predicted Reshifting
After slot selection, a KNN lookup over the historic dataset (k=20, filtered by laden status, container size, and assigned location) predicts the expected number of reshifts. This is returned alongside the recommended slot.

---

## Yards

| Name | Key |
|------|-----|
| Yard One | `One` |
| Yard Two | `Two` |
| Yard Three | `Three` |
| Yard R | `R` |
| Yard M | `M` |

---

## Project Structure

```
YardOptimiser/
├── milp_server.jl             Julia HTTP server (MILP solver + REST API)
├── index.html                 Web dashboard with chat widget (Power BI src not included)
├── MultiYard Optimiser.ipynb  Development notebook (same MILP logic)
├── Project.toml               Julia package dependencies
├── Historic/                  Per-yard historical container movement CSVs (not tracked)
└── Yards/                     Per-yard current slot and occupancy state CSVs (not tracked)
```

## Running the Server

Requires [Julia](https://julialang.org/downloads/) 1.9+.

```bash
julia milp_server.jl
```

On first run, dependencies are installed automatically via `Pkg.instantiate()`. The server starts on `http://localhost:8080`.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/solve` | POST | Run the MILP and return the recommended slot |
| `/health` | GET | Server health check |

### Request Format

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
| `width` | integer | `1` = 20ft, `2` = 40ft |
| `laden` | integer | `1` = laden, `0` = empty |
| `customer_id` | integer | Customer ID for grouping preference |

## Data File Formats

Data files are not tracked in version control.

**`Yards/<YardName>Slots.csv`** — physical slot definitions:
`Location, Block, Column, Tier, OccupiedNow, Cost, AdjCost`

**`Yards/<YardName>State.csv`** — current occupancy snapshot:
`MovementId, CustomerId, ContainerSize, Laden, Location, ETA_hours, WidthUnits, ShiftCount`

**`Historic/<YardName>Historic.csv`** — historical movements for KNN prediction:
`Laden, ContainerSize, Location, LocationList, Dwell, ShiftCount`

## Power BI Dashboard

The background dashboard iframe in `index.html` has its `src` removed from this repo. To restore it, set the `src` attribute of `#dashboard-frame` to your Power BI publish-to-web embed URL.
