# ══════════════════════════════════════════════════════════════════ #
# PTC Yard Allocation — HTTP API Server
# 
# Wraps the Multi-Yard MILP as a local web API.
# The chat widget sends POST /solve with JSON inputs,
# this server runs the MILP and returns the recommended slot.
#
# Usage:
#   1. Place this file in the same folder as your Yards/ directory
#   2. Run:  julia milp_server.jl
#   3. Open chat_widget.html in a browser
#   4. The widget talks to http://localhost:8080/solve
# ══════════════════════════════════════════════════════════════════ #

import Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()

using Statistics, LinearAlgebra, Random, SparseArrays
using JuMP, HiGHS
using CSV, DataFrames, XLSX
using HTTP, JSON3

# ══════════════════════════════════════════════════════════════════ #
# YARD-SPECIFIC LADEN COEFFICIENTS (from regression)
# ══════════════════════════════════════════════════════════════════ #
const LADEN_COEFFICIENTS = Dict(
    "One"   => (laden = 1.45787, laden_tier = -0.18356),
    "Two"   => (laden = 0.22452, laden_tier = -0.04366),
    "Three" => (laden = 0.0,     laden_tier = 0.0),
    "R"     => (laden = 0.85601, laden_tier = 0.0),
    "M"     => (laden = 0.0,     laden_tier = 0.0),
)

# ══════════════════════════════════════════════════════════════════ #
# HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════ #
is_blank_cell(x) = ismissing(x) || strip(string(x)) == ""

function remove_fully_empty_rows(df::DataFrame)
    filter(row -> !all(is_blank_cell, row), df)
end

function remove_rows_missing_key(df::DataFrame, key::Symbol)
    if !(key in names(df))
        return df
    end
    filter(row -> !is_blank_cell(row[key]), df)
end

function parse_location(loc::AbstractString)
    m = match(r"^(.*)([A-Z])(\d+)$", strip(loc))
    m === nothing && return nothing
    return (block = m.captures[1], col = m.captures[2], tier = parse(Int, m.captures[3]))
end

function lower_stack_locations(loc::AbstractString)
    p = parse_location(loc)
    p === nothing && return String[]
    p.tier == 1 && return String[]
    return [string(p.block, p.col, t) for t in 1:(p.tier - 1)]
end

function eta_segment(eta::Real)
    return eta < 120 ? "low" : "high"
end

function tier_preference_score(tier::Int, target_tier::Int, incoming_eta::Real, bigM::Int)
    if incoming_eta < 120
        return tier >= target_tier ? (tier - target_tier) : (bigM + (target_tier - tier))
    else
        return tier <= target_tier ? (target_tier - tier) : (bigM + (tier - target_tier))
    end
end

# ══════════════════════════════════════════════════════════════════ #
# HISTORIC PREDICTION (for comparing against actual data)
# ══════════════════════════════════════════════════════════════════ #
safe_string_api(x) = ismissing(x) || x === nothing ? "" : strip(string(x))

function safe_float_api(x, default=0.0)
    s = safe_string_api(x)
    s == "" && return default
    try; return Float64(x); catch; try; return parse(Float64, s); catch; return default; end; end
end

function safe_int_api(x)
    s = safe_string_api(x)
    s == "" && return 0
    try; return Int(round(Float64(x))); catch; try; return parse(Int, s); catch; return 0; end; end
end

