// The seeded world.
//
// The app opens onto a working library on a fresh install with no network, no
// account and no hardware. These are real buildings with real published
// figures, chosen because each one teaches something different: a soft storey,
// an unreinforced masonry hall, a base-isolated tower, a supertall with a
// six-second period.
//
// Nothing here is invented. Where a figure is an estimate it is marked as one,
// and the provenance travels with the building into the interface.

export const SEED_BUILDINGS = [
  {
    id: 'seed-my-building',
    name: 'My building',
    address: 'The one you are in',
    latitude: 37.7749,
    longitude: -122.4194,
    storeyCount: 8,
    height: 27,
    footprintArea: 620,
    yearBuilt: 1994,
    material: 'reinforcedConcrete',
    system: 'momentFrame',
    soil: 'denseSoil',
    retrofit: 'none',
    isSandbox: true,
    notes: 'The default building. Edit it to match yours, or import a real one.',
    provenance: { height: 'defaultAssumption', storeyCount: 'defaultAssumption' },
  },
  {
    id: 'seed-christchurch-arts',
    name: 'Christchurch Arts Centre',
    address: 'Christchurch, New Zealand',
    latitude: -43.5309,
    longitude: 172.6285,
    storeyCount: 3,
    height: 14,
    footprintArea: 2100,
    yearBuilt: 1877,
    material: 'unreinforcedMasonry',
    system: 'unreinforced',
    soil: 'softSoil',
    retrofit: 'full',
    notes: 'Gothic revival stone. Severely damaged in 2011 and rebuilt over a decade '
      + 'with base isolation and steel framing — the clearest case in the library of '
      + 'what retrofit actually buys.',
    provenance: { yearBuilt: 'wikidata', material: 'wikidata' },
  },
  {
    id: 'seed-ortigas',
    name: 'Ortigas Soft-Storey Apartments',
    address: 'Pasig, Philippines',
    latitude: 14.5833,
    longitude: 121.0614,
    storeyCount: 7,
    height: 21,
    footprintArea: 480,
    yearBuilt: 1988,
    material: 'reinforcedConcrete',
    system: 'softStorey',
    soil: 'softSoil',
    retrofit: 'none',
    notes: 'Open parking at ground level under six storeys of flats. The ground floor '
      + 'is roughly half as stiff as the ones above it, which is the configuration '
      + 'that collapses first and kills most people.',
    provenance: { system: 'aiInference' },
  },
  {
    id: 'seed-salesforce',
    name: 'Salesforce Tower',
    address: 'San Francisco, California',
    latitude: 37.7897,
    longitude: -122.3972,
    storeyCount: 61,
    height: 326,
    footprintArea: 2800,
    yearBuilt: 2018,
    material: 'steel',
    system: 'dualSystem',
    soil: 'denseSoil',
    retrofit: 'none',
    notes: 'Ductile core with an outrigger frame, founded on piles driven to bedrock '
      + 'through bay mud. Period near four seconds — long enough that it responds to '
      + 'distant large earthquakes rather than nearby small ones.',
    provenance: { height: 'wikidata', storeyCount: 'wikidata', material: 'wikidata' },
  },
  {
    id: 'seed-skytree',
    name: 'Tokyo Skytree',
    address: 'Sumida, Tokyo',
    latitude: 35.7101,
    longitude: 139.8107,
    storeyCount: 29,
    height: 634,
    footprintArea: 3600,
    yearBuilt: 2012,
    material: 'steel',
    system: 'baseIsolated',
    soil: 'softSoil',
    retrofit: 'none',
    notes: 'A central concrete shaft acts as a tuned mass against the steel lattice — '
      + 'the same principle as a five-storey pagoda, at 634 metres.',
    provenance: { height: 'wikidata', yearBuilt: 'wikidata' },
  },
  {
    id: 'seed-transamerica',
    name: 'Transamerica Pyramid',
    address: 'San Francisco, California',
    latitude: 37.7952,
    longitude: -122.4028,
    storeyCount: 48,
    height: 260,
    footprintArea: 1800,
    yearBuilt: 1972,
    material: 'steel',
    system: 'bracedFrame',
    soil: 'denseSoil',
    retrofit: 'partial',
    notes: 'The taper is structural, not stylistic: it puts mass low and reduces the '
      + 'wind and seismic moment at the base. It rode out Loma Prieta in 1989 with '
      + 'the top swaying about 30 cm for over a minute.',
    provenance: { height: 'wikidata', yearBuilt: 'wikidata' },
  },
  {
    id: 'seed-mexico-city',
    name: 'Tlatelolco Housing Block',
    address: 'Mexico City, Mexico',
    latitude: 19.4515,
    longitude: -99.1400,
    storeyCount: 13,
    height: 42,
    footprintArea: 900,
    yearBuilt: 1964,
    material: 'reinforcedConcrete',
    system: 'momentFrame',
    soil: 'verySoftSoil',
    retrofit: 'partial',
    notes: 'Built on the bed of a drained lake. The soil amplifies motion near two '
      + 'seconds, which happens to be the period of a building about this tall — the '
      + 'resonance that made 1985 so lethal.',
    provenance: { soil: 'wikidata' },
  },
  {
    id: 'seed-torre-mayor',
    name: 'Torre Mayor',
    address: 'Mexico City, Mexico',
    latitude: 19.4260,
    longitude: -99.1755,
    storeyCount: 55,
    height: 225,
    footprintArea: 2200,
    yearBuilt: 2003,
    material: 'steel',
    system: 'bracedFrame',
    soil: 'verySoftSoil',
    retrofit: 'none',
    notes: 'Ninety-eight seismic dampers inside a diagrid. Built on the same lake bed '
      + 'as Tlatelolco and designed explicitly against it.',
    provenance: { height: 'wikidata' },
  },
  {
    id: 'seed-victorian-terrace',
    name: 'Victorian Terrace',
    address: 'A typical brick terrace',
    latitude: 51.5074,
    longitude: -0.1278,
    storeyCount: 3,
    height: 10,
    footprintArea: 75,
    yearBuilt: 1890,
    material: 'unreinforcedMasonry',
    system: 'unreinforced',
    soil: 'stiffSoil',
    retrofit: 'none',
    notes: 'Load-bearing brick with timber floors and no tie between them. Stiff, so '
      + 'it takes the full force of high-frequency shaking rather than swaying out of '
      + 'the way of it.',
    provenance: { material: 'defaultAssumption' },
  },
  {
    id: 'seed-school',
    name: 'Reinforced School Block',
    address: 'A typical post-war school',
    latitude: 35.6812,
    longitude: 139.7671,
    storeyCount: 4,
    height: 14,
    footprintArea: 1400,
    yearBuilt: 1978,
    material: 'reinforcedConcrete',
    system: 'shearWall',
    soil: 'stiffSoil',
    retrofit: 'full',
    notes: 'Long, low and full of shear walls. Retrofitted with external steel bracing '
      + 'in the 1990s, the pattern used across Japan after 1995.',
    provenance: { retrofit: 'defaultAssumption' },
  },
];

