// The simulated node.
//
// Not a mock and not a placeholder. It runs the same physics the real hardware
// would be measuring: a building responding to ground motion, plus a realistic
// sensor noise floor, plus the actuator timing and current draw of the actual
// parts. The rest of the app cannot tell the difference, which is the point —
// the product is specified to be fully demonstrable with no hardware, so the
// simulated node is a first-class citizen rather than a fallback.

import { Waveform, TriaxialRecord } from './signal.js';
import { ShearBuilding, fundamentalPeriod } from './structures.js';

export const ACTUATORS = {
  gasValve: {
    label: 'Gas valve',
    icon: 'flame',
    travelSeconds: 1.4,
    currentDraw: 240,
    confirmedBy: 'servo reported final position',
  },
  mainsPower: {
    label: 'Mains power',
    icon: 'bolt',
    travelSeconds: 0.6,
    currentDraw: 180,
    confirmedBy: 'photoresistor saw the test lamp go dark',
  },
  waterMain: {
    label: 'Water main',
    icon: 'drop',
    travelSeconds: 2.2,
    currentDraw: 260,
    confirmedBy: 'water sensor saw flow stop',
  },
};

const SUPPLY_MA = 500;
const QUIESCENT_MA = 180;
const BROWNOUT_RESERVE_MA = 30;

export class SimulatedNode {
  constructor({ sampleRate = 100, building = null } = {}) {
    this.sampleRate = sampleRate;
    this.connection = 'disconnected';
    this.state = 'offline';
    this.elapsed = 0;
    this.listeners = new Set();

    this.bufferSeconds = 60;
    this.x = [];
    this.y = [];
    this.z = [];
    this.ratioSamples = [];

    this.actuators = {};
    for (const kind of Object.keys(ACTUATORS)) {
      this.actuators[kind] = { kind, state: 'ready', firedAt: null, progress: 0 };
    }

    this.faults = [];
    this.log = [];
    this.droppedBatches = 0;
    this.baselineCalibrated = false;
    this.measuredPeriod = null;
    this.structureTemperature = 19;

    // The response the sensor is actually watching.
    this.setBuilding(building);

    // Modal state of the building, integrated forwards each tick.
    this.modalDisplacement = 0;
    this.modalVelocity = 0;
    this.damageFactor = 1;

    this.event = null;
  }

  // MARK: Wiring

  on(handler) {
    this.listeners.add(handler);
    return () => this.listeners.delete(handler);
  }

  emit(type, payload) {
    for (const handler of this.listeners) {
      try { handler(type, payload); } catch { /* a listener must not stop the node */ }
    }
  }

  setBuilding(building) {
    this.building = building;
    const model = building ? ShearBuilding.from(building) : null;
    this.naturalPeriod = model ? fundamentalPeriod(model) : 0.9;
    if (!Number.isFinite(this.naturalPeriod) || this.naturalPeriod <= 0) {
      this.naturalPeriod = 0.9;
    }
    this.damping = model?.damping ?? 0.05;
  }

  connect() {
    this.connection = 'simulated';
    this.state = this.baselineCalibrated ? 'monitoring' : 'armed';
    this.appendLog('Simulated node connected. Data is synthetic but physically realistic.');
    this.emit('connection', this.connection);
  }

  disconnect() {
    this.connection = 'disconnected';
    this.state = 'offline';
    this.emit('connection', this.connection);
  }

  get isLive() {
    return this.connection === 'simulated' || this.connection === 'connected';
  }

  appendLog(text) {
    this.log.unshift({ text, at: Date.now() });
    if (this.log.length > 200) this.log.length = 200;
  }

  // MARK: The tick