function predict_shift_from_history_api(
    selected_yard::String, assigned_loc::String,
    incoming_eta::Real, incoming_width::Int, incoming_laden::Int; k::Int=20)

    historic_folder = joinpath(@__DIR__, "Historic")
    historic_file = joinpath(historic_folder, "$(selected_yard)Historic.csv")
    !isfile(historic_file) && return (predicted_shift=nothing, matched_rows=0, used_rows=0)

    hist = CSV.File(historic_file) |> DataFrame
    target_size = incoming_width == 1 ? 20 : 40

    hist[!, :_Laden] = safe_int_api.(hist.Laden)
    hist[!, :_Size] = safe_int_api.(hist.ContainerSize)
    hist[!, :_Dwell] = safe_float_api.(hist.Dwell, NaN)
    hist[!, :_Shift] = safe_int_api.(hist.ShiftCount)
    hist[!, :_Loc] = safe_string_api.(hist.Location)
    hist[!, :_LocList] = safe_string_api.(hist.LocationList)

    filtered = hist[(hist._Laden .== incoming_laden) .& (hist._Size .== target_size), :]

    loc_match = [
        let l = safe_string_api(r._Loc), ll = safe_string_api(r._LocList)
            l == assigned_loc || assigned_loc in [strip(x) for x in split(ll, ",")]
        end
        for r in eachrow(filtered)
    ]
    filtered = filtered[loc_match, :]
    filtered = filtered[.!isnan.(filtered._Dwell), :]

    nrow(filtered) == 0 && return (predicted_shift=nothing, matched_rows=0, used_rows=0)

    filtered[!, :_dd] = abs.(filtered._Dwell .- Float64(incoming_eta))
    filtered = sort(filtered, :_dd)
    topk = filtered[1:min(k, nrow(filtered)), :]

    predicted = nrow(topk) >= 5 ? mean(topk._Shift) : nothing
    return (predicted_shift=predicted, matched_rows=nrow(filtered), used_rows=nrow(topk))
end