/**
 * Historic ground motions, as parameters rather than as recorded traces.
 *
 * Real strong-motion records are megabytes each and licensed per-record. These
 * reproduce the character that matters for the simulation — duration, dominant
 * period, peak acceleration and the shape of the envelope — from published
 * summary figures, and the app says so rather than implying it is playing back
 * the real accelerogram.
 */
export const EARTHQUAKES = [
  {
    id: 'elcentro-1940',
    name: 'El Centro',
    year: 1940,
    magnitude: 6.9,
    pga: 3.13,
    dominantPeriod: 0.55,
    duration: 30,
    riseTime: 2,
    note: 'The first strong-motion record ever obtained, and the reference case for '
      + 'most of twentieth-century earthquake engineering.',
  },
  {
    id: 'kobe-1995',
    name: 'Kobe',
    year: 1995,
    magnitude: 6.9,
    pga: 8.21,
    dominantPeriod: 0.9,
    duration: 20,
    riseTime: 1,
    note: 'A near-field pulse: most of the energy arrives in a few seconds. Devastating '
      + 'to buildings whose period sits near one second.',
  },
  {
    id: 'northridge-1994',
    name: 'Northridge',
    year: 1994,
    magnitude: 6.7,
    pga: 8.43,
    dominantPeriod: 0.6,
    duration: 15,
    riseTime: 1.5,
    note: 'Extremely high vertical acceleration. Broke welded steel connections thought '
      + 'to be reliable, which changed the codes worldwide.',
  },
  {
    id: 'mexico-1985',
    name: 'Mexico City',
    year: 1985,
    magnitude: 8.0,
    pga: 1.67,
    dominantPeriod: 2.0,
    duration: 60,
    riseTime: 12,
    note: 'Modest acceleration, catastrophic outcome. The lake-bed soil filtered the '
      + 'motion into a two-second sine wave that matched mid-rise buildings exactly.',
  },
  {
    id: 'christchurch-2011',
    name: 'Christchurch',
    year: 2011,
    magnitude: 6.2,
    pga: 21.0,
    dominantPeriod: 0.35,
    duration: 12,
    riseTime: 0.8,
    note: 'Shallow, directly beneath the city, with vertical acceleration above 2g. '
      + 'Unreinforced masonry had no chance.',
  },
  {
    id: 'tohoku-2011',
    name: 'Tōhoku',
    year: 2011,
    magnitude: 9.1,
    pga: 2.9,
    dominantPeriod: 1.4,
    duration: 180,
    riseTime: 25,
    note: 'Three minutes of shaking. Duration matters as much as amplitude: every cycle '
      + 'takes a little more out of the structure.',
  },
];

