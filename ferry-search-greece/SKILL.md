---
name: ferry-search-greece
description: Find ferry itineraries, schedules, and booking links for Greece by combining ferries.gr with operator and terminal sites. Use when users ask for routes, departure times, fares, booking alternatives, or alternatives for island-to-island travel.
---

# Ferry Search Greece

## Overview

Use this skill when a user needs to find Greek ferry options between ports (islands and mainland) and compare schedule, duration, price band, and booking path.

## Quick start

Capture request intent first:

- Origin port
- Destination port
- Travel date/time
- Passengers and vehicle type
- Fare class preferences
- Transfer tolerance and maximum layover
- Flexible dates yes/no

If any field is missing, ask 1-2 clarifying questions and proceed with best-available options.

## Search process (ferries.gr-first)

1. Use ferries.gr-style search for the route and date, including direct and one-stop itineraries.
2. Capture top options by departure time, crossing duration, and capacity/vehicle support.
3. Open official operator pages for confirmation if ferries.gr lacks transparent pricing, luggage policy, or vehicle rules.
4. Return a ranked list with:
   - Operator
   - Route and ports
   - Departure/arrival times
   - Crossing duration
   - Fare bands or exact fare when visible
   - Vehicle restrictions
   - Booking link or source
5. Offer fallback windows if no direct sailing exists.

## Fallback sources

See `references/ferry-sources.md` for source list and query templates.

Use fallback sources when:

- User wants a single preferred operator.
- Route is seasonal or recently disrupted.
- ferries.gr result is incomplete or ambiguous.

## Output format

Respond with:

- A short summary sentence.
- 3 to 5 candidate options, highest confidence first.
- One paragraph on why each candidate fits the user constraints.
- A clear next step for booking and a policy check list (vehicle, pet, cancellation).
- Uncertainty note when fares or occupancy are not visible.

## Boundaries

- Do not invent routes, operators, or fares.
- Do not assume capacity guarantees unless a source confirms it.
- Do not browse non-Greek operators unless the route is explicitly international.

## Resources

- `references/ferry-sources.md`