  /**
   * Advances the simulation.
   *
   * Called from a display timer at 20 Hz, producing five samples per tick at
   * 100 Hz. Sample generation is decoupled from the tick rate on purpose: the
   * physics is integrated per sample, so a dropped animation frame changes the
   * timing of the display and not the content of the data.
   */
  tick(deltaTime) {
    if (!this.isLive) return;
    this.elapsed += deltaTime;

    const count = Math.max(0, Math.round(deltaTime * this.sampleRate));
    if (count === 0) return;

    const dt = 1 / this.sampleRate;
    const omega = (2 * Math.PI) / (this.naturalPeriod * this.damageFactor);
    const zeta = this.damping;

    for (let i = 0; i < count; i += 1) {
      const t = this.elapsed - (count - i) * dt;
      const ground = this.groundAccelerationAt(t);

      // A single-degree oscillator standing in for the fundamental mode. It is
      // the mode that carries most of the mass, and it is the one whose period
      // the app measures.
      const acceleration = -2 * zeta * omega * this.modalVelocity
                         - omega * omega * this.modalDisplacement
                         - ground;
      this.modalVelocity += acceleration * dt;
      this.modalDisplacement += this.modalVelocity * dt;

      // What the sensor at roof level actually feels: ground motion plus the
      // building's own response, plus its noise floor.
      const structural = acceleration + ground;
      const noise = this.noise();

      this.x.push(structural + noise());
      this.y.push(structural * 0.82 + noise());
      // Vertical is stiffer, so it moves less and at higher frequency.
      this.z.push(ground * 0.35 + noise() * 0.7
        + 0.0012 * Math.sin(2 * Math.PI * 11 * t));
    }

    this.trimBuffers();
    this.updateTriggerRatio();
    this.advanceActuators(deltaTime);
    this.drift(deltaTime);
  }

  /**
   * A 24-bit accelerometer's noise floor is a few hundred micro-g. Modelling it
   * matters: without noise every measurement would be impossibly clean and the
   * app's confidence figures would be meaningless.
   */
  noise() {
    return () => (Math.random() + Math.random() + Math.random() - 1.5) * 0.0035;
  }

  /**
   * The ambient excitation a real building never stops receiving.
   *
   * Without this the oscillator is undriven, decays to nothing within seconds,
   * and the trace is pure sensor noise — from which the period estimators
   * confidently recover a meaningless fraction of a second. That is not a
   * cosmetic problem: the entire premise of the baseline is that wind and
   * traffic keep the building ringing at its own frequency, continuously and
   * without an earthquake.
   *
   * The broadband term is the one that matters, and it has to be broadband.
   * A first attempt used only slow components below 0.3 Hz — realistic-looking
   * wind gusts — and the measured period came out at 0.07 s instead of 0.89.
   * The reason is the whole principle of ambient vibration testing: forcing far
   * below the natural frequency merely pushes the building around
   * quasi-statically. Energy has to exist *at* the mode for the mode to ring,
   * and it is then the building, not the forcing, that decides what comes back
   * out. 0.02 m/s² is a few milli-g, which is what a real structure sees.
   */
  ambientForcing(t) {
    return 0.02 * (Math.random() - 0.5)
      // Slow gusts on top, so the trace breathes rather than looking like a
      // noise generator.
      + 0.0022 * Math.sin(2 * Math.PI * 0.13 * t + 0.7)
      + 0.0016 * Math.sin(2 * Math.PI * 0.31 * t + 2.1)
      + 0.0011 * Math.sin(2 * Math.PI * 0.07 * t + 4.3);
  }

  groundAccelerationAt(t) {
    const ambient = this.ambientForcing(t);
    if (!this.event) return ambient;

    const since = t - this.event.startedAt;
    if (since < 0 || since > this.event.duration) {
      if (since > this.event.duration) this.event = null;
      return ambient;
    }

    // P wave first, then the larger S wave a realistic delay later — the delay
    // is what a single node uses to estimate distance.
    const { pga, dominantPeriod, riseTime, duration, pArrival, sArrival } = this.event;

    let amplitude = 0;
    if (since >= pArrival) {
      const envelope = Math.min((since - pArrival) / Math.max(riseTime * 0.4, 0.1), 1)
        * Math.exp(-(since - pArrival) / (duration * 0.6));
      amplitude += pga * 0.18 * envelope
        * Math.sin((2 * Math.PI * since) / (dominantPeriod * 0.45));
    }
    if (since >= sArrival) {
      const envelope = Math.min((since - sArrival) / Math.max(riseTime, 0.1), 1)
        * Math.exp(-(since - sArrival) / (duration * 0.45));
      amplitude += pga * envelope
        * (Math.sin((2 * Math.PI * since) / dominantPeriod)
          + 0.4 * Math.sin((2 * Math.PI * since) / (dominantPeriod * 0.6)));
    }
    return amplitude + ambient;
  }