# ══════════════════════════════════════════════════════════════════ #
# MAIN SOLVE FUNCTION
# ══════════════════════════════════════════════════════════════════ #
function solve_milp(selected_yard::String, incoming_eta::Real,
                    incoming_width::Int, incoming_laden::Int,
                    incoming_id::Int)

    # ── Load data ──
    yards_folder = joinpath(@__DIR__, "Yards")
    state_file = joinpath(yards_folder, "$(selected_yard)State.csv")
    slots_file = joinpath(yards_folder, "$(selected_yard)Slots.csv")

    if !isfile(state_file)
        return Dict("error" => "State file not found: $state_file")
    end
    if !isfile(slots_file)
        return Dict("error" => "Slots file not found: $slots_file")
    end

    container_data = CSV.File(state_file) |> DataFrame
    slot_data = CSV.File(slots_file) |> DataFrame

    container_data = remove_fully_empty_rows(container_data)
    slot_data = remove_fully_empty_rows(slot_data)

    if :MovementId in names(container_data)
        container_data = remove_rows_missing_key(container_data, :MovementId)
    end
    if :Location in names(slot_data)
        slot_data = remove_rows_missing_key(slot_data, :Location)
    end

    if "ETA_hours" in names(container_data)
        container_data = filter(row -> !is_blank_cell(row.ETA_hours), container_data)
        if nrow(container_data) > 0
            container_data.ETA_hours = Float64.(container_data.ETA_hours)
        end
    end

    # ── Lookups ──
    occupied_lookup = Dict(row.Location => row.OccupiedNow for row in eachrow(slot_data))
    tier_lookup = Dict(row.Location => row.Tier for row in eachrow(slot_data))
    cost_lookup = Dict(row.Location => row.Cost for row in eachrow(slot_data))
    adjcost_lookup = Dict(row.Location => row.AdjCost for row in eachrow(slot_data))
    block_lookup = Dict(row.Location => string(row.Block) for row in eachrow(slot_data))

    block_order = unique(string.(slot_data.Block))
    block_positions = Dict(block => idx for (idx, block) in enumerate(block_order))

    # ── Adjacent location for 40ft ──
    function adjacent_location(loc::AbstractString)
        p = parse_location(loc)
        p === nothing && return missing
        !haskey(block_positions, p.block) && return missing
        next_pos = block_positions[p.block] + 1
        next_pos > length(block_order) && return missing
        return string(block_order[next_pos], p.col, p.tier)
    end

    # ── Feasibility checks ──
    function feasible_20ft(loc)
        !haskey(occupied_lookup, loc) && return false
        occupied_lookup[loc] != 0 && return false
        for lower in lower_stack_locations(loc)
            !haskey(occupied_lookup, lower) && return false
            occupied_lookup[lower] != 1 && return false
        end
        return true
    end

    function feasible_40ft(loc)
        partner = adjacent_location(loc)
        ismissing(partner) && return false
        !haskey(occupied_lookup, loc) && return false
        !haskey(occupied_lookup, partner) && return false
        occupied_lookup[loc] != 0 && return false
        occupied_lookup[partner] != 0 && return false
        p1 = parse_location(loc)
        p2 = parse_location(partner)
        (p1 === nothing || p2 === nothing) && return false
        p1.tier != p2.tier && return false
        for t in 1:(p1.tier - 1)
            l1 = string(p1.block, p1.col, t)
            l2 = string(p2.block, p2.col, t)
            (!haskey(occupied_lookup, l1) || !haskey(occupied_lookup, l2)) && return false
            (occupied_lookup[l1] != 1 || occupied_lookup[l2] != 1) && return false
        end
        return true
    end

    # ── Historical target tier ──
    min_tier = minimum(slot_data.Tier)
    max_tier = maximum(slot_data.Tier)
    bigM = max_tier - min_tier + 1
    threshold = 1

    same_size = nrow(container_data) > 0 ? container_data[container_data.WidthUnits .== incoming_width, :] : DataFrame()
    history_pool = nrow(same_size) >= 5 ? same_size : container_data

    if nrow(history_pool) == 0
        target_tier = incoming_eta < 120 ? max_tier : min_tier
        avg_reshifting = 0.0
    else
        hp = copy(history_pool)
        hp.eta_diff = abs.(hp.ETA_hours .- incoming_eta)
        sorted_c = sort(hp, :eta_diff)
        closest = sorted_c[1:min(10, nrow(sorted_c)), :]

        tiers_found = Int[]
        for loc in closest.Location
            rows = slot_data[slot_data.Location .== loc, :]
            nrow(rows) > 0 && push!(tiers_found, rows[1, :Tier])
        end

        avg_reshifting = mean(coalesce.(closest.ShiftCount, 0))

        if isempty(tiers_found)
            target_tier = incoming_eta < 120 ? max_tier : min_tier
        else
            target_tier = floor(Int, mean(tiers_found))
            if incoming_eta < 120
                avg_reshifting >= threshold && (target_tier += 1)
            else
                avg_reshifting >= threshold && (target_tier -= 1)
            end
            target_tier = clamp(target_tier, min_tier, max_tier)
        end
    end

    # ── Customer grouping ──
    function nearest_block_distance(block, cust_blocks)
        isempty(cust_blocks) && return typemax(Int)
        !haskey(block_positions, block) && return typemax(Int)
        valid = [b for b in cust_blocks if haskey(block_positions, b)]
        isempty(valid) && return typemax(Int)
        return minimum(abs(block_positions[block] - block_positions[b]) for b in valid)
    end

    cust_rows = nrow(container_data) > 0 ? container_data[container_data.CustomerId .== incoming_id, :] : DataFrame()
    customer_blocks = String[]
    if nrow(cust_rows) > 0
        for loc in cust_rows.Location
            !ismissing(loc) && haskey(block_lookup, loc) && push!(customer_blocks, block_lookup[loc])
        end
        customer_blocks = unique(customer_blocks)
    end
    use_grouping = !isempty(customer_blocks)

    # ── Generate candidates ──
    cand_locs = String[]
    cand_partners = String[]
    cand_blocks = String[]
    cand_partnerblks = String[]
    cand_tiers = Int[]
    cand_costs = Float64[]
    cand_prefs = Int[]
    cand_tierdiffs = Int[]
    cand_blockdists = Int[]
    cand_scores = Float64[]

    if incoming_width == 1
        for loc in slot_data.Location
            feasible_20ft(loc) || continue
            pref = tier_preference_score(tier_lookup[loc], target_tier, incoming_eta, bigM)
            td = abs(tier_lookup[loc] - target_tier)
            blk = block_lookup[loc]
            bd = use_grouping ? nearest_block_distance(blk, customer_blocks) : typemax(Int)
            push!(cand_locs, loc); push!(cand_blocks, blk); push!(cand_tiers, tier_lookup[loc])
            push!(cand_costs, float(cost_lookup[loc])); push!(cand_prefs, pref)
            push!(cand_tierdiffs, td); push!(cand_blockdists, bd)
            push!(cand_scores, 1000.0 * pref + float(cost_lookup[loc]))
        end
    else
        seen = Set{Tuple{String,String}}()
        for loc in slot_data.Location
            partner = adjacent_location(loc)
            ismissing(partner) && continue
            !haskey(adjcost_lookup, loc) && continue
            (ismissing(adjcost_lookup[loc]) || adjcost_lookup[loc] == 9999) && continue
            feasible_40ft(loc) || continue
            (loc, partner) in seen && continue
            push!(seen, (loc, partner))
            pref = tier_preference_score(tier_lookup[loc], target_tier, incoming_eta, bigM)
            td = abs(tier_lookup[loc] - target_tier)
            b1, b2 = block_lookup[loc], block_lookup[partner]
            bd = use_grouping ? min(nearest_block_distance(b1, customer_blocks), nearest_block_distance(b2, customer_blocks)) : typemax(Int)
            push!(cand_locs, loc); push!(cand_partners, partner)
            push!(cand_blocks, b1); push!(cand_partnerblks, b2)
            push!(cand_tiers, tier_lookup[loc]); push!(cand_costs, float(adjcost_lookup[loc]))
            push!(cand_prefs, pref); push!(cand_tierdiffs, td); push!(cand_blockdists, bd)
            push!(cand_scores, 1000.0 * pref + float(adjcost_lookup[loc]))
        end
    end

    if isempty(cand_locs)
        return Dict("error" => "No feasible candidates found for the incoming container.")
    end

    # Build candidates DataFrame
    if incoming_width == 1
        candidates = DataFrame(
            Location = cand_locs, Block = cand_blocks, Tier = cand_tiers,
            Cost = cand_costs, PreferenceScore = cand_prefs,
            TierDiff = cand_tierdiffs, BlockDistance = cand_blockdists, Score = cand_scores
        )
    else
        candidates = DataFrame(
            Location = cand_locs, Partner = cand_partners,
            Block = cand_blocks, PartnerBlock = cand_partnerblks,
            Tier = cand_tiers, AdjCost = cand_costs, PreferenceScore = cand_prefs,
            TierDiff = cand_tierdiffs, BlockDistance = cand_blockdists, Score = cand_scores
        )
    end

    # ── Customer grouping band filter ──
    if use_grouping
        exact = candidates[(candidates.BlockDistance .== 0) .& (candidates.PreferenceScore .== 0), :]
        if nrow(exact) > 0
            cost_col = incoming_width == 1 ? :Cost : :AdjCost
            exact.Score = exact[!, cost_col]
            candidates = exact
        else
            near = candidates[candidates.BlockDistance .<= 3, :]
            if nrow(near) > 0
                cost_col = incoming_width == 1 ? :Cost : :AdjCost
                near.Score = 1000.0 .* near.PreferenceScore .+ 10.0 .* near.BlockDistance .+ near[!, cost_col]
                candidates = near
            end
        end
    end

    # ── Laden penalty (yard-specific) ──
    yard_laden = get(LADEN_COEFFICIENTS, selected_yard, (laden = 0.0, laden_tier = 0.0))
    laden_applied = false
    if incoming_laden == 1
        laden_coef = yard_laden.laden
        laden_tier_coef = yard_laden.laden_tier
        if laden_coef != 0.0 || laden_tier_coef != 0.0
            scaling_factor = 100.0
            candidates.Score .+= (laden_coef .+ laden_tier_coef .* candidates.Tier) .* scaling_factor
            laden_applied = true
        end
    end

    # ── Solve MILP ──
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    n = nrow(candidates)
    @variable(model, X[1:n], Bin)
    @objective(model, Min, sum(candidates.Score[k] * X[k] for k in 1:n))
    @constraint(model, sum(X[k] for k in 1:n) == 1)
    optimize!(model)

    if termination_status(model) != MOI.OPTIMAL
        return Dict("error" => "Solver did not find optimal solution.")
    end

    X_opt = round.(Int, value.(X))
    chosen_idx = findfirst(==(1), X_opt)
    chosen = candidates[chosen_idx, :]

    # ── Historic prediction ──
    assigned_location = string(chosen.Location)
    predicted_shift = nothing
    historic_matched = 0
    historic_used = 0
    try
        hist_result = predict_shift_from_history_api(
            selected_yard, assigned_location, incoming_eta, incoming_width, incoming_laden
        )
        predicted_shift = hist_result.predicted_shift
        historic_matched = hist_result.matched_rows
        historic_used = hist_result.used_rows
    catch e
        # Historic prediction is optional — don't fail the whole request
        println("[WARN] Historic prediction failed: ", sprint(showerror, e))
    end

    # ── Build response ──
    result = Dict(
        "yard" => selected_yard,
        "location" => assigned_location,
        "block" => string(chosen.Block),
        "tier" => chosen.Tier,
        "score" => round(chosen.Score, digits=2),
        "target_tier" => target_tier,
        "laden_applied" => laden_applied,
        "laden_coef" => yard_laden.laden,
        "laden_tier_coef" => yard_laden.laden_tier,
        "customer_grouping" => use_grouping,
        "total_candidates" => n,
        "container_type" => incoming_width == 1 ? "20ft" : "40ft",
        "predicted_shift" => predicted_shift,
        "historic_matched" => historic_matched,
        "historic_used" => historic_used,
    )

    if incoming_width == 2 && :Partner in names(chosen)
        result["partner"] = string(chosen.Partner)
        result["partner_block"] = string(chosen.PartnerBlock)
    end

    return result
