# Presenting Seismic in 3 minutes 30

One phone, one Arduino, no laptop. Times are cumulative — glance at them, don't
recite them.

## Before you start (do this five minutes early)

- [ ] Board powered, BLE module **blinking** not steady. Steady means it is
      already paired to something else and you will not find it.
- [ ] **Serial1 baud matches.** `arduino.ino:608` is `Serial1.begin(115200)`.
      Most HM-10s ship at 9600. If they disagree you get a connected link that
      is silent — the Hardware screen says so after four seconds, but find out
      now, not on stage.
- [ ] Phone: Bluetooth on, **Do Not Disturb on**, brightness up, screen
      auto-lock off.
- [ ] Open the app, go to **Node → Find a node → Connect to a Bluetooth
      device**, connect, and confirm the Hardware screen says
      *"Link open — listening on FFE1"*. Then leave it connected.
- [ ] Sign out, so you can demonstrate signing in.

**The single most important thing:** everything works with the board switched
off. If it fails, say *"the simulated node runs the same firmware logic through
the same parser"*, tap **Use the simulated node**, and carry on. Nothing in this
script breaks.

---

## 0:00 — The problem (20 s)

> "After an earthquake, the question everybody has is: can I go back inside?
> Today that is answered by a human inspector, and there are not enough of them
> — after Christchurch some buildings waited **weeks**. This building answers
> it itself, in about a minute."

Don't touch the phone yet. Let them look at you.

## 0:20 — Sign in (25 s)

Tap **Continue with Google**. While the browser sheet is up:

> "Google sign-in through Supabase — real OAuth, PKCE, no client secret in the
> app. Supabase is the whole backend: Postgres with row-level security, so a
> row is only ever readable by the household that owns it."

When it lands:

> "But sign-in is optional. **Continue without an account** gives you a guest
> that works identically — everything is local-first and the cloud is a replica,
> because earthquakes take down networks. That is not an edge case, it is the
> expected operating condition."

**If the network is bad:** tap *Continue without an account* and say that line
instead. It is the stronger point anyway.

## 0:45 — The building, in 3D (35 s)

Tab: **Simulate**.

> "This is my building as a structural model. Eight storeys, each with a real
> mass and a real stiffness. The shape is not decoration — this footprint came
> from OpenStreetMap, and plan irregularity is one of the strongest predictors
> of earthquake damage there is."

Switch the building to **Tokyo Skytree**:

> "Any building on Earth. Height and footprint from Wikidata and OpenStreetMap —
> both free, no key — and every fact carries its source. Where two sources
> disagree we keep the better one and *lower* the confidence, rather than
> averaging them into a number neither of them claims."

Tap **Shake**.

> "Real earthquake record, real time-history solver. Watch the top."

## 1:20 — The node detects (40 s) ← **the centrepiece**

Orb → **Hardware**. Point at the board.

> "This is the node. Arduino MEGA, accelerometer, tilt switch, microphone."

**Shake the board with your hand.** Then be quiet and let the phone talk. The
Live Commentary panel narrates it:

> *"I can feel the building moving and I can hear it — that's 2 of my 3 sensors,
> so I'm declaring it."*

When the vote lands, say the one line that matters:

> "**Three sensors have to agree.** One is a slammed door. Two is an
> earthquake. Watch —"

Now **tap the board once, gently** — one channel only.

> "One sensor voting. It refuses. That refusal is the difference between a
> system people keep switched on and one they turn off after the second false
> alarm."

## 2:00 — It acts, and it proves it (35 s)

Press **TEST EARTHQUAKE**. Point at the actuators as they fire:

> "Power cut — and it does not take its own word for it. There is a
> photoresistor watching the lamp, and the light went 320 to 890. A command
> that was *sent* is a rumour. A command whose effect was *measured* is a fact,
> and only one of those belongs in a safety report."

> "Then the water main, 800 ms later. One motor at a time — a USB port gives you
> 500 mA, the board takes 180 and a servo takes 250. Two at once browns out the
> microcontroller mid-earthquake. The gas valve is modelled and **not fitted**,
> and the app says so rather than pretending."

The 911 screen appears on its own:

> "And it calls emergency services with the address, the construction, whether
> anyone was home, and which utilities are confirmed off. Nothing is dialled —
> the banner says so — but the report is real, and it only lists shutoffs that
> were *physically confirmed*. Telling a dispatcher the power is off when it
> might not be is how a firefighter gets hurt."

## 2:35 — The measurement (35 s) ← **the actual idea**

Orb → **Assess**.

> "Here is the part that is not a gadget. A building sways at a period set by
> its stiffness. Damage removes stiffness, so the period gets **longer** —
> 10 to 30% for real damage, which is large and easy to measure."

> "The problem is that cold concrete is stiffer, so a building genuinely sways
> faster in January by about as much as damage would. A system that ignored that
> cries wolf every winter. So we normalise against a temperature-frequency
> regression fitted to **this building's own history**, with outlier rejection,
> and cross-check against residual displacement and permanent tilt — which
> temperature cannot explain away."

Point at the evidence list:

> "Every piece of evidence is listed with its weight and its source. Nothing
> contributes invisibly, and evidence that *disagrees* widens the interval
> rather than being averaged away — a wide interval says 'needs inspection'
> instead of being rounded down to green."

## 3:10 — The keys, and the map (20 s)

Orb → **Map**.

> "Verdicts publish to a map, so a street sees itself instead of waiting for an
> inspector."

Settings → **API keys** (one second, just show the list):

> "Gemini and Cerebras for the analyst, ElevenLabs for the emergency voice,
> Serper, Tavily and Exa for building import, OpenWeather for temperature.
> **None of them is required.** Every key upgrades one path from a bundled
> fallback to a live one, and the app is complete with an empty `.env`. The
> three best sources in here — USGS, OpenStreetMap, Wikidata — are free and
> need no key at all."

> "And the analyst cannot invent a number. Any answer is checked against the
> facts it was given; a figure that appears nowhere in them throws the whole
> answer away and falls back to a deterministic on-device narrator, and the
> screen says that happened."

## 3:30 — Stop talking

> "976 tests. Everything you saw works with no hardware, no keys and no network."

---

## The four questions you will be asked

**"Is the shaking real or a simulation?"**
Both, and the app never blurs them. The board's accelerometer is real. The
simulator is marked synthetic on every screen it touches. The 3D shake used a
recorded earthquake through a real solver.

**"What if the phone isn't connected?"**
The node acts on its own — it is not a peripheral, the phone is a display. It
cuts power and closes water with the phone in another building, buffers the
recording, and hands it over when the link comes back.

**"Why not just use the phone's accelerometer?"**
You can, it is in the picker, and it is real. But a phone rests on furniture
with its own resonance, timestamps on a clock the OS adjusts, and cannot tell
you the structure's temperature — which is the entire basis of the correction.
The app says all of that where the choice is offered.

**"How accurate is it?"**
The period measurement is good to about 1%. Real damage moves it 10–30%. The
honest limit is that a period change tells you stiffness was lost, not *where* —
that is why the verdict is "needs inspection" rather than "your third floor
column has failed".

---

## If you have only 90 seconds

Skip sign-in, the map and the keys. Run: problem (20 s) → shake the board and
let the commentary talk (40 s) → the two-of-three refusal (15 s) → the period
measurement (15 s). The refusal and the temperature correction are the two
things nobody else will have.

## The one-button fallback

**Settings → Run the full demonstration** drives the whole thing itself for
3 minutes 30, including the node's real event sequence, and captions each beat a
word at a time. Use it if your hands are shaking or the room is hostile. You
talk over it.