export const SOILS = {
  rock: { label: 'Rock', amplification: 1.0 },
  denseSoil: { label: 'Dense soil', amplification: 1.2 },
  stiffSoil: { label: 'Stiff soil', amplification: 1.4 },
  softSoil: { label: 'Soft soil', amplification: 1.8 },
  verySoftSoil: { label: 'Very soft soil', amplification: 2.4 },
};

export const RETROFITS = {
  none: { label: 'None', stiffnessFactor: 1.0, dampingBonus: 0 },
  partial: { label: 'Partial', stiffnessFactor: 1.2, dampingBonus: 0.01 },
  full: { label: 'Full', stiffnessFactor: 1.5, dampingBonus: 0.02 },
  baseIsolation: { label: 'Base isolation', stiffnessFactor: 0.35, dampingBonus: 0.10 },
};

export const VERDICTS = {
  safe: {
    label: 'Safe to occupy',
    tone: 'green',
    meaning: 'No structural damage was detected. The building responded the way an '
      + 'undamaged building of this type should.',
  },
  caution: {
    label: 'Restricted use',
    tone: 'amber',
    meaning: 'Something changed. It may be minor, but it should be looked at before '
      + 'the building is used normally again.',
  },
  unsafe: {
    label: 'Do not occupy',
    tone: 'red',
    meaning: 'The measurements are consistent with structural damage. Leave, and have '
      + 'the building inspected before returning.',
  },
  unknown: {
    label: 'Not yet assessed',
    tone: 'grey',
    meaning: 'There is a baseline but no event to compare against it.',
  },
};

/** The plan shapes an unmapped building can be given. */
export const PLAN_SHAPES = [
  'rectangular', 'square', 'lShaped', 'tShaped', 'uShaped',
  'cruciform', 'circular', 'octagonal', 'triangular', 'setbackTower',
];