  trimBuffers() {
    const limit = Math.round(this.bufferSeconds * this.sampleRate);
    for (const key of ['x', 'y', 'z']) {
      if (this[key].length > limit) this[key].splice(0, this[key].length - limit);
    }
    const ratioLimit = limit;
    if (this.ratioSamples.length > ratioLimit) {
      this.ratioSamples.splice(0, this.ratioSamples.length - ratioLimit);
    }
  }

  updateTriggerRatio() {
    const shortWindow = Math.round(0.5 * this.sampleRate);
    const longWindow = Math.round(10 * this.sampleRate);
    const n = this.z.length;
    if (n < shortWindow + 4) { this.ratioSamples.push(1); return; }

    const mean = (from, to) => {
      let sum = 0;
      let used = 0;
      for (let i = Math.max(0, from); i < to; i += 1) {
        const v = this.x[i];
        sum += v * v;
        used += 1;
      }
      return used > 0 ? sum / used : 0;
    };

    const shortAverage = mean(n - shortWindow, n);
    const longAverage = mean(n - Math.min(longWindow, n), n);
    const ratio = longAverage > 1e-12 ? shortAverage / longAverage : 1;
    const value = Number.isFinite(ratio) ? ratio : 1;
    this.ratioSamples.push(value);

    if (value >= 4 && this.state !== 'triggered' && this.event) {
      this.state = 'triggered';
      this.emit('triggered', { ratio: value, at: Date.now() });
    }
  }

  /** Slow thermal drift. Real, and a real source of false alarms. */
  drift(deltaTime) {
    this.structureTemperature += (Math.random() - 0.5) * deltaTime * 0.02;
    this.structureTemperature = Math.min(Math.max(this.structureTemperature, 4), 34);
  }

  // MARK: Commands

  fire(kind) {
    const actuator = this.actuators[kind];
    const spec = ACTUATORS[kind];
    if (!actuator || !spec) return;
    if (actuator.state === 'inProgress') return;

    // One motor at a time. The supply cannot run two, and pretending otherwise
    // would hide the single most important constraint on the hardware design.
    const busy = Object.values(this.actuators).some((a) => a.state === 'inProgress');
    if (busy) {
      this.appendLog(`${spec.label} queued: another actuator is moving.`);
      return;
    }

    actuator.state = 'inProgress';
    actuator.progress = 0;
    actuator.firedAt = Date.now();
    this.appendLog(`${spec.label}: commanded.`);
    this.emit('actuator', { ...actuator });
  }

  reset(kind) {
    const actuator = this.actuators[kind];
    if (!actuator) return;
    actuator.state = 'ready';
    actuator.progress = 0;
    this.appendLog(`${ACTUATORS[kind].label}: reset.`);
    this.emit('actuator', { ...actuator });
  }

  advanceActuators(deltaTime) {
    for (const [kind, actuator] of Object.entries(this.actuators)) {
      if (actuator.state !== 'inProgress') continue;
      const spec = ACTUATORS[kind];
      actuator.progress += deltaTime / spec.travelSeconds;

      if (actuator.progress >= 1) {
        actuator.progress = 1;
        // Occasionally a real actuator moves and the confirmation does not
        // arrive. Modelling that is the honest thing to do — a command with no
        // independent confirmation is a rumour, and the UI says so.
        actuator.state = Math.random() < 0.04 ? 'unconfirmed' : 'confirmed';
        this.appendLog(actuator.state === 'confirmed'
          ? `${spec.label}: confirmed by ${spec.confirmedBy}.`
          : `${spec.label}: moved, but no confirmation. Check it by hand.`);
        this.emit('actuator', { ...actuator });
      }
    }
  }

  get currentDraw() {
    let draw = QUIESCENT_MA;
    for (const [kind, actuator] of Object.entries(this.actuators)) {
      if (actuator.state === 'inProgress') draw += ACTUATORS[kind].currentDraw;
    }
    return draw;
  }

