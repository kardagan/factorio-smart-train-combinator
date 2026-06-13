# Smart Train Combinator

A Factorio 2.0 mod. A train-stop combinator that validates **each wagon's dedicated buffer
individually** before calling a train — instead of pooling all of a station's storage together.

## Why

The usual approach (and the original [Simple Train Combinator](https://mods.factorio.com/mod/simple-train-combinator))
sums all of a station's storage and does `floor(total / train_capacity)`. Nothing guarantees that
*each* wagon's buffer actually holds its share, so a train can be called while one bay is still
empty. Smart Train Combinator checks every wagon's own buffer and only calls a train when each one
is genuinely ready.

## How it works

Two entities, wired entirely by cable (no proximity magic):

- **Smart Train Combinator** (2×2) — the brain. Wire it to the train stop and to the probes.
- **Freight Bay Probe** (1×2) — a passive shell, **one per wagon**. Wire its **input** side to that
  wagon's buffer chests/tanks, and its **output** side to the main combinator.

Each tick the main reads every probe's buffer network *in isolation* (wagons never sum), computes
per wagon `floor(buffer / per-wagon capacity)` when loading (or `floor(free / capacity)` when
unloading), and calls:

```
trains = MIN over wagons of that value, clamped to your Max
```

So 3 probes means trains are treated as 3 wagons long, and the bottleneck wagon decides.

## Features

- Cargo (items, any quality) **and** fluids. Per-wagon capacity is read from the chosen
  rolling-stock prototype, so modded wagons work.
- Drives the stop: **train-limit** signal (default `signal-L`) and an optional **priority** signal
  (default `signal-P`) on a High / Important / Medium / Low level scaled by station fill.
- **Auto-naming**: builds the stop name from the tracked good, a green (load) / red (unload) arrow,
  and one wagon icon per bay — with a live preview.
- Three windows: **base config**, **train-stop config**, and a **per-wagon buffer monitor**.
- Blueprint, copy/paste and parametrization support.
- English and French locale.
- **Nullius** and **Ultracube** compatible.

## Usage

1. Research **Smart Train Combinator** and build one main + one probe per wagon of your trains.
2. Wire each probe's **input** to that wagon's buffer chests/tanks (red/green, as you like).
3. Wire each probe's **output** to the main combinator.
4. Wire the main to the train stop.
5. Open the main, pick the tracked item/fluid, the wagon type, the direction (load/unload) and your
   max trains. Enable train-limit / auto-naming / priority as needed.

## Screenshots

<!-- Add screenshots here, e.g. ![Setup](docs/setup.png) -->

## Credits

Inspired by **Simple Train Combinator** by *Odja_Anarchist* (GPLv3). This is an independent
implementation (no code reused), not a fork.

## License

[MIT](LICENSE) © 2026 kardagan
