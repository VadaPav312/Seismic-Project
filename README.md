# Seismic

A native iOS app that warns before an earthquake's destructive wave arrives, acts
to make a building safe, measures whether that building's structural behaviour
changed, and lets anyone pull a real building into a 3D simulator and shake it
with a real earthquake record.

## Opening it

```
open Seismic.xcodeproj
```

Select the **Seismic** scheme and run. There is nothing to configure: no
hardware, no API keys, no network. The app seeds itself on first launch with a
library of real buildings, ten historic earthquake records, a year of synthetic
measurement history and a populated community map, and it connects to a
simulated seismic node that generates physically realistic data.

Requires Xcode 16 or later and iOS 17+.

### Running the tests

```
cd SeismicKit && swift test
```

489 tests across seven modules. Every one of the fifty algorithms is tested
against a known input with an expected output.

## What is here

```
Seismic.xcodeproj        The app target (file-system synchronised — new files
                         are picked up without editing the project)
Seismic/                 SwiftUI app: design system, charts, 3D simulator, screens
SeismicKit/              All logic, as a multi-module Swift package
  SeismicCore            Units, domain types, secrets, shared maths
  SeismicSignal          Algorithms 1–34: conditioning, detection, spectra, modal
  SeismicGeo             Algorithms 35–38 plus spatial indexing and geometry
  SeismicStructures      Algorithms 39–50: the solver and the assessment
  SeismicDevice          BLE protocol, chunked transfer, the simulated node
  SeismicData            Persistence, seed library, tamper-evident ledger, sync
  SeismicServices        Reserved for the networked service clients
.env.example             Every environment variable, with its purpose and what
                         happens when it is absent
```

Nothing in `SeismicKit` imports SwiftUI, so all of it is testable on any machine
without a simulator.

## The idea

A building sways at a natural period set by its stiffness. Damage reduces
stiffness, so the period lengthens — typically 10–30% for significant damage,
which is a large and measurable change.

The difficulty is that temperature moves it by a few per cent too. Cold concrete
is stiffer, so a building genuinely sways faster on a January morning than on a
July afternoon, by about as much as real damage would. A system that ignored
that would cry wolf every winter, and after two false alarms nobody would
believe the true one. So the measured period is normalised against a
temperature-frequency regression fitted to that specific building's own history,
with outlier rejection — and the result is cross-checked against residual
displacement and permanent tilt, which temperature cannot explain away.

## Configuration

Every credential loads from `.env`, which is gitignored. `.env.example` lists
all of them with a one-line purpose. **None is required.** Each key upgrades one
simulated path to a live one; without it the app uses a bundled or on-device
fallback that works completely. Settings → API Keys can paste, replace, test or
clear any key, and shows per-key status. Keys typed there override `.env`.

Three services are used that need no key at all, which is worth saying plainly
because the opposite is usually assumed: the USGS earthquake feed, USGS
aftershock forecasts, and OpenStreetMap tiles.

## Demonstrating it

Node → Demonstration has explicit controls to inject a magnitude 6.4 nearby, a
distant magnitude 7.4, structural damage, and a connection drop mid-event. These
are labelled and in the open rather than hidden behind a debug flag, because the
product is meant to be shown to somebody without hardware.

To open straight onto a given screen — useful for screenshots and demos:

```
SEISMIC_INITIAL_TAB=simulator
```

## Notes on a few decisions

**The simulated node is a first-class citizen, not a mock.** It runs the same
STA/LTA detector the firmware runs, streams a genuine noise floor with the
building's own resonance in it, serialises actuators against the real USB power
budget, browns out if asked to move two motors at once, drifts its period with
temperature, and permanently softens when it decides the building was damaged.
Every screen is therefore exercised by realistic data during development.

**Actuators fire one at a time.** A USB port supplies 500 mA; the board takes
about 180 mA and a servo draws around 250 mA while turning a valve. Two at once
browns out the microcontroller — mid-earthquake, having already been told to
close the gas. The app presents the sequence as a timeline, which is also the
clearest way to show that each action was independently confirmed.

**Nothing contributes to a verdict invisibly.** Each measurement becomes a
stated piece of evidence with its own headline, explanation, source and weight,
and the assessment screen lists all of them. Contradictory evidence widens the
reported interval rather than being averaged away, and a wide interval produces
"needs inspection" rather than being rounded down to green.

**Green, amber and red are reserved for structural verdicts** and appear nowhere
else in the interface. Every verdict also carries a distinct glyph and border
weight, so it survives colour blindness, greyscale and a cracked screen.