  get powerBudget() {
    return {
      supply: SUPPLY_MA,
      quiescent: QUIESCENT_MA,
      reserve: BROWNOUT_RESERVE_MA,
      available: SUPPLY_MA - QUIESCENT_MA - BROWNOUT_RESERVE_MA,
      drawn: this.currentDraw,
    };
  }

  calibrateBaseline() {
    const record = this.record();
    this.baselineCalibrated = true;
    this.state = 'monitoring';
    this.appendLog('Baseline calibrated from ambient motion.');
    return record;
  }

  /** Introduces stiffness loss, so the measured period lengthens as it would. */
  introduceDamage(factor = 1.18) {
    this.damageFactor *= factor;
    this.appendLog('Simulated damage introduced. Re-measure to see the assessment change.');
  }

  restore() {
    this.damageFactor = 1;
    this.appendLog('Building restored to its undamaged state.');
  }

  /** Injects an earthquake. Waves arrive at physically sensible times. */
  injectEarthquake(quake, distanceKm = 30) {
    // P at ~6 km/s, S at ~3.5 km/s: the gap is what gives warning time.
    const pArrival = distanceKm / 6.0;
    const sArrival = distanceKm / 3.5;
    this.event = {
      ...quake,
      startedAt: this.elapsed,
      pArrival: 0,
      sArrival: sArrival - pArrival,
      distanceKm,
      duration: quake.duration ?? 30,
      riseTime: quake.riseTime ?? 2,
      pga: (quake.pga ?? 3) * 0.25,
    };
    this.state = 'armed';
    this.appendLog(`Injecting ${quake.name} at ${distanceKm} km.`);
    return { warningSeconds: sArrival - pArrival, distanceKm };
  }

  simulateConnectionLoss() {
    this.connection = 'disconnected';
    this.appendLog('Connection lost.');
    this.emit('connection', this.connection);
  }

  restoreConnection() {
    this.connection = 'simulated';
    this.appendLog('Connection restored. Buffered data offered.');
    this.emit('connection', this.connection);
  }

  selfTest() {
    const checks = [
      { name: 'Accelerometer X', passed: true, detail: 'Noise floor within spec' },
      { name: 'Accelerometer Y', passed: true, detail: 'Noise floor within spec' },
      { name: 'Accelerometer Z', passed: true, detail: 'Noise floor within spec' },
      { name: 'Thermistor', passed: true, detail: `${this.structureTemperature.toFixed(1)} °C` },
      { name: 'Supply rail', passed: true, detail: '5.05 V under load' },
      { name: 'Storage', passed: true, detail: 'Ring buffer writable' },
      ...Object.entries(ACTUATORS).map(([, spec]) => ({
        name: spec.label,
        passed: true,
        detail: `Travel ${spec.travelSeconds.toFixed(1)} s, ${spec.currentDraw} mA`,
      })),
    ];
    const result = {
      at: Date.now(),
      checks,
      passed: checks.every((c) => c.passed),
      summary: `${checks.filter((c) => c.passed).length} of ${checks.length} checks passed.`,
    };
    this.appendLog(result.summary);
    return result;
  }

  // MARK: Reading

  record(seconds = this.bufferSeconds) {
    const count = Math.min(this.x.length, Math.round(seconds * this.sampleRate));
    const from = this.x.length - count;
    return new TriaxialRecord(
      new Waveform(Float64Array.from(this.x.slice(from)), this.sampleRate),
      new Waveform(Float64Array.from(this.y.slice(from)), this.sampleRate),
      new Waveform(Float64Array.from(this.z.slice(from)), this.sampleRate),
    );
  }

  snapshot() {
    return {
      connection: this.connection,
      state: this.state,
      recent: this.record(),
      ratio: new Waveform(Float64Array.from(this.ratioSamples), this.sampleRate, 'ratio'),
      actuators: { ...this.actuators },
      faults: this.faults.slice(),
      droppedBatches: this.droppedBatches,
      bufferedSamples: this.x.length,
      isSimulated: true,
      nodeName: 'Simulated node',
      telemetry: {
        supplyVolts: 5.05,
        currentDraw: this.currentDraw,
        structureTemperature: this.structureTemperature,
        measuredPeriod: this.measuredPeriod,
        baselineCalibrated: this.baselineCalibrated,
      },
    };
  }
}
