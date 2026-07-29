// The 3D building twin.
//
// Storeys are built once as a stack of meshes; the simulation then only writes
// each floor's horizontal offset and colour per frame. Rebuilding geometry per
// frame would be both slow and pointless — the shape does not change, only
// where each floor is.
//
// Two decisions worth stating. The renderer draws on demand rather than
// continuously, so a stationary building costs nothing; and each storey is an
// extrusion of the building's real footprint polygon rather than a box, because
// an imported building that comes out a featureless slab has thrown away the one
// genuinely site-specific fact the importer went and found.

import * as THREE from '../../vendor/three.module.min.js';
import { polygonFor, boundingBox } from '../core/planshape.js';

const DAMAGE_COLOURS = [
  0x4a708f, // none — cool, deliberately unalarming
  0x5c94a1,
  0xbca059,
  0xbf7047,
  0xad4045, // complete
];

const MATERIAL_COLOURS = {
  reinforcedConcrete: 0x9ea0a4,
  steel: 0x8c99ab,
  timber: 0xa87f56,
  masonry: 0xa88274,
  unreinforcedMasonry: 0xa88274,
  hybrid: 0x94989c,
  unknown: 0x8c8f94,
};

export class BuildingScene {
  constructor(container) {
    this.container = container;
    this.storeys = [];
    this.appliedState = new Map();
    this.exaggeration = 40;
    this.style = 'materials';
    this.needsRender = true;
    this.disposed = false;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x0a0b0d);

    this.camera = new THREE.PerspectiveCamera(42, 1, 0.1, 6000);

    this.renderer = new THREE.WebGLRenderer({
      antialias: true,
      // A depth-only clear each frame is enough; preserving the buffer costs
      // memory bandwidth for no benefit here.
      preserveDrawingBuffer: false,
      powerPreference: 'default',
    });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.shadowMap.enabled = false;
    container.append(this.renderer.domElement);

    this.addLights();
    this.buildingRoot = new THREE.Group();
    this.scene.add(this.buildingRoot);

