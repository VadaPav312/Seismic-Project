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

   Recording transfer is recoverable chunk by chunk: REC:n re-sends a single
   chunk, so one dropped BLE notification costs 12 ms rather than re-sending
   the whole 25-chunk recording.
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

/* ---- the serial budget -------------------------------------------------
   The BLE module is the narrowest thing in the whole system and everything
   sent has to fit through it. At 9600 8N1 there are ten bits to a byte, so
   the link carries 960 bytes a second and no more. Exceeding that does not
   drop data — it blocks, inside the sampling loop, which is worse.

     telemetry   ~128 bytes  x 1 Hz            = 128 B/s
     acceleration  ~31 bytes x STREAM_HZ
     a recording ~161 bytes  x 25 chunks       = 4025 B, about 4.2 s

   At STREAM_HZ = 10 the steady state was 438 B/s, or 46% of the link, and a
   128-byte telemetry line does not fit in the AVR's 64-byte transmit buffer
   — so once a second the sampler stalled for ~66 ms waiting on the radio.
   At 5 Hz it is 283 B/s, under a third, and telemetry is the only thing that
   ever has to wait.

   Halving the stream costs nothing real: the detector runs on all 50 Hz on
   the board, and the ten seconds an assessment is actually made from is
   recorded at the full rate and sent afterwards. The stream is for the trace
   on screen, and no eye resolves a seismograph faster than this. */
const uint32_t BLE_BAUD          = 9600;
const uint16_t BLE_BYTES_PER_SEC = BLE_BAUD / 10;   /* 8N1: ten bits a byte */
const uint16_t STREAM_HZ         = 5;
const uint8_t  STREAM_DIVIDER    = SAMPLE_HZ / STREAM_HZ;

/* Measured lengths of the two lines that are sent continuously. */
const uint16_t TELEMETRY_BYTES = 128;
const uint16_t ACCEL_BYTES     = 31;

/* The budget, checked by the compiler rather than remembered.
   Raising STREAM_HZ or adding a field to the telemetry line is exactly the
   change somebody makes without thinking about the radio, and the symptom —
   a sampling loop that stalls waiting on a full transmit buffer — looks
   nothing like its cause. Half the link is left free for the event messages,
   which all arrive at once and matter far more than the trace. */
static_assert(TELEMETRY_BYTES + ACCEL_BYTES * STREAM_HZ < BLE_BYTES_PER_SEC / 2,
              "steady-state output must stay under half the serial link");

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

const uint8_t REC_PER_CHUNK = 20;
/* A BLE notification is twenty bytes, so a 160-byte chunk is eight of them.
   Long enough for the module to get them out, short enough that twenty-five
   chunks stay inside five seconds. */
const uint16_t CHUNK_GAP_MS = 30;

uint16_t recChunkCount() {
  return (recCount + REC_PER_CHUNK - 1) / REC_PER_CHUNK;
}

/* One chunk, by index. Factored out so a single missing chunk can be re-sent
   without re-sending the other twenty-four.

   This is what REC: uses. A ten-second recording is 25 chunks and about three
   seconds of airtime; when one chunk is lost — which over BLE it routinely is —
   asking for the whole recording again spends all three seconds to recover
   twenty samples, and stands a fair chance of dropping a different chunk on the
   way. Asking for the one that is missing costs twelve milliseconds. */
void sendChunk(uint16_t c) {
  if (c >= recChunkCount()) {
    say("{\"t\":\"err\",\"m\":\"chunk out of range\"}");
    return;
  }
  uint16_t start = c * REC_PER_CHUNK;
  uint16_t n = min((uint16_t)REC_PER_CHUNK, (uint16_t)(recCount - start));
  long sum = 0;
  Serial1.print(F("{\"t\":\"rec\",\"c\":")); Serial1.print(c); Serial1.print(F(",\"d\":["));
  for (uint16_t i = 0; i < n; i++) {
    Serial1.print(recBuf[start+i]); sum += recBuf[start+i];
    if (i < n-1) Serial1.print(',');
  }
  Serial1.print(F("],\"sum\":")); Serial1.print(sum); Serial1.println('}');
}

void sendRecording() {
  snprintf(txbuf, sizeof(txbuf), "{\"t\":\"recbegin\",\"n\":%d,\"hz\":%d}", recCount, SAMPLE_HZ);
  say(txbuf);
  delay(20);
  uint16_t chunks = recChunkCount();
  for (uint16_t c = 0; c < chunks; c++) {
    sendChunk(c);
    /* One chunk is about 160 bytes, which at 9600 is 168 ms on the wire. The
       twelve milliseconds that used to be here were sized for a link ten
       times faster; at this rate the transmit buffer simply blocked instead,
       which throttled it accidentally rather than deliberately. Waiting for
       the buffer to actually empty is the honest version, and it gives the
       module's own radio time to push the notification out. */
    Serial1.flush();
    delay(CHUNK_GAP_MS);
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
  else if (!strncmp(c, "REC:", 4)) {
    /* Re-send one chunk. The app asks for exactly the ones that went missing
       rather than for the whole recording, so a single dropped notification
       costs twelve milliseconds instead of three seconds. */
    ack("REC");
    sendChunk((uint16_t)atoi(c+4));
  }
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
  /* 9600, which is what an HM-10 and nearly every clone of it ships with.
     It is also the constraint everything below is sized against: 9600 8N1 is
     960 bytes a second, and that is not a lot. See BLE_BYTES_PER_SEC. */
  Serial1.begin(BLE_BAUD);
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

    if (++streamDivider >= STREAM_DIVIDER) {
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
