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

539 tests across seven modules. Every one of the fifty algorithms is tested
against a known input with an expected output, and every network client is
tested against a stubbed transport — including the paths that fail, which are
the ones that matter and the ones a live-network test would never reach
reliably.

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
  SeismicServices        HTTP with backoff, the AI analyst, retrieval, cloud
SeismicWidgets/          Home-screen widget and the Live Activity
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

During development a `.env` at the repository root is copied into the app
bundle by a build phase, so the vault finds it on first launch. **Debug builds
only** — a release build never carries it, and any stale copy from a previous
debug build is removed. On a real device you can also drop a `.env` into the
app's documents directory through the Files app without rebuilding.


Every credential loads from `.env`, which is gitignored. `.env.example` lists
all of them with a one-line purpose. **None is required.** Each key upgrades one
simulated path to a live one; without it the app uses a bundled or on-device
fallback that works completely. Settings → API Keys can paste, replace, test or
clear any key, and shows per-key status. Keys typed there override `.env`.

Three services are used that need no key at all, which is worth saying plainly
because the opposite is usually assumed: the USGS earthquake feed, USGS
aftershock forecasts, and OpenStreetMap tiles.

## The parts that are easy to miss

**The working is shown.** Analysis is a whole screen of it: the Welch spectrum a
period was picked off, with the smoothing as a toggle rather than a silent
default; the peaks and their prominences; three independent period estimates
side by side; the Hilbert envelope the damping was fitted to; a response
spectrum with your building's period marked on it; and a spectrogram, where a
building that softens during an earthquake shows it as a bright band sliding
downwards.


**The analyst cannot invent a number.** Any answer it produces is checked
against the facts it was given; a numeric token that appears nowhere in them
means the whole answer is discarded and the deterministic on-device narrator is
used instead, with the substitution stated on screen. A fluent paragraph
containing a measurement nobody took is the one failure this app cannot ship.

**You can hear a building.** Its period is transposed up six octaves — a pure
multiplication, so every ratio survives — and played. Play the before and after
periods together and the change stops being a percentage: two tones nine hertz
apart beat against each other nine times a second, and you hear the damage as a
throb. People who cannot read a spectrum trust their own ears immediately.

**The Live Activity is the real interface.** Nobody unlocks a phone and finds an
app during an earthquake. The countdown, the instruction and eventually the
verdict appear on the Lock Screen and in the Dynamic Island, and the sequence is
ended deliberately with the verdict left visible for five minutes afterwards.

**The network screen demonstrates its own failure.** Three sensors in a line
produce a confident-looking epicentre in the wrong place. There is a button that
does exactly that, beside the button that does it properly, and the azimuthal
gap is the number that gives the bad one away.

**Nothing needs a key.** Wikidata, OpenStreetMap and the USGS feed are the
highest-quality sources in the app and all three are free, so building import
and the live earthquake feed work on a fresh install with an empty `.env`.

## Demonstrating it

Node → Demonstration has explicit controls to inject a magnitude 6.4 nearby, a
distant magnitude 7.4, structural damage, and a connection drop mid-event. These
are labelled and in the open rather than hidden behind a debug flag, because the
product is meant to be shown to somebody without hardware.

Presentation mode drives the app itself through a ninety-second argument —
building, simulation, warning, measurement, map — captioning each beat a moment
before it happens, so an audience is looking at the right part of the screen when
it changes. It is in the ⋯ menu.

To open straight onto any screen — useful for screenshots and demos. Every
section works, not only the five with tabs:

```
SEISMIC_INITIAL_TAB=simulator
SEISMIC_INITIAL_TAB=prepare
SEISMIC_INITIAL_TAB=network
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

**A model that says nothing is better than one that guesses.** Two sources that
disagree about a building's height are never averaged, because the average is a
number neither of them claims. The higher-confidence value is kept, the conflict
is recorded in its provenance, and the confidence goes down rather than up.

**Every spoken line has a local twin.** The emergency sentences are pre-rendered
after each assessment, so the line that would be spoken during the *next* event
is already cached before it happens — and if it is not, the device's own voice
says the same words immediately. A voice that needs a network is a voice that
fails at exactly the moment the network does.