    this.attachControls();
    this.observeSize();
    this.loop();
  }

  /**
   * Lit for a dark room.
   *
   * This app is most likely opened at night, and a bright key light against a
   * near-black background is genuinely uncomfortable. The massing still reads
   * because what makes a shape legible is the contrast between its lit and
   * shadowed faces, not the absolute level.
   */
  addLights() {
    const key = new THREE.DirectionalLight(0xf2f4f7, 1.15);
    key.position.set(1, 1.6, 0.9);
    this.scene.add(key);

    const fill = new THREE.DirectionalLight(0x3ec9f0, 0.32);
    fill.position.set(-1.2, 0.4, -0.8);
    this.scene.add(fill);

    this.scene.add(new THREE.AmbientLight(0x6b7280, 0.55));
  }

  // MARK: Geometry

  build(building, { animate = false } = {}) {
    for (const storey of this.storeys) {
      storey.geometry.dispose();
      storey.material.dispose();
      this.buildingRoot.remove(storey);
    }
    this.storeys = [];
    this.appliedState.clear();
    this.building = building;

    const count = Math.max(1, Math.round(building.storeyCount ?? 1));
    const totalHeight = Math.max(building.height ?? count * 3.4, 1);
    const storeyHeight = totalHeight / count;

    const ring = building.footprint?.length >= 4
      ? building.footprint
      : polygonFor(building.planShape ?? 'rectangular', building.footprintArea ?? 400);

    const shape = this.shapeFrom(ring);
    const box = boundingBox(ring);

    for (let i = 0; i < count; i += 1) {
      // 0.88 of the storey height, so a visible reveal separates the floors and
      // the stack reads as storeys rather than as one extrusion.
      const geometry = new THREE.ExtrudeGeometry(shape, {
        depth: storeyHeight * 0.88,
        bevelEnabled: false,
        curveSegments: 4,
      });
      // ExtrudeGeometry builds along +Z; rotating lays the plan flat so the
      // extrusion becomes vertical.
      geometry.rotateX(-Math.PI / 2);

      const material = new THREE.MeshStandardMaterial({
        color: this.baseColour(),
        roughness: building.material === 'steel' ? 0.42 : 0.86,
        metalness: building.material === 'steel' ? 0.45 : 0.02,
        flatShading: false,
      });

      const mesh = new THREE.Mesh(geometry, material);
      mesh.position.y = i * storeyHeight;
      mesh.userData.index = i;
      mesh.userData.restY = mesh.position.y;
      if (animate) mesh.scale.setScalar(0.001);

      this.buildingRoot.add(mesh);
      this.storeys.push(mesh);
    }

    this.addGround(Math.max(box.width, box.depth) * 3.4 + 40);
    this.frameCamera(totalHeight, Math.max(box.width, box.depth));
    if (animate) this.playConstruction();
    this.needsRender = true;
  }

  shapeFrom(ring) {
    const box = boundingBox(ring);
    const cx = (box.minX + box.maxX) / 2;
    const cy = (box.minY + box.maxY) / 2;

    const shape = new THREE.Shape();
    ring.forEach(([x, y], index) => {
      // Centred, or the tower would stand off to one side of its own ground
      // plane and out of the camera's framing.
      const px = x - cx;
      const py = y - cy;
      if (index === 0) shape.moveTo(px, py);
      else shape.lineTo(px, py);
    });
    shape.closePath();
    return shape;
  }

  /**
   * A finite ground plane, deliberately not an infinite one.
   *
   * Anything that measures the scene's bounds — including automatic camera
   * framing — gets a meaningless answer from an infinite floor.
   */
  addGround(size) {
    if (this.ground) {
      this.ground.geometry.dispose();
      this.ground.material.dispose();
      this.scene.remove(this.ground);
    }
    const geometry = new THREE.PlaneGeometry(size, size);
    geometry.rotateX(-Math.PI / 2);
    const material = new THREE.MeshStandardMaterial({
      color: 0x131519, roughness: 1, metalness: 0,
    });
    this.ground = new THREE.Mesh(geometry, material);
    this.ground.position.y = -0.05;
    this.scene.add(this.ground);
  }

  baseColour() {
    if (this.style === 'drift') return DAMAGE_COLOURS[0];
    return MATERIAL_COLOURS[this.building?.material] ?? MATERIAL_COLOURS.unknown;
  }

  setStyle(style) {
    this.style = style;
    for (const storey of this.storeys) {
      storey.material.wireframe = style === 'wireframe';
      storey.material.color.setHex(
        style === 'wireframe' ? 0x3ec9f0 : this.baseColour(),
      );
    }
    this.appliedState.clear();
    this.needsRender = true;
  }

  // MARK: Animation

  /**
   * Writes one frame of a solved response.
   *
   * The material is only touched when a storey's damage state actually changes.
   * Reassigning a colour every frame invalidates the material and forces it back
   * to the GPU — on a sixty-storey tower that is thousands of pointless uploads
   * a second, and the state itself changes a handful of times in a whole event.
   */
  apply(displacements, drifts, system = 'momentFrame') {
    const exaggeration = this.exaggeration;
    for (let i = 0; i < this.storeys.length; i += 1) {
      const storey = this.storeys[i];
      const offset = Number.isFinite(displacements?.[i]) ? displacements[i] : 0;
      storey.position.x = offset * exaggeration;

      if (this.style !== 'drift' || !drifts) continue;
      const state = damageIndex(Math.abs(drifts[i] ?? 0), system);
      if (this.appliedState.get(i) === state) continue;
      this.appliedState.set(i, state);
      storey.material.color.setHex(DAMAGE_COLOURS[state]);
    }
    this.needsRender = true;
  }

  /** Permanently tints a damaged storey, so the damage stays visible. */
  markDamage(storeyResults, system = 'momentFrame') {
    for (const result of storeyResults ?? []) {
      const storey = this.storeys[result.storey - 1];
      if (!storey || result.damageState === 0) continue;
      storey.material.color.setHex(DAMAGE_COLOURS[result.damageState]);
      storey.material.emissive.setHex(DAMAGE_COLOURS[result.damageState]);
      storey.material.emissiveIntensity = 0.16;
      this.appliedState.set(result.storey - 1, result.damageState);
    }
    this.needsRender = true;
  }

  reset() {
    for (const storey of this.storeys) {
      storey.position.x = 0;
      storey.material.emissiveIntensity = 0;
      storey.material.color.setHex(this.baseColour());
    }
    this.appliedState.clear();
    this.needsRender = true;
  }

  /** Animates a mode shape — "show me how it wants to move". */
  animateMode(shape, amplitude = 0.9) {
    this.modeShape = shape;
    this.modeAmplitude = amplitude;
    this.modeStartedAt = performance.now();
    this.needsRender = true;
  }

  stopMode() { this.modeShape = null; this.reset(); }

  playConstruction() {
    this.constructionStartedAt = performance.now();
    this.needsRender = true;
  }

  // MARK: Camera

  frameCamera(totalHeight, plan) {
    const distance = Math.max(totalHeight * 1.25, plan * 2.4, 22);
    this.orbit = { theta: Math.PI * 0.22, phi: Math.PI * 0.36, distance };
    this.target = new THREE.Vector3(0, totalHeight * 0.45, 0);
    this.updateCamera();
  }

  updateCamera() {
    if (!this.orbit) return;
    const { theta, phi, distance } = this.orbit;
    this.camera.position.set(
      this.target.x + distance * Math.sin(phi) * Math.sin(theta),
      this.target.y + distance * Math.cos(phi),
      this.target.z + distance * Math.sin(phi) * Math.cos(theta),
    );
    this.camera.lookAt(this.target);
    this.needsRender = true;
  }

  attachControls() {
    const element = this.renderer.domElement;
    let dragging = false;
    let lastX = 0;
    let lastY = 0;
    let pinchStart = null;

    const down = (event) => {
      if (event.touches?.length === 2) {
        pinchStart = { distance: touchDistance(event), start: this.orbit?.distance ?? 40 };
        return;
      }
      dragging = true;
      const point = event.touches?.[0] ?? event;
      lastX = point.clientX;
      lastY = point.clientY;
    };
    const move = (event) => {
      if (pinchStart && event.touches?.length === 2) {
        event.preventDefault();
        const scale = pinchStart.distance / Math.max(touchDistance(event), 1);
        this.orbit.distance = clamp(pinchStart.start * scale, 8, 4000);
        this.updateCamera();
        return;
      }
      if (!dragging || !this.orbit) return;
      event.preventDefault();
      const point = event.touches?.[0] ?? event;
      this.orbit.theta -= (point.clientX - lastX) * 0.008;
      // Clamped short of the poles: passing straight overhead flips the view
      // and is disorienting.
      this.orbit.phi = clamp(this.orbit.phi - (point.clientY - lastY) * 0.006, 0.12, Math.PI / 2);
      lastX = point.clientX;
      lastY = point.clientY;
      this.updateCamera();
    };
    const up = () => { dragging = false; pinchStart = null; };

    element.addEventListener('pointerdown', down);
    element.addEventListener('pointermove', move);
    element.addEventListener('pointerup', up);
    element.addEventListener('pointercancel', up);
    element.addEventListener('touchstart', down, { passive: false });
    element.addEventListener('touchmove', move, { passive: false });
    element.addEventListener('touchend', up);
    element.addEventListener('wheel', (event) => {
      if (!this.orbit) return;
      event.preventDefault();
      this.orbit.distance = clamp(this.orbit.distance * (1 + event.deltaY * 0.0016), 8, 4000);
      this.updateCamera();
    }, { passive: false });

    element.addEventListener('dblclick', () => {
      if (!this.building) return;
      this.frameCamera(this.building.height ?? 30, 30);
    });
  }

  observeSize() {
    const resize = () => {
      const width = this.container.clientWidth || 320;
      const height = this.container.clientHeight || 320;
      this.renderer.setSize(width, height, false);
      this.camera.aspect = width / Math.max(height, 1);
      this.camera.updateProjectionMatrix();
      this.needsRender = true;
    };
    resize();
    this.resizeObserver = new ResizeObserver(resize);
    this.resizeObserver.observe(this.container);
  }

  /**
   * Renders only when something has changed.
   *
   * A structural diagram that is not moving does not need sixty redraws a
   * second, and on a phone that difference is most of the warmth in the case.
   */
  loop() {
    const frame = () => {
      if (this.disposed) return;
      this.raf = requestAnimationFrame(frame);

      if (this.modeShape) {
        const t = (performance.now() - this.modeStartedAt) / 1000;
        const wave = Math.sin(t * 2.2) * this.modeAmplitude;
        for (let i = 0; i < this.storeys.length; i += 1) {
          this.storeys[i].position.x = (this.modeShape[i] ?? 0) * wave * this.exaggeration * 0.05;
        }
        this.needsRender = true;
      }

      if (this.constructionStartedAt) {
        const elapsed = (performance.now() - this.constructionStartedAt) / 1000;
        let settled = true;
        for (let i = 0; i < this.storeys.length; i += 1) {
          const progress = clamp((elapsed - i * 0.055) / 0.28, 0, 1);
          const eased = 1 - (1 - progress) ** 3;
          this.storeys[i].scale.setScalar(Math.max(eased, 0.001));
          if (progress < 1) settled = false;
        }
        this.needsRender = true;
        if (settled) this.constructionStartedAt = null;
      }

      if (this.needsRender) {
        this.needsRender = false;
        this.renderer.render(this.scene, this.camera);
      }
    };
    frame();
  }

  /** Releases the GPU resources. Not optional — WebGL contexts are limited. */
  dispose() {
    this.disposed = true;
    if (this.raf) cancelAnimationFrame(this.raf);
    this.resizeObserver?.disconnect();
    for (const storey of this.storeys) {
      storey.geometry.dispose();
      storey.material.dispose();
    }
    this.ground?.geometry.dispose();
    this.ground?.material.dispose();
    this.renderer.dispose();
    this.renderer.domElement.remove();
  }
}

function damageIndex(drift, system) {
  const thresholds = {
    momentFrame: [0.004, 0.008, 0.020, 0.050],
    bracedFrame: [0.003, 0.006, 0.015, 0.040],
    shearWall: [0.002, 0.005, 0.012, 0.030],
    dualSystem: [0.003, 0.007, 0.017, 0.045],
    baseIsolated: [0.005, 0.010, 0.025, 0.060],
    softStorey: [0.003, 0.006, 0.014, 0.030],
    unreinforced: [0.001, 0.003, 0.007, 0.015],
  }[system] ?? [0.004, 0.008, 0.020, 0.050];

  for (let i = thresholds.length - 1; i >= 0; i -= 1) {
    if (drift >= thresholds[i]) return i + 1;
  }
  return 0;
}

function touchDistance(event) {
  const [a, b] = event.touches;
  return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
}

function clamp(value, low, high) {
  return Math.min(Math.max(value, low), high);
}