end

# ══════════════════════════════════════════════════════════════════ #
# HTTP SERVER
# ══════════════════════════════════════════════════════════════════ #
function handle_solve(req::HTTP.Request)
    # CORS headers for browser access
    headers = [
        "Content-Type" => "application/json",
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "POST, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type",
    ]

    # Handle preflight
    if req.method == "OPTIONS"
        return HTTP.Response(200, headers, "")
    end

    try
        body = JSON3.read(String(req.body))

        yard = string(get(body, :yard, "One"))
        eta = Float64(get(body, :eta, 240))
        width = Int(get(body, :width, 1))
        laden = Int(get(body, :laden, 1))
        customer_id = Int(get(body, :customer_id, 1))

        println("\n[REQUEST] Yard=$yard, ETA=$eta, Width=$width, Laden=$laden, Customer=$customer_id")

        result = solve_milp(yard, eta, width, laden, customer_id)

        println("[RESULT] ", result)

        return HTTP.Response(200, headers, JSON3.write(result))
    catch e
        err_msg = sprint(showerror, e)
        println("[ERROR] ", err_msg)
        return HTTP.Response(500, headers, JSON3.write(Dict("error" => err_msg)))
    end
end

function handle_health(req::HTTP.Request)
    headers = [
        "Content-Type" => "application/json",
        "Access-Control-Allow-Origin" => "*",
    ]
    return HTTP.Response(200, headers, JSON3.write(Dict("status" => "ok")))
end

# Start server
const ROUTER = HTTP.Router()
HTTP.register!(ROUTER, "POST", "/solve", handle_solve)
HTTP.register!(ROUTER, "OPTIONS", "/solve", handle_solve)
HTTP.register!(ROUTER, "GET", "/health", handle_health)

println("═══════════════════════════════════════")
println("  PTC Yard Allocation API Server")
println("  Running on http://localhost:8080")
println("  POST /solve  — run the MILP")
println("  GET  /health — check server status")
println("═══════════════════════════════════════")

HTTP.serve(ROUTER, "0.0.0.0", 8080)
