// aes.js -- AES-128 in the browser: an independent reference for the FPGA.
//
// Same construction as model/aes_golden.py: the S-box is computed from its
// algebraic definition, not typed in, so a match with the FPGA is a genuine
// cross-check. Bytes are flat 16-element arrays in FIPS-197 order
// (byte i = state[i % 4][i / 4]), which is also the hex-string order.

const rotl8 = (x, s) => ((x << s) | (x >>> (8 - s))) & 0xff;

export const SBOX = new Uint8Array(256);
export const INV_SBOX = new Uint8Array(256);
(function buildSbox() {
  // walk GF(2^8)* with generator 3, tracking its inverse alongside
  let p = 1, q = 1;
  do {
    p = p ^ ((p << 1) & 0xff) ^ (p & 0x80 ? 0x1b : 0);
    q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xff;
    if (q & 0x80) q ^= 0x09;
    const x = q ^ rotl8(q, 1) ^ rotl8(q, 2) ^ rotl8(q, 3) ^ rotl8(q, 4);
    SBOX[p] = (x ^ 0x63) & 0xff;
  } while (p !== 1);
  SBOX[0] = 0x63;
  for (let i = 0; i < 256; i++) INV_SBOX[SBOX[i]] = i;
})();

const xtime = (b) => ((b << 1) ^ (b & 0x80 ? 0x1b : 0)) & 0xff;
function gmul(a, b) {
  let p = 0;
  for (let i = 0; i < 8; i++) {
    if (b & 1) p ^= a;
    a = xtime(a);
    b >>= 1;
  }
  return p;
}

export function expandKey(key) {
  const w = [];
  for (let i = 0; i < 4; i++) w.push([key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]);
  let rcon = 1;
  for (let i = 4; i < 44; i++) {
    let t = w[i - 1].slice();
    if (i % 4 === 0) {
      t = [t[1], t[2], t[3], t[0]].map((b) => SBOX[b]);
      t[0] ^= rcon;
      rcon = xtime(rcon);
    }
    w.push(w[i - 4].map((b, j) => b ^ t[j]));
  }
  const rk = [];
  for (let r = 0; r < 11; r++) rk.push(Uint8Array.from([].concat(w[4 * r], w[4 * r + 1], w[4 * r + 2], w[4 * r + 3])));
  return rk;
}

