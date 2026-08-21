# Ferry Search Sources (Greece)

## Primary source

- ferries.gr
  - Use as first-pass route and schedule aggregator for Greek domestic routes.
  - Prioritize visible departure/arrival times, operator name, and crossing duration.

## Operator fallback sources

Use these when ferries.gr is incomplete or when the user asks for direct operator pages:

- Blue Star Ferries
- SeaJets
- Anek
- Hellenic Seaways
- Minoan Lines
- Superfast Ferries
- Any local terminal site shown in official result context

For each operator, prefer the official schedule/booking page and confirm:

- Vehicle class rules
- Pet policy
- Change/cancel terms
- Onboard amenities (if requested)

## Query templates

- `site:ferries.gr [origin] [destination] [date] ferry`
- `[origin] [destination] ferry schedule [operator]`
- `[origin] ferry port departures [month]`

## Comparison criteria

- Shortest crossing time
- Number of stops
- Vehicle acceptance
- Fare predictability
- Transfer time at hubs
- Booking deadline and fare class constraints
