// Linear algebra, kept deliberately small.
//
// Only what the structural solver actually needs: an LU factorisation that can
// be reused across thousands of time steps, and a symmetric eigensolver. The
// reuse is the whole point — Newmark integration solves the same effective
// stiffness matrix at every step, and factorising it once instead of every step
// is the difference between a solve that takes a moment and one that hangs.

/** Dense LU with partial pivoting. Returns null for a singular matrix. */
export function factorise(matrix) {
  const n = matrix.length;
  if (n === 0) return null;

  // Copy: the caller's matrix is theirs, and an in-place factorisation that
  // silently destroys the input is a trap.
  const lu = matrix.map((row) => Float64Array.from(row));
  const pivot = new Int32Array(n);
  for (let i = 0; i < n; i += 1) pivot[i] = i;

  for (let column = 0; column < n; column += 1) {
    let best = column;
    let bestValue = Math.abs(lu[column][column]);
    for (let row = column + 1; row < n; row += 1) {
      const value = Math.abs(lu[row][column]);
      if (value > bestValue) {
        best = row;
        bestValue = value;
      }
    }
    // A pivot this small means the matrix is singular to working precision.
    // Returning null lets the caller fall back rather than propagating
    // infinities into a safety verdict.
    if (bestValue < 1e-14) return null;

    if (best !== column) {
      const swap = lu[best];
      lu[best] = lu[column];
      lu[column] = swap;
      const p = pivot[best];
      pivot[best] = pivot[column];
      pivot[column] = p;
    }

    const diagonal = lu[column][column];
    for (let row = column + 1; row < n; row += 1) {
      const factor = lu[row][column] / diagonal;
      lu[row][column] = factor;
      if (factor === 0) continue;
      for (let k = column + 1; k < n; k += 1) {
        lu[row][k] -= factor * lu[column][k];
      }
    }
  }

  return { lu, pivot, n };
}

/** Forward then back substitution against an existing factorisation. */
export function solveFactorised(factorisation, rhs) {
  if (!factorisation) return null;
  const { lu, pivot, n } = factorisation;
  if (rhs.length !== n) return null;

  const y = new Float64Array(n);
  for (let i = 0; i < n; i += 1) {
    let sum = rhs[pivot[i]];
    for (let j = 0; j < i; j += 1) sum -= lu[i][j] * y[j];
    y[i] = sum;
  }

  const x = new Float64Array(n);
  for (let i = n - 1; i >= 0; i -= 1) {
    let sum = y[i];
    for (let j = i + 1; j < n; j += 1) sum -= lu[i][j] * x[j];
    x[i] = sum / lu[i][i];
  }

  for (let i = 0; i < n; i += 1) {
    if (!Number.isFinite(x[i])) return null;
  }
  return x;
}

/** One-shot solve. Convenience only; the solver reuses a factorisation. */
export function solve(matrix, rhs) {
  return solveFactorised(factorise(matrix), rhs);
}

/**
 * Cyclic Jacobi eigendecomposition for a symmetric matrix.
 *
 * Returns eigenvalues ascending with their eigenvectors as columns. Jacobi
 * rather than anything cleverer because the matrices here are small, it is
 * unconditionally stable for symmetric input, and it needs no external library
 * — which matters when the alternative is shipping a linear algebra package to
 * a phone to decompose an 8x8.
 */
export function symmetricEigen(matrix, { sweeps = 60, tolerance = 1e-12 } = {}) {
  const n = matrix.length;
  if (n === 0) return { values: [], vectors: [] };

  const a = matrix.map((row) => Float64Array.from(row));
  const v = Array.from({ length: n }, (_, i) => {
    const row = new Float64Array(n);
    row[i] = 1;
    return row;
  });

  for (let sweep = 0; sweep < sweeps; sweep += 1) {
    let offDiagonal = 0;
    for (let p = 0; p < n; p += 1) {
      for (let q = p + 1; q < n; q += 1) offDiagonal += a[p][q] * a[p][q];
    }
    if (offDiagonal <= tolerance) break;

    let rotated = false;
    for (let p = 0; p < n - 1; p += 1) {
      for (let q = p + 1; q < n; q += 1) {
        if (Math.abs(a[p][q]) < 1e-18) continue;
        rotated = true;

        const theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
        const t = Math.sign(theta || 1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
        const c = 1 / Math.sqrt(t * t + 1);
        const s = t * c;

        for (let k = 0; k < n; k += 1) {
          const akp = a[k][p];
          const akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (let k = 0; k < n; k += 1) {
          const apk = a[p][k];
          const aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (let k = 0; k < n; k += 1) {
          const vkp = v[k][p];
          const vkq = v[k][q];
          v[k][p] = c * vkp - s * vkq;
          v[k][q] = s * vkp + c * vkq;
        }
      }
    }
    // Nothing rotated: already diagonal to working precision. Continuing would
    // burn the remaining sweeps to no effect.
    if (!rotated) break;
  }

  const order = Array.from({ length: n }, (_, i) => i)
    .sort((x, y) => a[x][x] - a[y][y]);

  return {
    values: order.map((i) => a[i][i]),
    vectors: order.map((i) => Array.from({ length: n }, (_, row) => v[row][i])),
  };
}

/** Matrix times vector. */
export function multiply(matrix, vector) {
  const out = new Float64Array(matrix.length);
  for (let i = 0; i < matrix.length; i += 1) {
    let sum = 0;
    const row = matrix[i];
    for (let j = 0; j < row.length; j += 1) sum += row[j] * vector[j];
    out[i] = sum;
  }
  return out;
}

export function dot(a, b) {
  let sum = 0;
  for (let i = 0; i < a.length; i += 1) sum += a[i] * b[i];
  return sum;
}

export function norm(vector) {
  return Math.sqrt(dot(vector, vector));
}