const subBytes = (s) => s.map((b) => SBOX[b]);
const invSubBytes = (s) => s.map((b) => INV_SBOX[b]);
// out[r + 4c] = in[r + 4((c + r) % 4)]
const shiftRows = (s) => { const o = new Uint8Array(16); for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) o[r + 4 * c] = s[r + 4 * ((c + r) % 4)]; return o; };
const invShiftRows = (s) => { const o = new Uint8Array(16); for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) o[r + 4 * ((c + r) % 4)] = s[r + 4 * c]; return o; };
function mixColumns(s) {
  const o = new Uint8Array(16);
  for (let c = 0; c < 4; c++) {
    const [a0, a1, a2, a3] = s.slice(4 * c, 4 * c + 4);
    o[4 * c]     = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
    o[4 * c + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
    o[4 * c + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
    o[4 * c + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
  }
  return o;
}
function invMixColumns(s) {
  const o = new Uint8Array(16);
  for (let c = 0; c < 4; c++) {
    const [a0, a1, a2, a3] = s.slice(4 * c, 4 * c + 4);
    o[4 * c]     = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
    o[4 * c + 1] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
    o[4 * c + 2] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
    o[4 * c + 3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
  }
  return o;
}
const xor16 = (a, b) => a.map((x, i) => x ^ b[i]);

// Encrypt one block. With trace = true, returns every intermediate state:
// rounds[0] is the initial AddRoundKey, rounds[1..10] the ten rounds.
export function encryptBlock(key, pt, trace = false, rk = null) {
  rk = rk || expandKey(key);
  let s = xor16(Uint8Array.from(pt), rk[0]);
  const rounds = trace ? [{ input: Uint8Array.from(pt), key: rk[0], out: s }] : null;
  for (let r = 1; r <= 10; r++) {
    const start = s;
    const sb = subBytes(s);
    const sr = shiftRows(sb);
    const mc = r < 10 ? mixColumns(sr) : null;
    s = xor16(mc || sr, rk[r]);
    if (trace) rounds.push({ start, sub: sb, shift: sr, mix: mc, key: rk[r], out: s });
  }
  return trace ? { ct: s, rounds } : s;
}

export function decryptBlock(rk, ct) {
  let s = xor16(Uint8Array.from(ct), rk[10]);
  for (let r = 9; r >= 0; r--) {
    s = invSubBytes(invShiftRows(s));
    s = xor16(s, rk[r]);
    if (r > 0) s = invMixColumns(s);
  }
  return s;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
export const toHex = (u8) => Array.from(u8, (b) => b.toString(16).padStart(2, "0")).join("");
export function fromHex(h) {
  h = h.replace(/[^0-9a-f]/gi, "");
  if (h.length % 2) h = "0" + h;
  return Uint8Array.from(h.match(/../g) || [], (x) => parseInt(x, 16));
}
export const isHex32 = (h) => /^[0-9a-f]{32}$/i.test(h.replace(/\s/g, ""));
export function randomBytes(n) { const b = new Uint8Array(n); crypto.getRandomValues(b); return b; }
export function bytesToBig(u8) { let v = 0n; for (const b of u8) v = (v << 8n) | BigInt(b); return v; }
export function bigToBytes(v, n = 16) {
  const o = new Uint8Array(n);
  v &= (1n << BigInt(8 * n)) - 1n;
  for (let i = n - 1; i >= 0; i--) { o[i] = Number(v & 0xffn); v >>= 8n; }
  return o;
}

// PKCS#7 for text that does not fill whole blocks
export function pad(u8) {
  const n = 16 - (u8.length % 16);
  const o = new Uint8Array(u8.length + n);
  o.set(u8);
  o.fill(n, u8.length);
  return o;
}
export function unpad(u8) {
  const n = u8[u8.length - 1];
  if (n < 1 || n > 16) return u8;
  for (let i = u8.length - n; i < u8.length; i++) if (u8[i] !== n) return u8;
  return u8.slice(0, u8.length - n);
}

// XOR of E(key, seed + i) for i < n, via WebCrypto AES-CTR (its keystream is
// exactly those blocks). Used to check the FPGA's benchmark checksum.
export async function ctrXorChecksum(key, seed, n, onProgress) {
  const k = await crypto.subtle.importKey("raw", key, "AES-CTR", false, ["encrypt"]);
  const acc = new Uint8Array(16);
  const CHUNK = 1 << 18;                        // 4 MiB per call
  let ctr = bytesToBig(seed);
  for (let done = 0; done < n; ) {
    const m = Math.min(CHUNK, n - done);
    const ks = new Uint8Array(await crypto.subtle.encrypt(
      { name: "AES-CTR", counter: bigToBytes(ctr), length: 128 }, k, new Uint8Array(16 * m)));
    const w = new Uint32Array(ks.buffer);
    const a = new Uint32Array(4);
    for (let i = 0; i < w.length; i += 4) { a[0] ^= w[i]; a[1] ^= w[i + 1]; a[2] ^= w[i + 2]; a[3] ^= w[i + 3]; }
    const ab = new Uint8Array(a.buffer);
    for (let i = 0; i < 16; i++) acc[i] ^= ab[i];
    ctr += BigInt(m);
    done += m;
    if (onProgress) onProgress(done / n);
  }
  return acc;
}

// Known-answer tests: FIPS-197 App. B / C.1, SP 800-38A ECB, AESAVS
export const KAT = [
  ["FIPS-197 App. B",   "2b7e151628aed2a6abf7158809cf4f3c", "3243f6a8885a308d313198a2e0370734", "3925841d02dc09fbdc118597196a0b32"],
  ["FIPS-197 App. C.1", "000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff", "69c4e0d86a7b0430d8cdb78070b4c55a"],
  ["SP 800-38A ECB #1", "2b7e151628aed2a6abf7158809cf4f3c", "6bc1bee22e409f96e93d7e117393172a", "3ad77bb40d7a3660a89ecaf32466ef97"],
  ["SP 800-38A ECB #2", "2b7e151628aed2a6abf7158809cf4f3c", "ae2d8a571e03ac9c9eb76fac45af8e51", "f5d3d58503b9699de785895a96fdbaaf"],
  ["SP 800-38A ECB #3", "2b7e151628aed2a6abf7158809cf4f3c", "30c81c46a35ce411e5fbc1191a0a52ef", "43b1cd7f598ece23881b00e3ed030688"],
  ["SP 800-38A ECB #4", "2b7e151628aed2a6abf7158809cf4f3c", "f69f2445df4f9b17ad2b417be66c3710", "7b0c785e27e8ad3f8223207104725dd4"],
  ["AESAVS all-zero",   "00000000000000000000000000000000", "00000000000000000000000000000000", "66e94bd4ef8a2c3b884cfa59ca342b2e"],
  ["AESAVS all-ones key","ffffffffffffffffffffffffffffffff", "00000000000000000000000000000000", "a1f6258c877d5fcd8964484538bfc92c"],
];

// self-check on load: the model must reproduce every published vector
export const MODEL_OK = KAT.every(([, k, p, c]) => toHex(encryptBlock(fromHex(k), fromHex(p))) === c)
  && toHex(decryptBlock(expandKey(fromHex(KAT[1][1])), fromHex(KAT[1][3]))) === KAT[1][2];
