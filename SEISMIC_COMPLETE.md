# SEISMIC — Complete Hardware Reference & Firmware

> **Single-file reference for rebuilding the Seismic earthquake node from scratch.**
> Contains the full build instructions, wiring coordinates, test procedures,
> troubleshooting log, and the complete Arduino sketch.

| | |
|---|---|
| **Project** | Earthquake early-warning and structural assessment node |
| **Board** | Arduino MEGA 2560 |
| **Power** | USB from MacBook only — no adapter, no battery |
| **Link** | BLE serial bridge to iOS app |
| **Libraries** | None required |
| **Status** | All components documented below are tested and confirmed working |

---

## HOW TO USE THIS FILE

- **Building from scratch?** Start at Part 1, work through Part 5 in order, then run Part 10's tests.
- **Something broken?** Go straight to Part 12, Troubleshooting.
- **Just need the code?** Part 14 at the bottom.
- **Rebuilding after a break?** Part 2 tells you what was dropped and why, so you don't repeat dead ends.

---

## CONTENTS

1. [What This Device Does](#part-1--what-this-device-does)
2. [Final Component List](#part-2--final-component-list)
3. [Breadboard Fundamentals](#part-3--breadboard-fundamentals)
4. [Resistor Identification](#part-4--resistor-identification)
5. [Build Order](#part-5--build-order)
6. [Complete Pin Map](#part-6--complete-pin-map)
7. [Complete Column Map](#part-7--complete-column-map)
8. [Capacitor Placement](#part-8--capacitor-placement)
9. [Connector Reference](#part-9--connector-reference)
10. [Full Test Sequence](#part-10--full-test-sequence)
11. [Calibration Values To Record](#part-11--calibration-values-to-record)
12. [Troubleshooting](#part-12--troubleshooting)
13. [Demo Day Checklist](#part-13--demo-day-checklist)
14. [Complete Arduino Sketch](#part-14--complete-arduino-sketch)

---

# PART 1 — WHAT THIS DEVICE DOES

The node sits on a flat surface. It watches for shaking using three independent
sensors. When at least two of them agree, it declares an earthquake, counts down
a warning, physically cuts simulated building power and closes a simulated water
main, verifies its own actions actually happened, records ten seconds of the
shaking, then measures whether the structure's natural sway period changed —
which reveals structural damage.

**The science:** a structure sways at a natural period set by its stiffness.
Damage reduces stiffness while mass stays constant, so the period gets longer —
typically 10 to 30 percent for significant damage. Measuring that period before
and after an event is a real post-earthquake assessment technique.

**Division of labour:** the Arduino measures ground motion, decides, and acts.
The phone does the analysis, visualisation, 3D simulation, and networking.
The node protects the building offline; the phone makes it a network and a
diagnosis.

---

# PART 2 — FINAL COMPONENT LIST

## Components used (12 modules, all tested working)

| Component | Role | Pins |
|---|---|---|
| Arduino MEGA 2560 | The board | — |
| BLE module | Link to the phone | 18 TX1, 19 RX1 |
| GY-521 (MPU6050) | Accelerometer — primary shake channel | 20 SDA, 21 SCL, 3.3V AD0 |
| Tilt ball switch | Independent shake confirmation + permanent lean detection | 36 |
| Sound sensor | Independent shake confirmation | A3 |
| PIR sensor | Occupancy — is anyone in the building | 37 |
| Thermistor | Temperature compensation for the period measurement | A0 |
| Photoresistor | Self-verification — proves the power cut happened | A1 |
| PN2222 transistor | Solid-state power switch | 26 (via 1k) |
| Red LED | Represents building electricity | via transistor |
| Stepper + ULN2003 | Water main shutoff | 22, 23, 24, 25 |
| MAX7219 display | Countdown and status | 30, 31, 32 |
| RGB LED | Verdict placard — green/amber/red | 5, 6, 7 |
| Active buzzer | Alarm | 27 |
| Button | Arm/disarm | 38 |

## Components dropped, and why

| Component | Reason |
|---|---|
| **SG90 servo (gas valve)** | Did not respond. Silent with no power draw — likely faulty unit. The transistor power cut covers the "physical intervention" story on its own |
| **DS1307 RTC** | Never appeared on the I2C bus (only 0x69 showed, never 0x68). Likely needs a CR2032 coin cell. Dropped because the phone timestamps everything with network-synced time, which is more accurate anyway |
| **5V relay (SRD-05VDC-SL-C)** | Pins are on a 0.2 inch grid with an offset middle pin — will not seat in a breadboard. The PN2222 transistor does the same switching job with no moving parts |
| **Ultrasonic sensor** | Removed to save board space and wires |
| **Passive buzzer** | Removed; the active buzzer covers alarm duty |
| **74HC595 + LED bar** | No room left on the board |

**What to say if a judge asks about the relay:** "We used solid-state switching
rather than an electromechanical relay — no moving parts, no contact wear,
faster response." That is a genuine engineering advantage, not a cover story.

---

# PART 3 — BREADBOARD FUNDAMENTALS

Your board: **columns 1 to 63**, rows **A–E** (bottom half), a trench, rows
**F–J** (top half).

## The connection rule

Within one column:
- **A, B, C, D, E are all connected together**
- **F, G, H, I, J are all connected together**
- The trench separates them completely

So if you put a wire in A5 and another in C5, they are connected. If you put one
in A5 and one in F5, they are NOT.

## The power rails

The long strips along both edges, marked with red and blue lines, run the full
length of the board. Everything plugged into a red rail is connected. Same for
blue.

**Check for a rail break.** Many 830-point boards have a gap in the power rails
around column 30 — look for a break in the printed red/blue line. If yours has
one, bridge it with jumper wires on all four rails, or nothing past column 30
gets power.

## The module overhang rule — CRITICAL

**A module's body is wider than its pins.** When you seat a module's pins in row
E, the circuit board sits on top of rows F, G, and H in those columns. Those
holes are physically buried and unusable.

| Module goes in | Pins in row | Body covers | Wire from |
|---|---|---|---|
| Bottom half | **E** | F, G, H | rows **A–D** (4 free holes per column) |
| Top half | **F** | G, H, I | row **J** (1 free hole per column) |

**Consequence:** any column occupied by a bottom-half module is off-limits in
the top half, and vice versa. The column map in section 7 already accounts for
this.

Discrete parts — LEDs, resistors, capacitors, buzzers, switches, thermistors —
are low-profile and block nothing.

## Resistors in a breadboard

A resistor is a bridge between two rows. One leg goes in the row containing the
component, the other leg in a different empty row. Then a jumper wire goes from
that second row onward.

**Common mistake:** both resistor legs in the same column does nothing — it just
shorts across itself.

---

# PART 4 — RESISTOR IDENTIFICATION

| Value | Colour bands | Quantity needed | Used for |
|---|---|---|---|
| **220Ω** | red, red, brown, gold | 4 | Each LED colour and the building-power LED |
| **1kΩ** | brown, black, red, gold | 2 | BLE voltage divider, transistor base |
| **2kΩ** | red, black, red, gold | 1 | BLE voltage divider |
| **10kΩ** | brown, black, orange, gold | 3 | Photoresistor, thermistor dividers |

Read bands from the end where they are grouped closest together.

---

# PART 5 — BUILD ORDER

Build in this exact order. Test after each step. Do not proceed past a failure.

---

## STEP 1 — Power rails (4 wires)

| # | Wire from | To |
|---|---|---|
| 1 | Arduino **5V** | **BOTTOM + rail** |
| 2 | Arduino **GND** | **BOTTOM − rail** |
| 3 | **BOTTOM + rail** | **TOP + rail** |
| 4 | **BOTTOM − rail** | **TOP − rail** |

All four rails are now one supply. Use whichever rail is physically nearest to
each component.

**TEST:** LED long leg in TOP +, short leg through a 220Ω to TOP −. It lights.
Remove it.

---

## STEP 2 — GY-521 accelerometer (columns 1–10, bottom half)

Your module has **10 pins**. Order from pin 1:

**VCC, GND, SCL, SDA, XDA, XCL, AD0, INT, NCS, FSYNC**

Seat the pins in **row E, columns 1 through 10**. The body will cover F1–H10.

| Column | Pin | Note |
|---|---|---|
| E1 | VCC | |
| E2 | GND | |
| E3 | SCL | |
| E4 | SDA | |
| E5 | XDA | not used |
| E6 | XCL | not used |
| E7 | **AD0** | **critical** |
| E8 | INT | not used |
| E9 | NCS | leave empty — keeps it in I2C mode |
| E10 | FSYNC | leave empty |

### Wires (all from rows A–D)

| # | From | To |
|---|---|---|
| 1 | **D1** | BOTTOM + rail |
| 2 | **D2** | BOTTOM − rail |
| 3 | **D3** | Arduino **pin 21** (SCL) |
| 4 | **D4** | Arduino **pin 20** (SDA) |
| 5 | **D7** | Arduino **3.3V** |

### The AD0 wire

**This is the single most important wire in the build.** The MPU6050 defaults to
I2C address 0x68. Tying AD0 to 3.3V moves it to 0x69, which is what the code
expects. Without it, the accelerometer is invisible.

**TEST:**
1. Install "MPU6050 by Electronic Cats" from Manage Libraries
2. File → Examples → MPU6050 → MPU6050_raw → Upload
3. Serial Monitor at **38400**

**Pass:** Flat on the table, one axis reads roughly 16000 and the others near
zero. Rotate 90 degrees and the values swap between axes. Magnitude stays around
16400 in every orientation.

**Confirmed working reading from this build:**
```
flat:        x=-2984  y=328  z=16160  mag=16436
rotated 90:  x=-16696 y=244  z=-1736  mag=16788
```

---

## STEP 3 — BLE module with voltage divider (columns 22–27, divider 30–32)

### Why the divider

The MEGA outputs **5V** on its transmit pin. Most BLE modules run **3.3V logic**
and their RX pin can be damaged by 5V. Two resistors drop it to about 3.3V.

**Only the module's RX needs protecting.** Its TX goes direct — 3.3V is enough
for the MEGA to read as HIGH.

### Pin naming

On the MEGA, **pin 18 is TX1** and **pin 19 is RX1**. Transmit always connects
to receive:
- Module TXD → Arduino pin 19 (RX1)
- Arduino pin 18 (TX1) → divider → Module RXD

### Seat the module — row E, columns 22–27

| Column | Pin |
|---|---|
| E22 | STATE |
| E23 | RXD |
| E24 | TXD |
| E25 | GND |
| E26 | VCC |
| E27 | EN |

Check your module's silkscreen and shift if the order differs.

### Build the divider — columns 30–32

| # | Part | From | To |
|---|---|---|---|
| 1 | Wire | Arduino **pin 18 (TX1)** | **A30** |
| 2 | **1kΩ resistor** | **B30** | **B32** |
| 3 | **2kΩ resistor** | **C32** | **TOP − rail** |
| 4 | Wire | **D32** | **D23** (module RXD column) |

**Column 32 is the divider midpoint** — that is where the reduced voltage comes
out.

### Remaining BLE wires

| # | From | To |
|---|---|---|
| 5 | **D24** (TXD) | Arduino **pin 19 (RX1)** — direct, no resistors |
| 6 | **D25** (GND) | BOTTOM − rail |
| 7 | **D26** (VCC) | BOTTOM + rail |

### Set the baud rate

The factory default is 9600, too slow for sending recordings.

1. Upload a serial passthrough sketch
2. Serial Monitor at **9600**, line ending **"Both NL & CR"**
3. Send `AT` — expect `OK`
4. Send `AT+BAUD8` for 115200

If no reply, try "No line ending". HM-10 modules use `AT+BAUD4` for 115200.

**If you skip this, set `Serial1.begin(9600)` in the sketch instead.**

**TEST:** Print a counter to Serial1 every second. On your phone, install
nRF Connect, scan, connect, subscribe to the characteristic. Numbers should
climb.

**If nothing appears:** swap the wires on pins 18 and 19. This fixes it 90
percent of the time.

---

## STEP 4 — RGB verdict LED (columns 35–42, bottom half)

Four legs. **The longest is common.** Order left to right: Red, Common, Green,
Blue.

### Place the LED

| Column | Leg |
|---|---|
| A35 | Red |
| A36 | Common (longest) |
| A37 | Green |
| A38 | Blue |

### Three 220Ω resistors

| Resistor | From | To |
|---|---|---|
| #1 | **B35** | **B40** |
| #2 | **B37** | **B41** |
| #3 | **B38** | **B42** |

### Wires

| # | From | To |
|---|---|---|
| 1 | **C40** | Arduino **pin 5** |
| 2 | **C41** | Arduino **pin 6** |
| 3 | **C42** | Arduino **pin 7** |
| 4 | **C36** | BOTTOM − rail |

### CRITICAL: use the DIGITAL header

**Pins 5, 6, 7 are in the DIGITAL header** — the long row numbered 0 to 53 along
one edge, marked `DIGITAL (PWM~)`.

**They are NOT A5, A6, A7** — those are in the separate `ANALOG IN` header on
the opposite side of the board. This exact mistake cost time during this build.

**TEST:** pin 5 HIGH = red, pin 6 = green, pin 7 = blue, 5 and 6 together =
amber.

**If lit when pins are LOW:** common-anode LED. Set `RGB_COMMON_ANODE 1` in the
sketch and move the C36 wire to the BOTTOM + rail.

---

## STEP 5 — Active buzzer (columns 45, 47)

Legs are 0.2 inch apart, so two columns apart.

| Column | Leg | Wire from | To |
|---|---|---|---|
| A45 | + (longer, or marked) | **B45** | Arduino **pin 27** |
| A47 | − | **B47** | BOTTOM − rail |

No resistor — active buzzers have a built-in driver.

**TEST:** `digitalWrite(27, HIGH)` produces a tone.

---

## STEP 6 — Button (columns 50, 52, straddling the trench)

A tactile button has four legs, internally paired. Push it down across the
centre gap so the legs land at **E50, E52, F50, F52**.

| # | From | To |
|---|---|---|
| 1 | **A50** | Arduino **pin 38** |
| 2 | **A52** | BOTTOM − rail |

No resistor — the code uses `INPUT_PULLUP`, which enables a resistor inside the
Arduino. The pin reads HIGH normally and LOW when pressed.

---

## STEP 7 — MAX7219 display (columns 55–59, bottom half)

Seat the pins in **row E, columns 55 through 59**. Body covers F55–H59.

| Column | Pin | Wire from | To |
|---|---|---|---|
| E55 | VCC | **D55** | BOTTOM + rail |
| E56 | GND | **D56** | BOTTOM − rail |
| E57 | DIN | **D57** | Arduino **pin 30** |
| E58 | CS | **D58** | Arduino **pin 31** |
| E59 | CLK | **D59** | Arduino **pin 32** |

### Brightness warning

**Set intensity to 2 in code.** At full brightness this module alone can pull
over 300mA and starve everything else on a USB-powered board.

### Rotation

If the digits appear sideways, flip `DISPLAY_ROTATE` between 1 and 0 in the
sketch. This build needed `DISPLAY_ROTATE 1`.

---

## STEP 8 — Thermistor (columns 60, 62, bottom half)

Two legs, no polarity.

| # | Part | From | To |
|---|---|---|---|
| 1 | Wire | **B60** | BOTTOM + rail |
| 2 | Thermistor | **A60** | **A62** |
| 3 | **10kΩ resistor** | **B62** | BOTTOM − rail |
| 4 | Wire | **C62** | Arduino **A0** |

This is a voltage divider. As temperature changes, the thermistor's resistance
changes, which changes the voltage on A0.

**TEST:** Read A0 and convert. Should show room temperature. Pinch the
thermistor between your fingers and the reading should climb within a few
seconds.

**Confirmed working reading from this build:** 24.9 degrees C at room
temperature.

---

## STEP 9 — Tilt ball switch (columns 20, 21, top half)

A small metal cylinder containing a ball. When tilted or shaken, the ball
bridges two internal contacts.

Bend the legs to reach **F20** and **F21**.

| # | From | To |
|---|---|---|
| 1 | **G20** | Arduino **pin 36** |
| 2 | **G21** | TOP − rail |

`INPUT_PULLUP`, no resistor.

### Orientation matters

Tilt switches are orientation-dependent. During this build it initially read
permanently ACTIVE. **Reorienting it fixed the problem.**

**TEST:** Read the pin while the board is still — should read one state. Tip and
shake — should change state. If it never changes, try standing it vertically, or
at different angles, until you find an orientation that rests in one state and
activates when shaken.

**If no orientation works:** set `TILT_INVERT 1` in the sketch.

---

## STEP 10 — Transistor power cut (columns 32–35, top half)

This is the most impressive part of the board: a solid-state switch that the
system can then verify actually operated.

### The transistor

Your **PN2222** is a small black half-cylinder with three legs. Hold it with the
**flat face toward you, legs pointing down**. Standard order left to right:

**Emitter — Base — Collector**

Seat it in row **F**:

| Column | Leg |
|---|---|
| F33 | Emitter |
| F34 | Base |
| F35 | Collector |

### Wiring

| # | Part | From | To | Purpose |
|---|---|---|---|---|
| 1 | Wire | Arduino **pin 26** | **H32** | Signal in |
| 2 | **1kΩ resistor** | **H32** | **H34** | Limits base current, protects the pin |
| 3 | Wire | **G33** | TOP − rail | Emitter to ground |

The signal path: pin 26 → column 32 → through the 1kΩ → column 34 (base).

### How it behaves

Pin 26 HIGH means the transistor conducts and the LED is lit — the building has
power. Pin 26 LOW cuts it.

**This is inverse of what you might expect.** The code holds pin 26 HIGH during
normal operation.

**If the transistor never conducts:** swap emitter and collector. That is the
most common cause.

---

## STEP 11 — Building power LED (columns 37–39, top half)

| # | Part | From | To |
|---|---|---|---|
| 1 | Wire | TOP + rail | **F37** |
| 2 | **220Ω resistor** | **G37** | **G38** |
| 3 | Red LED long leg | **F38** | — |
| 4 | Red LED short leg | **F39** | — |
| 5 | Wire | **G39** | **G35** (transistor collector) |

The current path: 5V → resistor → LED → collector → through the transistor →
emitter → ground. When the transistor switches off, the path breaks and the LED
goes dark.

---

## STEP 12 — Photoresistor verification sensor (columns 41–43, top half)

**This is the feature that separates this project from every other hackathon
build.** Everyone's project can command an action. This one proves the action
physically happened.

Two legs, no polarity. Bend to reach **F41** and **F43**.

| # | Part | From | To |
|---|---|---|---|
| 1 | Wire | **G41** | TOP + rail |
| 2 | **10kΩ resistor** | **G43** | TOP − rail |
| 3 | Wire | **H43** | Arduino **A1** |

### Positioning matters more than the wiring

Point the photoresistor's face directly at the red LED, about **1cm away**. Roll
a small paper tube and tape it around both so room light does not interfere.

**TEST:** Read A1 with the LED on, then with it off. The difference should
exceed 150. If it does not, move the photoresistor closer and improve the light
shielding.

**Record both values.** Their midpoint is the confirmation threshold in the
sketch.

---

## STEP 13 — Stepper water main (columns 45–48, top half)

Seat the ULN2003's 4-pin IN header in **row F, columns 45 through 48**. Body
covers G45–I48. Wire from row **J**.

| Column | Pin | Wire from | To |
|---|---|---|---|
| F45 | IN1 | **J45** | Arduino **pin 22** |
| F46 | IN2 | **J46** | Arduino **pin 23** |
| F47 | IN3 | **J47** | Arduino **pin 24** |
| F48 | IN4 | **J48** | Arduino **pin 25** |

Power connector on the driver board (separate header or screw terminal). Use
female-to-male Dupont wires:

| From | To |
|---|---|
| ULN2003 **+** | TOP + rail |
| ULN2003 **−** | TOP − rail |

The stepper motor's white plug goes straight into the driver board's white
socket. It is keyed — no adapting needed.

**Tape a paper flag to the shaft reading WATER** so the rotation is visible.

### The driver board has four LEDs

They light in sequence as the motor steps. This is your best diagnostic:

| LEDs | Meaning |
|---|---|
| Chasing in sequence, shaft turns | Working |
| Chasing, shaft still | Motor power or plug not connected |
| Nothing lights | Signal wires or ground not connected |
| One stuck on | Coils not being de-energised |

### USB power rules — critical

- **Set all four pins LOW immediately after each move.** The ULN2003 holds
  torque by keeping coils energised, which you do not need for a valve gesture
  and which eats your entire current headroom
- **Use around 1024 steps** — a half turn, clearly visible
- **Step delay around 3000 microseconds** — slower means lower peak current
- **800ms of clear air** either side of a move

### Staged testing

| Attempt | Step delay | Step count | Watch for |
|---|---|---|---|
| 1 | 8000 | 128 | Board reset? |
| 2 | 5000 | 256 | Board reset? |
| 3 | 3000 | 1024 | Board reset? |

**Stop at the last setting that does not reset the board.** This build ran fine
at 3000 / 1024.

---

## STEP 14 — PIR occupancy sensor (columns 50–52, top half)

Seat in row F. Body covers G50–I52. Wire from row **J**.

| Column | Pin | Wire from | To |
|---|---|---|---|
| F50 | VCC | **J50** | TOP + rail |
| F51 | OUT | **J51** | Arduino **pin 37** |
| F52 | GND | **J52** | TOP − rail |

PIR modules take 30 to 60 seconds to settle after power-on. Ignore readings
during that period.

---

## STEP 15 — Sound sensor (columns 60–63, top half)

Seat in row F. Body covers G60–I63. Wire from row **J**.

| Column | Pin | Wire from | To |
|---|---|---|---|
| F60 | AO | **J60** | Arduino **A3** |
| F61 | GND | **J61** | TOP − rail |
| F62 | VCC | **J62** | TOP + rail |
| F63 | DO | — | unused |

**Use the analogue output (AO), not the digital one.** You want a continuous
level, not a threshold.

Most sound sensor modules have a small potentiometer for sensitivity. If the
readings barely move when you clap, adjust it.

---

# PART 6 — COMPLETE PIN MAP

| Arduino pin | Header | Connects to | Board location |
|---|---|---|---|
| **3.3V** | Power | GY-521 AD0 | D7 |
| **5V** | Power | BOTTOM + rail | — |
| **GND** | Power | BOTTOM − rail | — |
| **5** | Digital | RGB red | C40 |
| **6** | Digital | RGB green | C41 |
| **7** | Digital | RGB blue | C42 |
| **18 (TX1)** | Digital | BLE RXD via divider | A30 |
| **19 (RX1)** | Digital | BLE TXD | D24 |
| **20 (SDA)** | Digital | GY-521 SDA | D4 |
| **21 (SCL)** | Digital | GY-521 SCL | D3 |
| **22** | Digital | Stepper IN1 | J45 |
| **23** | Digital | Stepper IN2 | J46 |
| **24** | Digital | Stepper IN3 | J47 |
| **25** | Digital | Stepper IN4 | J48 |
| **26** | Digital | Transistor base via 1kΩ | H32 |
| **27** | Digital | Active buzzer | B45 |
| **30** | Digital | MAX7219 DIN | D57 |
| **31** | Digital | MAX7219 CS | D58 |
| **32** | Digital | MAX7219 CLK | D59 |
| **36** | Digital | Tilt switch | G20 |
| **37** | Digital | PIR OUT | J51 |
| **38** | Digital | Button | A50 |
| **A0** | Analog | Thermistor | C62 |
| **A1** | Analog | Photoresistor | H43 |
| **A3** | Analog | Sound sensor | J60 |

---

# PART 7 — COMPLETE COLUMN MAP

## Bottom half (A–E) — module pins in row E, wire from rows A–D

| Columns | Component | Blocks top half? |
|---|---|---|
| 1–10 | GY-521 accelerometer | **Yes** |
| 22–27 | BLE module | **Yes** |
| 30–32 | BLE voltage divider (discrete) | No |
| 35–42 | RGB LED and its three resistors | No |
| 45, 47 | Active buzzer | No |
| 50, 52 | Button (straddles the trench) | **Yes** |
| 55–59 | MAX7219 display | **Yes** |
| 60, 62 | Thermistor | No |

## Top half (F–J) — module pins in row F, wire from row J

| Columns | Component |
|---|---|
| 20, 21 | Tilt ball switch |
| 32–35 | PN2222 transistor and base resistor |
| 37–39 | Building power LED |
| 41–43 | Photoresistor (verification) |
| 45–48 | ULN2003 stepper driver |
| 50–52 | PIR sensor |
| 60–63 | Sound sensor |

## Free columns

Bottom half: 11–21, 28–29, 33–34, 43–44, 46, 48–49, 51, 53–54, 61, 63
Top half: 1–19, 22–31, 36, 40, 44, 49, 53–59

---

# PART 8 — CAPACITOR PLACEMENT

Capacitors act as local reservoirs. When a motor starts, it demands current
faster than USB can supply — the capacitor releases stored charge to cover that
instant, preventing a brownout.

**Put each one as close as possible to what draws the current.**

Electrolytics have polarity. **The striped side is negative.**

| Capacitor | Long leg (+) | Striped leg (−) | Protects |
|---|---|---|---|
| **100µF #1** | BOTTOM + rail, near column 34 | BOTTOM − rail, same area | Transistor and power LED |
| **100µF #2** | TOP + rail, near column 46 | TOP − rail, same area | Stepper driver |
| **10µF #1** | BOTTOM + rail, near column 57 | BOTTOM − rail, same area | MAX7219 display |
| **10µF #2** | BOTTOM + rail, near column 5 | BOTTOM − rail, same area | General logic supply |

Push them straight into the rail holes — no breadboard rows needed.

**Backwards electrolytics can pop.** Check every stripe faces a blue rail before
powering on.

---

# PART 9 — CONNECTOR REFERENCE

| Component | Connector type | How to attach |
|---|---|---|
| GY-521, BLE, MAX7219, ULN2003, PIR, sound sensor | Male header pins | Push straight into the breadboard |
| **PN2222 transistor** | 3 bare legs | Flat face toward you: emitter, base, collector |
| **ULN2003 power header** | Male pins | Female-to-male Dupont wires |
| **Stepper to ULN2003** | Keyed white plug | Plugs in directly, no adapting |
| LEDs, resistors, capacitors, buzzer, tilt switch, thermistor, photoresistor, button | Bare legs | Straight into the breadboard |

## Wire budget

You have 65 breadboard jumpers and 20 female-to-male Dupont wires.

Dupont wires needed: 2 for the ULN2003 power header. Everything else uses
standard jumpers, because every module with male headers plugs directly into the
breadboard.

---

# PART 10 — FULL TEST SEQUENCE

Use the bench test sketch. Serial Monitor at **115200**, line ending
**"Newline"**. Do not proceed past a failure.

| # | Command | What to do | Passes when |
|---|---|---|---|
| 1 | (press reset) | Nothing | `accelerometer : FOUND` |
| 2 | `SCAN` | Nothing | `found 0x69` |
| 3 | `A` | Board flat, then rotate 90 degrees and repeat | Magnitude around 16400 both times; axes swap |
| 4 | `M` | Shake the board for 5 seconds | Peak deviation in the thousands |
| 5 | `T` | Then pinch the thermistor and repeat | Room temperature, rises when pinched |
| 6 | `L` | Then cover it and repeat | Number changes substantially |
| 7 | `MN` | Clap and talk for 5 seconds | Swing of at least 50 |
| 8 | `MT` | Tip and shake the switch | Several state changes |
| 9 | `MP` | Wave your hand | Detections logged |
| 10 | `MB` | Press the button several times | Count matches |
| 11 | `B` | Listen | Audible beep |
| 12 | `RGBT` | Watch the LED | Red, green, blue, white in sequence |
| 13 | `DT` | Watch the display | All pixels on, then counts 0 to 9 upright |
| 14 | `PW1` then `PW0` | Watch the red LED | LED goes dark, delta over 150 |
| 15 | `W1` then `W0` | Watch the shaft | Turns visibly, no board reset |
| 16 | `S` | Nothing | Every reading sensible |

**Test 15 is the one to watch.** If the header banner reprints during a stepper
move, the board reset from a current spike. Increase the step delay and reduce
the step count until it stops.

---

# PART 11 — CALIBRATION VALUES TO RECORD

Write these down. They go into the production sketch.

| Value | How to get it | This build's result |
|---|---|---|
| **Gravity magnitude** | `A` with the board flat and still | 16369 |
| **Photoresistor, LED on** | `L` with power restored | record yours |
| **Photoresistor, LED off** | `L` after `PW1` | record yours |
| **PHOTO_THRESHOLD** | Midpoint of the two above | record yours |
| **Sound baseline** | `N` in a quiet room | around 48 |
| **Room temperature** | `T` | 24.9 C |
| **Nuisance ratio: typing** | `S` while typing | record yours |
| **Nuisance ratio: walking past** | `S` while someone walks past | record yours |
| **Nuisance ratio: bag dropped** | `S` while dropping a bag | record yours |
| **Real trigger ratio: table bang** | `S` while banging | record yours |
| **TRIGGER_RATIO** | Comfortably between the worst nuisance and a real bang | record yours |
| **Stepper delay that survives** | Staged test in step 13 | 3000 |
| **Stepper count that survives** | Staged test in step 13 | 1024 |

**Tune the trigger threshold in a noisy room with people moving around, not on a
silent bench.** A false trigger during your pitch is worse than no trigger at
all.

---

# PART 12 — TROUBLESHOOTING

Every problem encountered during this build, and its fix.

## Serial Monitor shows garbled characters

**Cause:** baud rate mismatch.
**Fix:** set the Serial Monitor dropdown to 115200. If still garbled, the sketch
may be using a different rate.

## Serial Monitor says "connect to board" though it is plugged in

**Causes, in order of likelihood:**
1. **Charge-only USB cable** — many cables carry power but no data. Try another
2. **Missing CH340 driver** — if your MEGA is a clone with a small square chip
   near the USB port, macOS needs the WCH CH340 driver installed, followed by a
   restart
3. **Wrong port selected** — Tools → Port, pick the entry that appears when you
   plug the board in
4. **Wrong board selected** — Tools → Board → Arduino Mega or Mega 2560, and
   Tools → Processor → ATmega2560

**Diagnostic:** in Terminal run `ls /dev/cu.*` with the board unplugged, then
plugged in. A new entry appearing means the Mac sees the board.

## Only 0x69 appears in the I2C scan, no 0x68

That is expected in this build. The RTC was dropped. 0x69 is the accelerometer,
which is the one that matters.

## `mpu:0` on boot, LED flashes red

**Cause:** the AD0 wire is not connected.
**Fix:** check D7 goes to Arduino 3.3V. Without it the accelerometer sits at
0x68 and the code cannot find it.

## Accelerometer reads zeros or does not change

**Fix:** check SDA is on pin 20 and SCL on pin 21, not swapped. Check VCC and
GND are seated.

## RGB LED does not light at all

**Most likely cause encountered in this build:** the wires were plugged into
**A5, A6, A7** in the analog header instead of **digital pins 5, 6, 7**.

The digital header is the long row numbered 0 to 53 marked `DIGITAL (PWM~)`.
The analog header is a separate shorter row marked `ANALOG IN`. They are on
opposite sides of the board and are completely different pins.

**Other causes:**
- Common leg not connected to the ground rail
- Resistors with both legs in the same column (does nothing)
- Common-anode LED — set `RGB_COMMON_ANODE 1` and move the common leg to the +
  rail

## Display digits appear rotated 90 degrees

**Fix:** flip `DISPLAY_ROTATE` between 1 and 0 in the sketch. This build needed
`DISPLAY_ROTATE 1`.

## Tilt switch reads permanently active

**Cause:** orientation. Tilt ball switches are orientation-dependent.
**Fix:** try standing it vertically, then at various angles, until it rests in
one state and activates when shaken. Reorienting fixed it in this build.

**Diagnostic:** pull one leg out of the breadboard entirely. The pin should read
HIGH. If it still reads LOW, something is shorting at that column.

**Last resort:** set `TILT_INVERT 1` in the sketch.

## Board resets when a motor moves

**This is a brownout, not a code bug.** The board reset looks identical to a
false earthquake trigger in your data, so recognise it early.

**Symptom:** the boot message or header banner reprints in the Serial Monitor.

**Fixes, in order:**
1. Increase the stepper delay: `SD:8000`
2. Reduce the step count: `SC:128`
3. Check the 100µF capacitor near the stepper, stripe in the blue rail
4. Confirm nothing else is moving at the same time
5. Confirm the actuator stagger is at least 800ms

## Stepper LEDs chase but the shaft does not turn

**Fix:** the white plug is not fully seated in the driver board's socket, or the
driver's + and − are not connected to the rails. Some driver boards also have a
small jumper cap near the power connector which must be present.

## Stepper only turns a small amount

**Cause:** the step count is low. 256 steps is roughly one eighth of a turn.
**Fix:** increase to 1024 for a visible half turn, provided the board does not
reset.

## Servo silent, no movement, no sound

A servo with power but no valid signal **hums**. A servo with no power is
**silent**. Silence points at power, not signal.

**Diagnostics:**
1. Bypass the breadboard — connect the servo directly to Arduino 5V, GND, and
   pin 9
2. Try turning the horn by hand: a powered servo resists, an unpowered one spins
   freely
3. Check the plug connection — jumper ends pushed into a female plug work loose
   constantly, and must be taped

In this build the servo remained silent under every test and was assumed faulty.

## Photoresistor delta too small for verification

**Fix:** move the photoresistor closer to the LED, ideally about 1cm, and wrap a
paper tube around both to block room light. You need a difference of at least
150 for reliable verification.

## Nothing works after adding a new component

**Check the module overhang rule.** If you seated a module in row E, it covers
rows F, G, H in those columns. Anything you plugged into those buried holes is
not connected.

---

# PART 13 — DEMO DAY CHECKLIST

- [ ] Every capacitor stripe faces a blue rail
- [ ] The AD0 wire (D7 to 3.3V) is firmly seated
- [ ] BLE baud rate in the sketch matches the module's actual setting
- [ ] `PHOTO_THRESHOLD` set from your own measured values
- [ ] `TRIGGER_RATIO` tuned in a noisy room, not a silent one
- [ ] Stepper delay and count set to values that never reset the board
- [ ] Paper flags attached: WATER on the stepper shaft, MAINS on the power LED
- [ ] RGB verdict LED positioned prominently and unobstructed
- [ ] Breadboard taped to a piece of card so nothing shifts when the table is
      banged
- [ ] Full `DRILL` sequence rehearsed ten times end to end
- [ ] Node left DISARMED until the moment of the demo
- [ ] Phone paired and the app confirmed receiving telemetry
- [ ] USB cable confirmed as a data cable, and a spare packed
- [ ] Laptop charged, or a power bank packed

## Wire colour discipline

Red for 5V, black for ground, and one distinct colour per function. Keep runs
short. Judges read the board before they read the screen.

## The demo sequence

1. Board sits on the judging table, RGB green, monitoring
2. Press **Test Earthquake** in the app — or bang the table if armed
3. Buzzer sounds, display counts 5-4-3-2-1, phone screen takes over
4. Power LED goes dark with a confirmation chirp
5. App reports **power cut: CONFIRMED**, not merely commanded
6. Stepper turns, water main closes
7. Ten seconds of shaking recorded and streamed to the phone
8. Structural period re-measured, verdict computed
9. RGB LED settles on green, amber, or red — the answer to the only question
   that matters after an earthquake: can I go back inside?

---

---

# PART 14 — COMPLETE ARDUINO SKETCH

## Before uploading — three checks

1. **BLE baud rate.** If you never changed your module from its factory setting,
   change `Serial1.begin(115200)` to `Serial1.begin(9600)`.
2. **PHOTO_THRESHOLD.** Set this from your own measured photoresistor values
   (see Part 11). The midpoint between LED-on and LED-off.
3. **Behaviour flags.** `RGB_COMMON_ANODE`, `TILT_INVERT`, and `DISPLAY_ROTATE`
   near the top — flip any that behave backwards on your build.

## App commands this sketch accepts

Sent over BLE as plain text with a newline, or typed into the USB Serial Monitor
at 115200 for bench work.

| Command | Effect |
|---|---|
| `DRILL` | **Runs the complete event sequence** — this is the app's Test Earthquake button |
| `ARM` | Begin monitoring for real shaking |
| `DISARM` | Ignore shaking — use while presenting |
| `CAL` | Recalibrate gravity, sound floor, and baseline period |
| `RESET` | Restore all actuators, return to monitoring |
| `SEND` | Resend the last recording |
| `STATUS` | Request one telemetry line immediately |
| `PWR:1` / `PWR:0` | Cut and restore building power |
| `WTR:1` / `WTR:0` | Close and open the water main |
| `THR:45` | Trigger ratio × 10 |
| `STEP:1024` | Stepper steps per move |
| `SPD:3000` | Stepper delay in microseconds |
| `PHO:600` | Photoresistor confirmation threshold |
| `NOSTEP` / `YESTEP` | Disable or enable the stepper |
| `BEEP` | Test the buzzer |

## Messages this sketch sends

| Type | Meaning |
|---|---|
| `boot` | Node restarted; `mpu:0` means the accelerometer is missing |
| `tel` | Telemetry, once per second — all channels plus vote states |
| `acc` | Live accelerometer sample at ~10 Hz for the seismograph |
| `trig` | Event declared, with the vote breakdown that caused it |
| `count` | Countdown seconds remaining |
| `phase` | Phase change: warning, acting, recording, assessing, verdict |
| `act` | Actuator state: 0 idle, 1 commanded, 2 confirmed, 3 failed |
| `verify` | Evidence behind a confirmation — before/after light readings |
| `recbegin` / `rec` / `recend` | Chunked event recording with checksums |
| `assess` | Structural assessment and final verdict |
| `cal` | Calibration results |
| `note` / `err` / `ack` | Informational messages |

---

## The sketch

```cpp
/* ============================================================================
   SEISMIC — Earthquake early-warning and structural assessment node
   Arduino MEGA 2560  |  USB powered  |  BLE link to iOS app
   ----------------------------------------------------------------------------
   HARDWARE
     GY-521 accelerometer   I2C 0x69 (AD0 to 3.3V)  pins 20 SDA / 21 SCL
     BLE module             Serial1                 pin 18 TX1 / 19 RX1
     RGB LED (verdict)      pins 5 R, 6 G, 7 B      DIGITAL header
     Stepper (WATER)        pins 22 23 24 25  via ULN2003
     Power cut transistor   pin 26   (HIGH = building has power)
     Active buzzer          pin 27
     MAX7219 display        pin 30 DIN / 31 CS / 32 CLK
     Tilt ball switch       pin 36   (INPUT_PULLUP)
     PIR occupancy          pin 37
     Button arm/disarm      pin 38   (INPUT_PULLUP)
     Thermistor             A0
     Photoresistor          A1   (watches the power LED = verification)
     Sound sensor           A3

   NO EXTERNAL LIBRARIES REQUIRED.

   The app drives everything remotely. DRILL runs the complete event sequence
   so you never need to touch the board during a demonstration.
   ============================================================================ */

#include <Wire.h>

/* ============================ PINS ====================================== */
#define PIN_RGB_R        5
#define PIN_RGB_G        6
#define PIN_RGB_B        7
#define PIN_STEP_IN1    22
#define PIN_STEP_IN2    23
#define PIN_STEP_IN3    24
#define PIN_STEP_IN4    25
#define PIN_POWERCUT    26
#define PIN_BUZZER      27
#define PIN_MAX_DIN     30
#define PIN_MAX_CS      31
#define PIN_MAX_CLK     32
#define PIN_TILT        36
#define PIN_PIR         37
#define PIN_BUTTON      38
#define PIN_THERM       A0
#define PIN_PHOTO       A1
#define PIN_SOUND       A3

/* Flip these if your parts behave the other way round */
#define RGB_COMMON_ANODE 0
#define TILT_INVERT      0
#define DISPLAY_ROTATE   1

#define MPU_ADDR 0x69

/* ============================ TUNING ==================================== */
const uint16_t SAMPLE_HZ        = 50;
const uint32_t SAMPLE_PERIOD_US = 1000000UL / SAMPLE_HZ;

const float    STA_ALPHA        = 0.20f;    /* short-term smoothing */
const float    LTA_ALPHA        = 0.002f;   /* long-term smoothing  */
const float    LTA_FLOOR        = 60.0f;
float          TRIGGER_RATIO    = 4.0f;     /* tune with THR: */

const uint8_t  VOTES_REQUIRED   = 2;        /* of accel / tilt / sound */
const uint16_t VOTE_WINDOW_MS   = 600;
uint16_t       SOUND_DELTA      = 60;

const uint8_t  COUNTDOWN_START  = 5;
const uint16_t ACTUATOR_GAP_MS  = 800;      /* USB power: one motor at a time */

uint16_t       STEP_COUNT       = 1024;
uint16_t       STEP_DELAY_US    = 3000;
uint16_t       PHOTO_THRESHOLD  = 600;      /* set from your own readings */
bool           stepperEnabled   = true;

#define REC_LEN 500                          /* 10 s at 50 Hz */
int16_t  recBuf[REC_LEN];
uint16_t recCount = 0;

/* ============================ STATE ===================================== */
enum NodeState {
  ST_BOOT = 0, ST_CALIBRATING, ST_MONITOR, ST_DISARMED,
  ST_TRIGGERED, ST_ACTING, ST_RECORDING, ST_ASSESSING, ST_VERDICT
};
NodeState state = ST_BOOT;

float    sta = 0, lta = 100, ratio = 1.0f;
float    gravityMag = 16384.0f;
uint16_t soundBaseline = 0;
int16_t  ax, ay, az;

uint32_t lastSampleUs = 0, lastTelemetryMs = 0, lastButtonMs = 0;
uint8_t  streamDivider = 0;

bool     voteAccel = false, voteTilt = false, voteSound = false;
uint32_t voteAccelMs = 0, voteTiltMs = 0, voteSoundMs = 0;

float    peakAccelG = 0;
float    periodBaseline = 0, periodAfter = 0, periodChangePct = 0;
bool     powerCutConfirmed = false, tiltPermanent = false;
char     verdict = 'G';
uint8_t  stPower = 0, stWater = 0;

char txbuf[190];

/* ============================ MPU6050 =================================== */
void mpuWrite(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg); Wire.write(val);
  Wire.endTransmission();
}

bool mpuInit() {
  mpuWrite(0x6B, 0x00); delay(50);   /* wake */
  mpuWrite(0x1A, 0x00);              /* DLPF off, full bandwidth */
  mpuWrite(0x1C, 0x00);              /* +/- 2g */
  Wire.beginTransmission(MPU_ADDR);
  return (Wire.endTransmission() == 0);
}

void mpuRead() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);
  Wire.endTransmission(false);
  Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)6, (uint8_t)true);
  if (Wire.available() >= 6) {
    ax = (Wire.read() << 8) | Wire.read();
    ay = (Wire.read() << 8) | Wire.read();
    az = (Wire.read() << 8) | Wire.read();
  }
}

float accelMag() {
  float fx = ax, fy = ay, fz = az;
  return sqrt(fx*fx + fy*fy + fz*fz);
}

/* ============================ MAX7219 =================================== */
void maxSend(uint8_t reg, uint8_t data) {
  digitalWrite(PIN_MAX_CS, LOW);
  shiftOut(PIN_MAX_DIN, PIN_MAX_CLK, MSBFIRST, reg);
  shiftOut(PIN_MAX_DIN, PIN_MAX_CLK, MSBFIRST, data);
  digitalWrite(PIN_MAX_CS, HIGH);
}

void maxInit() {
  pinMode(PIN_MAX_DIN, OUTPUT);
  pinMode(PIN_MAX_CS,  OUTPUT);
  pinMode(PIN_MAX_CLK, OUTPUT);
  maxSend(0x0F, 0x00);   /* display test off */
  maxSend(0x09, 0x00);   /* no decode */
  maxSend(0x0B, 0x07);   /* scan all rows */
  maxSend(0x0A, 0x02);   /* brightness LOW - USB current budget */
  maxSend(0x0C, 0x01);   /* wake */
  for (uint8_t i = 1; i <= 8; i++) maxSend(i, 0x00);
}

const uint8_t PROGMEM DIGITS[10][8] = {
  {0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},
  {0x18,0x38,0x18,0x18,0x18,0x18,0x3C,0x00},
  {0x3C,0x66,0x06,0x0C,0x18,0x30,0x7E,0x00},
  {0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00},
  {0x0C,0x1C,0x3C,0x6C,0x7E,0x0C,0x0C,0x00},
  {0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00},
  {0x1C,0x30,0x60,0x7C,0x66,0x66,0x3C,0x00},
  {0x7E,0x06,0x0C,0x18,0x30,0x30,0x30,0x00},
  {0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00},
  {0x3C,0x66,0x66,0x3E,0x06,0x0C,0x38,0x00}
};
const uint8_t PROGMEM GLYPH_OK[8]   = {0x00,0x42,0x42,0x42,0x42,0x24,0x18,0x00};
const uint8_t PROGMEM GLYPH_BANG[8] = {0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00};

void dispBlank() { for (uint8_t r = 1; r <= 8; r++) maxSend(r, 0x00); }
void dispAll()   { for (uint8_t r = 1; r <= 8; r++) maxSend(r, 0xFF); }

void dispPattern(const uint8_t *src) {
#if DISPLAY_ROTATE
  uint8_t out[8] = {0,0,0,0,0,0,0,0};
  for (uint8_t r = 0; r < 8; r++) {
    uint8_t row = pgm_read_byte(&src[r]);
    for (uint8_t c = 0; c < 8; c++)
      if (row & (1 << (7 - c))) out[c] |= (1 << r);
  }
  for (uint8_t r = 0; r < 8; r++) maxSend(r + 1, out[r]);
#else
  for (uint8_t r = 0; r < 8; r++) maxSend(r + 1, pgm_read_byte(&src[r]));
#endif
}

void dispDigit(uint8_t d) { if (d > 9) { dispBlank(); return; } dispPattern(DIGITS[d]); }
void dispOK()    { dispPattern(GLYPH_OK); }
void dispAlert() { dispPattern(GLYPH_BANG); }

/* ============================ RGB ======================================= */
void rgb(uint8_t r, uint8_t g, uint8_t b) {
#if RGB_COMMON_ANODE
  analogWrite(PIN_RGB_R, 255-r); analogWrite(PIN_RGB_G, 255-g); analogWrite(PIN_RGB_B, 255-b);
#else
  analogWrite(PIN_RGB_R, r); analogWrite(PIN_RGB_G, g); analogWrite(PIN_RGB_B, b);
#endif
}
void rgbGreen() { rgb(0,140,0);   }
void rgbAmber() { rgb(180,90,0);  }
void rgbRed()   { rgb(200,0,0);   }
void rgbBlue()  { rgb(0,0,160);   }
void rgbOff()   { rgb(0,0,0);     }

/* ============================ STEPPER =================================== */
const uint8_t STEP_SEQ[8][4] = {
  {1,0,0,0},{1,1,0,0},{0,1,0,0},{0,1,1,0},
  {0,0,1,0},{0,0,1,1},{0,0,0,1},{1,0,0,1}
};

void coilsOff() {
  digitalWrite(PIN_STEP_IN1, LOW); digitalWrite(PIN_STEP_IN2, LOW);
  digitalWrite(PIN_STEP_IN3, LOW); digitalWrite(PIN_STEP_IN4, LOW);
}

void stepMove(uint16_t steps, int8_t dir) {
  static uint8_t phase = 0;
  for (uint16_t i = 0; i < steps; i++) {
    phase = (phase + (dir > 0 ? 1 : 7)) & 0x07;
    digitalWrite(PIN_STEP_IN1, STEP_SEQ[phase][0]);
    digitalWrite(PIN_STEP_IN2, STEP_SEQ[phase][1]);
    digitalWrite(PIN_STEP_IN3, STEP_SEQ[phase][2]);
    digitalWrite(PIN_STEP_IN4, STEP_SEQ[phase][3]);
    delayMicroseconds(STEP_DELAY_US);
  }
  coilsOff();                    /* CRITICAL on USB power */
}

/* ============================ SENSORS =================================== */
float readTempC() {
  int raw = analogRead(PIN_THERM);
  if (raw <= 0 || raw >= 1023) return -99.0f;
  float r = 10000.0f / ((1023.0f / raw) - 1.0f);
  float s = log(r / 10000.0f) / 3950.0f + 1.0f / 298.15f;
  return (1.0f / s) - 273.15f;
}

bool tiltOn() {
  bool v = (digitalRead(PIN_TILT) == LOW);
#if TILT_INVERT
  return !v;
#else
  return v;
#endif
}

bool pirOn() { return digitalRead(PIN_PIR) == HIGH; }

void beep(uint16_t ms) {
  digitalWrite(PIN_BUZZER, HIGH); delay(ms); digitalWrite(PIN_BUZZER, LOW);
}

/* ============================ MESSAGING ================================= */
void say(const char *s) { Serial1.println(s); Serial.println(s); }

void sendTelemetry() {
  snprintf(txbuf, sizeof(txbuf),
    "{\"t\":\"tel\",\"st\":%d,\"ratio\":%d,\"tmp\":%d,\"snd\":%d,\"pho\":%d,"
    "\"tilt\":%d,\"occ\":%d,\"va\":%d,\"vt\":%d,\"vs\":%d,\"votes\":%d,"
    "\"pb\":%d,\"thr\":%d}",
    (int)state, (int)(ratio*100), (int)(readTempC()*10),
    analogRead(PIN_SOUND), analogRead(PIN_PHOTO),
    tiltOn()?1:0, pirOn()?1:0,
    voteAccel?1:0, voteTilt?1:0, voteSound?1:0,
    (voteAccel?1:0)+(voteTilt?1:0)+(voteSound?1:0),
    (int)(periodBaseline*1000), (int)(TRIGGER_RATIO*10));
  say(txbuf);
}

void sendAccel(int16_t v) {
  snprintf(txbuf, sizeof(txbuf), "{\"t\":\"acc\",\"v\":%d,\"r\":%d}", v, (int)(ratio*100));
  say(txbuf);
}

void sendPhase(const char *p) {
  snprintf(txbuf, sizeof(txbuf), "{\"t\":\"phase\",\"p\":\"%s\"}", p);
  say(txbuf);
}

void sendActuator(const char *dev, uint8_t st) {
  snprintf(txbuf, sizeof(txbuf), "{\"t\":\"act\",\"dev\":\"%s\",\"st\":%d}", dev, st);
  say(txbuf);
}

void sendRecording() {
  snprintf(txbuf, sizeof(txbuf), "{\"t\":\"recbegin\",\"n\":%d,\"hz\":%d}", recCount, SAMPLE_HZ);
  say(txbuf);
  delay(20);
  const uint8_t PER = 20;
  uint16_t chunks = (recCount + PER - 1) / PER;
  for (uint16_t c = 0; c < chunks; c++) {
    uint16_t start = c * PER;
    uint16_t n = min((uint16_t)PER, (uint16_t)(recCount - start));
    long sum = 0;
    Serial1.print(F("{\"t\":\"rec\",\"c\":")); Serial1.print(c); Serial1.print(F(",\"d\":["));
    for (uint16_t i = 0; i < n; i++) {
      Serial1.print(recBuf[start+i]); sum += recBuf[start+i];
      if (i < n-1) Serial1.print(',');
    }
    Serial1.print(F("],\"sum\":")); Serial1.print(sum); Serial1.println('}');
    delay(12);                    /* let the BLE buffer drain */
  }
  say("{\"t\":\"recend\"}");
}

void sendAssessment() {
  snprintf(txbuf, sizeof(txbuf),
    "{\"t\":\"assess\",\"pb\":%d,\"pa\":%d,\"pct\":%d,\"pga\":%d,"
    "\"tiltp\":%d,\"pwr\":%d,\"verdict\":\"%c\"}",
    (int)(periodBaseline*1000), (int)(periodAfter*1000),
    (int)(periodChangePct*10), (int)(peakAccelG*1000),
    tiltPermanent?1:0, powerCutConfirmed?1:0, verdict);
  say(txbuf);
}

/* ============================ ACTUATORS ================================= */
void powerCut() {
  stPower = 1; sendActuator("power", 1);
  int before = analogRead(PIN_PHOTO);
  digitalWrite(PIN_POWERCUT, LOW);
  delay(200);
  int after = analogRead(PIN_PHOTO);
  beep(80);
  powerCutConfirmed = (abs(after - before) > 150);
  stPower = powerCutConfirmed ? 2 : 3;
  sendActuator("power", stPower);
  snprintf(txbuf, sizeof(txbuf),
    "{\"t\":\"verify\",\"dev\":\"power\",\"before\":%d,\"after\":%d,\"ok\":%d}",
    before, after, powerCutConfirmed ? 1 : 0);
  say(txbuf);
}

void powerRestore() {
  digitalWrite(PIN_POWERCUT, HIGH);
  delay(150);
  powerCutConfirmed = false;
  stPower = 0; sendActuator("power", 0);
}

void waterClose() {
  if (!stepperEnabled) {
    stWater = 3; sendActuator("water", 3);
    say("{\"t\":\"note\",\"m\":\"water main unavailable - reduced power mode\"}");
    return;
  }
  stWater = 1; sendActuator("water", 1);
  stepMove(STEP_COUNT, +1);
  stWater = 2; sendActuator("water", 2);
}

void waterOpen() {
  if (!stepperEnabled) { stWater = 0; sendActuator("water", 0); return; }
  stepMove(STEP_COUNT, -1);
  stWater = 0; sendActuator("water", 0);
}

void resetActuators() {
  powerRestore();
  delay(ACTUATOR_GAP_MS);
  waterOpen();
  say("{\"t\":\"note\",\"m\":\"actuators reset\"}");
}

/* ============================ PERIOD ==================================== */
/* Time-domain zero-crossing counting. At these low frequencies this beats an
   FFT, because an FFT would need an impractically long record for resolution. */
float measurePeriod(uint16_t durationMs) {
  uint32_t t0 = millis();
  float avg = 0; uint16_t n = 0;
  while (millis() - t0 < durationMs / 2) {
    mpuRead();
    avg += (accelMag() - gravityMag); n++;
    delay(1000 / SAMPLE_HZ);
  }
  if (n) avg /= n;

  t0 = millis();
  uint16_t crossings = 0;
  float prev = 0; bool first = true;
  uint32_t elapsed = 0;
  while ((elapsed = millis() - t0) < durationMs / 2) {
    mpuRead();
    float dev = accelMag() - gravityMag - avg;
    if (!first && ((prev < 0 && dev >= 0) || (prev >= 0 && dev < 0))) crossings++;
    prev = dev; first = false;
    delay(1000 / SAMPLE_HZ);
  }
  if (crossings < 2) return 0;
  return (elapsed / 1000.0f) / (crossings / 2.0f);
}

void computeVerdict() {
  if (periodBaseline > 0.001f && periodAfter > 0.001f)
    periodChangePct = ((periodAfter - periodBaseline) / periodBaseline) * 100.0f;
  else periodChangePct = 0;

  tiltPermanent = tiltOn();

  if (tiltPermanent || periodChangePct > 15.0f)          verdict = 'R';
  else if (periodChangePct > 5.0f || peakAccelG > 0.30f) verdict = 'A';
  else                                                   verdict = 'G';

  if      (verdict == 'R') rgbRed();
  else if (verdict == 'A') rgbAmber();
  else                     rgbGreen();
}

/* ============================ CALIBRATION =============================== */
void calibrate() {
  state = ST_CALIBRATING;
  rgbBlue(); dispBlank();
  sendPhase("calibrating");
  say("{\"t\":\"note\",\"m\":\"calibrating - keep the surface still\"}");

  double sum = 0;
  for (uint16_t i = 0; i < 200; i++) { mpuRead(); sum += accelMag(); delay(5); }
  gravityMag = sum / 200.0;

  uint32_t ssum = 0;
  for (uint16_t i = 0; i < 200; i++) { ssum += analogRead(PIN_SOUND); delay(2); }
  soundBaseline = ssum / 200;

  sta = 0; lta = LTA_FLOOR; ratio = 1.0f;
  periodBaseline = measurePeriod(6000);

  snprintf(txbuf, sizeof(txbuf),
    "{\"t\":\"cal\",\"grav\":%d,\"snd\":%d,\"per\":%d}",
    (int)gravityMag, (int)soundBaseline, (int)(periodBaseline*1000));
  say(txbuf);

  rgbGreen(); dispOK();
  state = ST_MONITOR;
  sendPhase("monitoring");
}

/* ============================ THE EVENT SEQUENCE ======================== */
void pollCommands();   /* fwd */

void runEventSequence(bool wasDrill) {
  /* ---- WARN ---- */
  state = ST_TRIGGERED;
  rgbRed();
  snprintf(txbuf, sizeof(txbuf),
    "{\"t\":\"trig\",\"ratio\":%d,\"va\":%d,\"vt\":%d,\"vs\":%d,\"drill\":%d}",
    (int)(ratio*100), voteAccel?1:0, voteTilt?1:0, voteSound?1:0, wasDrill?1:0);
  say(txbuf);
  sendPhase("warning");

  for (int8_t s = COUNTDOWN_START; s >= 1; s--) {
    dispDigit(s);
    snprintf(txbuf, sizeof(txbuf), "{\"t\":\"count\",\"s\":%d}", s);
    say(txbuf);
    uint8_t beeps = COUNTDOWN_START - s + 1;
    for (uint8_t b = 0; b < beeps; b++) { beep(40); delay(60); }
    delay(1000 - beeps * 100);
    pollCommands();
  }
  dispAlert();
  beep(400);

  /* ---- ACT ---- one motor at a time, USB current budget ---- */
  state = ST_ACTING;
  sendPhase("acting");

  powerCut();
  delay(ACTUATOR_GAP_MS);

  waterClose();
  delay(ACTUATOR_GAP_MS);

  /* ---- RECORD ---- */
  state = ST_RECORDING;
  sendPhase("recording");
  recCount = 0; peakAccelG = 0;
  uint32_t t = micros();
  while (recCount < REC_LEN) {
    if (micros() - t >= SAMPLE_PERIOD_US) {
      t += SAMPLE_PERIOD_US;
      mpuRead();
      float dev = accelMag() - gravityMag;
      recBuf[recCount++] = (int16_t)constrain(dev, -32000, 32000);
      float g = fabs(dev) / 16384.0f;
      if (g > peakAccelG) peakAccelG = g;
    }
  }
  sendRecording();

  /* ---- ASSESS ---- */
  state = ST_ASSESSING;
  sendPhase("assessing");
  dispBlank(); rgbBlue();
  delay(1200);
  periodAfter = measurePeriod(6000);

  /* ---- VERDICT ---- */
  state = ST_VERDICT;
  computeVerdict();
  sendAssessment();
  sendPhase("verdict");

  if      (verdict == 'R') dispAlert();
  else if (verdict == 'A') dispDigit(1);
  else                     dispOK();
}

/* ============================ FUSION VOTING ============================= */
bool fusionSaysEvent() {
  uint32_t now = millis();
  if (voteAccel && now - voteAccelMs > VOTE_WINDOW_MS) voteAccel = false;
  if (voteTilt  && now - voteTiltMs  > VOTE_WINDOW_MS) voteTilt  = false;
  if (voteSound && now - voteSoundMs > VOTE_WINDOW_MS) voteSound = false;
  uint8_t v = (voteAccel?1:0) + (voteTilt?1:0) + (voteSound?1:0);
  return v >= VOTES_REQUIRED;
}

/* ============================ COMMANDS ================================== */
char cmdBuf[40];
uint8_t cmdLen = 0;

void ack(const char *c) {
  snprintf(txbuf, sizeof(txbuf), "{\"t\":\"ack\",\"c\":\"%s\"}", c);
  say(txbuf);
}

void handleCommand(char *c) {
  for (char *p = c; *p; p++) *p = toupper(*p);

  if (!strcmp(c, "DRILL")) {
    ack("DRILL");
    runEventSequence(true);
  }
  else if (!strcmp(c, "ARM"))    { state = ST_MONITOR;  rgbGreen(); dispOK();   ack("ARM"); }
  else if (!strcmp(c, "DISARM")) { state = ST_DISARMED; rgbBlue();  dispBlank();ack("DISARM"); }
  else if (!strcmp(c, "CAL"))    { ack("CAL"); calibrate(); }
  else if (!strcmp(c, "RESET"))  {
    ack("RESET"); resetActuators();
    state = ST_MONITOR; rgbGreen(); dispOK(); sendPhase("monitoring");
  }
  else if (!strcmp(c, "SEND"))   { ack("SEND"); sendRecording(); }
  else if (!strcmp(c, "STATUS")) { sendTelemetry(); }
  else if (!strcmp(c, "PWR:1"))  { ack("PWR:1"); powerCut(); }
  else if (!strcmp(c, "PWR:0"))  { ack("PWR:0"); powerRestore(); }
  else if (!strcmp(c, "WTR:1"))  { ack("WTR:1"); waterClose(); }
  else if (!strcmp(c, "WTR:0"))  { ack("WTR:0"); waterOpen(); }
  else if (!strcmp(c, "NOSTEP")) { stepperEnabled = false; ack("NOSTEP"); }
  else if (!strcmp(c, "YESTEP")) { stepperEnabled = true;  ack("YESTEP"); }
  else if (!strcmp(c, "BEEP"))   { ack("BEEP"); beep(200); }
  else if (!strncmp(c, "THR:", 4))  { TRIGGER_RATIO   = atoi(c+4)/10.0f; sendTelemetry(); }
  else if (!strncmp(c, "STEP:", 5)) { STEP_COUNT      = atoi(c+5);       sendTelemetry(); }
  else if (!strncmp(c, "SPD:", 4))  { STEP_DELAY_US   = atoi(c+4);       sendTelemetry(); }
  else if (!strncmp(c, "PHO:", 4))  { PHOTO_THRESHOLD = atoi(c+4);       sendTelemetry(); }
  else say("{\"t\":\"err\",\"m\":\"unknown command\"}");
}

void pollCommands() {
  while (Serial1.available()) {
    char ch = Serial1.read();
    if (ch == '\n' || ch == '\r') {
      if (cmdLen) { cmdBuf[cmdLen] = 0; handleCommand(cmdBuf); cmdLen = 0; }
    } else if (cmdLen < sizeof(cmdBuf)-1) cmdBuf[cmdLen++] = ch;
  }
  while (Serial.available()) {          /* USB monitor works too, for the bench */
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') {
      if (cmdLen) { cmdBuf[cmdLen] = 0; handleCommand(cmdBuf); cmdLen = 0; }
    } else if (cmdLen < sizeof(cmdBuf)-1) cmdBuf[cmdLen++] = ch;
  }
}

/* ============================ SETUP ===================================== */
void setup() {
  Serial.begin(115200);
  Serial1.begin(115200);        /* match your BLE module - use 9600 if unchanged */
  Wire.begin();
  Wire.setClock(400000);

  pinMode(PIN_BUZZER, OUTPUT);   digitalWrite(PIN_BUZZER, LOW);
  pinMode(PIN_POWERCUT, OUTPUT); digitalWrite(PIN_POWERCUT, HIGH);
  pinMode(PIN_STEP_IN1, OUTPUT); pinMode(PIN_STEP_IN2, OUTPUT);
  pinMode(PIN_STEP_IN3, OUTPUT); pinMode(PIN_STEP_IN4, OUTPUT);
  coilsOff();
  pinMode(PIN_TILT,   INPUT_PULLUP);
  pinMode(PIN_PIR,    INPUT);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  pinMode(PIN_RGB_R,  OUTPUT);
  pinMode(PIN_RGB_G,  OUTPUT);
  pinMode(PIN_RGB_B,  OUTPUT);

  maxInit(); dispBlank(); rgbBlue();
  delay(300);

  bool mpuOK = mpuInit();
  snprintf(txbuf, sizeof(txbuf), "{\"t\":\"boot\",\"mpu\":%d}", mpuOK ? 1 : 0);
  say(txbuf);

  if (!mpuOK) {
    while (1) {
      rgbRed(); delay(200); rgbOff(); delay(200);
      say("{\"t\":\"err\",\"m\":\"accelerometer missing - check AD0 wire\"}");
      delay(2000);
    }
  }

  beep(120);
  calibrate();
}

/* ============================ LOOP ====================================== */
void loop() {
  pollCommands();

  /* button: arm / disarm / reset after a verdict */
  if (digitalRead(PIN_BUTTON) == LOW && millis() - lastButtonMs > 400) {
    lastButtonMs = millis();
    if (state == ST_DISARMED)      { state = ST_MONITOR; rgbGreen(); dispOK(); sendPhase("monitoring"); }
    else if (state == ST_VERDICT)  { resetActuators(); state = ST_MONITOR; rgbGreen(); dispOK(); sendPhase("monitoring"); }
    else                           { state = ST_DISARMED; rgbBlue(); dispBlank(); sendPhase("disarmed"); }
    beep(60);
  }

  /* sampling and trigger detection */
  if (micros() - lastSampleUs >= SAMPLE_PERIOD_US) {
    lastSampleUs += SAMPLE_PERIOD_US;
    mpuRead();
    float dev = fabs(accelMag() - gravityMag);

    /* recursive STA/LTA - the same idea real seismometers use */
    sta = STA_ALPHA * dev + (1.0f - STA_ALPHA) * sta;
    lta = LTA_ALPHA * dev + (1.0f - LTA_ALPHA) * lta;
    if (lta < LTA_FLOOR) lta = LTA_FLOOR;
    ratio = sta / lta;

    /* three independent channels vote */
    if (ratio > TRIGGER_RATIO)                                 { voteAccel = true; voteAccelMs = millis(); }
    if (tiltOn())                                              { voteTilt  = true; voteTiltMs  = millis(); }
    if (analogRead(PIN_SOUND) > soundBaseline + SOUND_DELTA)   { voteSound = true; voteSoundMs = millis(); }

    if (++streamDivider >= (SAMPLE_HZ / 10)) {
      streamDivider = 0;
      if (state == ST_MONITOR || state == ST_DISARMED)
        sendAccel((int16_t)constrain(accelMag() - gravityMag, -32000, 32000));
    }

    if (state == ST_MONITOR && fusionSaysEvent()) {
      voteAccel = voteTilt = voteSound = false;
      runEventSequence(false);
      lastSampleUs = micros();
    }
  }

  /* telemetry once a second */
  if (millis() - lastTelemetryMs > 1000) {
    lastTelemetryMs = millis();
    sendTelemetry();
  }

  /* pulse the verdict LED while holding a result */
  if (state == ST_VERDICT) {
    if ((millis() / 500) % 2) {
      if      (verdict == 'R') rgbRed();
      else if (verdict == 'A') rgbAmber();
      else                     rgbGreen();
    } else rgbOff();
  }
}
```
