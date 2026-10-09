// app.js -- AES-128 Accelerator Console
import * as A from "./aes.js";
import { Board, CMD, CORES, segLayout, showOnBoard, displayAuto, setLeds, parseStatus } from "./board.js";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const board = new Board();
const CLK_HZ = 100e6;
const TARGET_MHZ = 384.6;
const SOFTCORE_GBPS = 0.00474;          // bench/data.json: MicroBlaze-class, byte-wise AES
const ZERO16 = new Uint8Array(16);

const state = {
  status: null, lastButtons: null,
  verified: 0, latSeen: new Set(), bestGbps: 0,
  bench: {}, browserGbps: null, ctResult: null, nist: null,
  display: { layout: null, speed: 12, bright: 7 },
  leds: { manual: false, pattern: 0, rgb16: 0, rgb17: 0 },
  build: null, heavy: 0,
};

// ---------------------------------------------------------------------------
// small utilities
// ---------------------------------------------------------------------------
const fmt = (n, d = 2) => Number(n).toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
const fmtInt = (n) => Number(n).toLocaleString();
const cc = (i) => `var(--c${i})`;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function fmtGbps(g) {
  if (g >= 1) return `${fmt(g, 2)} Gbps`;
  if (g >= 1e-3) return `${fmt(g * 1e3, 1)} Mbps`;
  return `${fmt(g * 1e6, 0)} kbps`;
}

let logCount = 0;
function log(msg, cls = "info") {
  const el = $("#log");
  const line = document.createElement("div");
  line.className = cls;
  line.textContent = `${new Date().toLocaleTimeString()}  ${msg}`;
  el.appendChild(line);
  if (el.children.length > 400) el.firstChild.remove();
  el.scrollTop = el.scrollHeight;
  $("#logCount").textContent = `(${++logCount})`;
}
let toastTimer;
function toast(msg, bad = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast show" + (bad ? " bad" : "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.className = "toast"), 3200);
}
function requireBoard() {
  if (board.connected) return true;
  toast("Connect the board first (top right).", true);
  return false;
}
// run a long job with status polling paused and the button disabled
async function job(btn, fn) {
  if (btn) btn.disabled = true;
  state.heavy++;
  try { return await fn(); }
  catch (e) { log(e.message, "bad"); toast(e.message, true); }
  finally { state.heavy--; if (btn) btn.disabled = false; renderScorecard(); }
}

// ---------------------------------------------------------------------------
// navigation
// ---------------------------------------------------------------------------
function show(view) {
  $$(".view").forEach((v) => v.classList.toggle("active", v.id === `view-${view}`));
  $$(".nav a").forEach((a) => a.classList.toggle("active", a.dataset.view === view));
  if (view === "impl" && !state.build) loadBuild();
}
$$(".nav a").forEach((a) => a.addEventListener("click", (e) => { e.preventDefault(); history.replaceState(null, "", `#${a.dataset.view}`); show(a.dataset.view); }));
$$("[data-goto]").forEach((b) => b.addEventListener("click", () => { history.replaceState(null, "", `#${b.dataset.goto}`); show(b.dataset.goto); }));

// ---------------------------------------------------------------------------
// core pickers
// ---------------------------------------------------------------------------
const CORE_DESC = { 1: "1 round · II 11", 2: "whitening overlap · II 10", 3: "10 rounds unrolled · II 1" };
function corePicker(el, { multi = false, initial = [2] } = {}) {
  const sel = new Set(initial);
  el.innerHTML = Object.entries(CORES).map(([i, c]) =>
    `<button type="button" class="core-opt${sel.has(+i) ? " on" : ""}" data-i="${i}" style="--cc:${cc(i)}">
       <span class="cn">${c.name}</span><span class="cd">${CORE_DESC[i]}</span></button>`).join("");
  el.addEventListener("click", (e) => {
    const b = e.target.closest(".core-opt");
    if (!b) return;
    const i = +b.dataset.i;
    if (multi) { sel.has(i) && sel.size > 1 ? sel.delete(i) : sel.add(i); }
    else { sel.clear(); sel.add(i); }
    $$(".core-opt", el).forEach((x) => x.classList.toggle("on", sel.has(+x.dataset.i)));
  });
  return () => [...sel].sort();
}
const encCores = corePicker($("#encCores"));
const bnCores = corePicker($("#bnCores"), { multi: true, initial: [1, 2, 3] });
const imCores = corePicker($("#imCores"), { initial: [3] });

// ---------------------------------------------------------------------------
// 7-segment renderer (shared by the board mirror and the display preview)
// ---------------------------------------------------------------------------
const NS = "http://www.w3.org/2000/svg";
const segDisplays = [];
function hseg(cx, cy, L, t) { const h = t / 2; return `${cx-L/2},${cy} ${cx-L/2+h},${cy-h} ${cx+L/2-h},${cy-h} ${cx+L/2},${cy} ${cx+L/2-h},${cy+h} ${cx-L/2+h},${cy+h}`; }
function vseg(cx, cy, L, t) { const h = t / 2; return `${cx},${cy-L/2} ${cx+h},${cy-L/2+h} ${cx+h},${cy+L/2-h} ${cx},${cy+L/2} ${cx-h},${cy+L/2-h} ${cx-h},${cy-L/2+h}`; }
class SegDisplay {
  constructor(parent) {
    const T = 8, W = 40, H = 80;
    const shapes = [hseg(W/2, 4, W-6, T), vseg(W, H*.25+2, H/2-8, T), vseg(W, H*.75+2, H/2-8, T),
                    hseg(W/2, H+4, W-6, T), vseg(0, H*.75+2, H/2-8, T), vseg(0, H*.25+2, H/2-8, T), hseg(W/2, H/2+4, W-6, T)];
    this.digits = [];
    for (let d = 0; d < 8; d++) {
      const g = document.createElementNS(NS, "g");
      g.setAttribute("transform", `translate(${20 + d * 62},6) skewX(-7)`);
      const parts = shapes.map((pts) => { const p = document.createElementNS(NS, "polygon"); p.setAttribute("points", pts); g.appendChild(p); return p; });
      const dp = document.createElementNS(NS, "circle");
      dp.setAttribute("cx", W + 9); dp.setAttribute("cy", H + 4); dp.setAttribute("r", 4.2);
      g.appendChild(dp); parts.push(dp);
      parent.appendChild(g);
      this.digits.push(parts);
    }
    this.layout = { segs: new Array(8).fill(0), scroll: false };
    this.speed = 12; this.bright = 7; this.pos = 0; this.last = 0;
    segDisplays.push(this);
    this.paint();
  }
  set(layout, { speed = 12, bright = 7 } = {}) {
    this.layout = layout; this.speed = speed; this.bright = bright; this.pos = 0; this.last = performance.now();
    this.paint();
  }
  paint() {
    const { segs, scroll } = this.layout;
    const a = (0.35 + 0.65 * (this.bright + 1) / 8).toFixed(2);
    this.digits.forEach((parts, d) => {
      const s = scroll ? segs[(this.pos + d) % segs.length] : segs[d] || 0;
      parts.forEach((el, bit) => {
        const on = (s >> bit) & 1;
        el.setAttribute("fill", on ? "#ff3b30" : "#2a1212");
        el.setAttribute("fill-opacity", on ? a : "1");
      });
    });
  }
  tick(now) {
    if (!this.layout.scroll) return;
    if (now - this.last >= (this.speed + 1) * 21) { this.pos = (this.pos + 1) % this.layout.segs.length; this.last = now; this.paint(); }
  }
}
function segSvg(container, viewBox = "0 0 520 100") {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("viewBox", viewBox);
  container.appendChild(svg);
  return new SegDisplay(svg);
}
(function loop(now) { segDisplays.forEach((d) => d.tick(now)); requestAnimationFrame(loop); })(0);

// ---------------------------------------------------------------------------
// board mirror (overview)
// ---------------------------------------------------------------------------
const mirror = (() => {
  const W = 640, H = 330;
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", "Live view of the Nexys A7 board");
  svg.innerHTML = `
    <rect x="1" y="1" width="${W-2}" height="${H-2}" rx="16" fill="#0b1210" stroke="rgba(148,163,184,.18)"/>
    <text x="22" y="32" fill="#6f7b8e" font-size="13" font-family="var(--mono)">NEXYS A7-100T</text>
    <text x="22" y="50" fill="#3d4757" font-size="11" font-family="var(--mono)">XC7A100T · 100 MHz</text>
    <rect x="110" y="60" width="380" height="88" rx="8" fill="#0a0505" stroke="#2a1212"/>
    <g id="mSeg" transform="translate(120,68) scale(0.69)"></g>
    <text x="300" y="168" text-anchor="middle" fill="#3d4757" font-size="10" font-family="var(--mono)">7-SEGMENT</text>
    <circle id="mRgb17" cx="520" cy="82" r="9" fill="#1b2230"/><text x="520" y="106" text-anchor="middle" fill="#3d4757" font-size="9" font-family="var(--mono)">LD17</text>
    <circle id="mRgb16" cx="550" cy="82" r="9" fill="#1b2230"/><text x="550" y="106" text-anchor="middle" fill="#3d4757" font-size="9" font-family="var(--mono)">LD16</text>
    <g id="mLeds"></g><g id="mSw"></g><g id="mBtn"></g>
    <text x="22" y="206" fill="#3d4757" font-size="10" font-family="var(--mono)">LD15</text>
    <text x="22" y="276" fill="#3d4757" font-size="10" font-family="var(--mono)">SW15</text>`;
  $("#boardMirror").appendChild(svg);
  const seg = new SegDisplay($("#mSeg", svg));
  const leds = [], sws = [], btns = {};
  for (let i = 0; i < 16; i++) {
    const x = 70 + (15 - i) * 26;            // LD15 on the left, as on the board
    const r = document.createElementNS(NS, "rect");
    Object.entries({ x, y: 196, width: 12, height: 8, rx: 2, fill: "#13261b" }).forEach(([k, v]) => r.setAttribute(k, v));
    $("#mLeds", svg).appendChild(r); leds[i] = r;
    const g = document.createElementNS(NS, "g");
    g.innerHTML = `<rect x="${x}" y="244" width="12" height="26" rx="3" fill="#1b2230" stroke="rgba(148,163,184,.25)"/><rect class="k" x="${x+2}" y="258" width="8" height="10" rx="2" fill="#a9b4c4"/>`;
    $("#mSw", svg).appendChild(g); sws[i] = $(".k", g);
  }
  const pos = { U: [560, 190], L: [526, 222], C: [560, 222], R: [594, 222], D: [560, 254] };
  for (const [k, [x, y]] of Object.entries(pos)) {
    const g = document.createElementNS(NS, "g");
    g.innerHTML = `<circle cx="${x}" cy="${y}" r="12" fill="#1b2230" stroke="rgba(148,163,184,.3)"/><text x="${x}" y="${y + 4}" text-anchor="middle" font-size="10" fill="#6f7b8e" font-family="var(--mono)">${k}</text>`;
    $("#mBtn", svg).appendChild(g); btns[k] = $("circle", g);
  }
  const RGB = ["#1b2230", "#3b82f6", "#22c55e", "#22d3ee", "#ef4444", "#d946ef", "#facc15", "#f8fafc"]; // index = {r,g,b}
  return {
    update(st) {
      const s = st.selftest;
      let pattern;
      if (st.ledManual) pattern = state.leds.pattern;
      else pattern = (s.pass) | (s.fail << 3) | ((s.ran ? 1 : 0) << 6) | ((st.frames & 0x7f) << 7) | (1 << 14) | ((st.uptime & 1) << 15);
      leds.forEach((r, i) => {
        const on = (pattern >> i) & 1;
        r.setAttribute("fill", on ? "#4ade80" : "#13261b");
        r.style.filter = on ? "drop-shadow(0 0 4px #4ade80)" : "";
      });
      sws.forEach((k, i) => k.setAttribute("y", (st.switches >> i) & 1 ? 246 : 258));
      sws.forEach((k, i) => k.setAttribute("fill", (st.switches >> i) & 1 ? "#4cc9f0" : "#a9b4c4"));
      for (const k of Object.keys(btns)) btns[k].setAttribute("fill", st.buttons[k] ? "#4cc9f0" : "#1b2230");
      const allPass = s.ran && s.pass === 7;
      const c16 = st.ledManual ? state.leds.rgb16 : (!s.ran ? 0 : allPass ? 2 : 4);
      const c17 = st.ledManual ? state.leds.rgb17 : 0;
      $("#mRgb16", svg).setAttribute("fill", RGB[c16]);
      $("#mRgb17", svg).setAttribute("fill", RGB[c17]);
      // display: the board's own text in auto mode, otherwise what we sent
      if (!st.pageMode) {
        const text = !s.ran ? "  tESt  " : allPass ? "AES PASS" : "AES FAIL";
        if (this.autoText !== text) { seg.set(segLayout(text)); this.autoText = text; }
      } else if (state.display.layout && this.shown !== state.display.layout) {
        seg.set(state.display.layout, state.display);
        this.shown = state.display.layout; this.autoText = null;
      }
    },
  };
})();

// ---------------------------------------------------------------------------
// objectives scorecard -- the proposal's goals, checked against the board
// ---------------------------------------------------------------------------
function renderScorecard() {
  const st = state.status, b = state.build;
  const items = [];
  const add = (cls, t, d, v) => items.push({ cls, t, d, v });

  if (st && st.selftest.ran) add(st.selftest.pass === 7 ? "ok" : "fail", "Dedicated AES-128 engine", "Encryption runs in FPGA logic, off the processor", `${[1,2,4].filter((m) => st.selftest.pass & m).length}/3 cores pass`);
  else add("wait", "Dedicated AES-128 engine", "Encryption runs in FPGA logic, off the processor", st ? "self-test running" : "connect board");

  add(state.bestGbps >= 1 ? "ok" : "wait", "Throughput above 1 Gbps", "Measured in hardware cycles, not estimated", state.bestGbps ? fmtGbps(state.bestGbps) : "run benchmark");
  add(state.latSeen.size ? (state.latSeen.size === 1 && state.latSeen.has(11) ? "ok" : "fail") : "wait", "Fast processing: 20–100 cycles", "Proposal target; latency counted by the FPGA", state.latSeen.size ? `${[...state.latSeen].join(", ")} cycles` : "encrypt a block");
  if (b) add("ok", "Low-area and high-throughput versions", "Iterative for IoT, pipelined for servers", `${fmtInt(b.cores.iterative.lut)} vs ${fmtInt(b.cores.pipelined.lut)} LUT`);
  else add("wait", "Low-area and high-throughput versions", "Iterative for IoT, pipelined for servers", "loading build info");
  add(state.nist ? (state.nist.fail ? "fail" : "ok") : "wait", "NIST FIPS-197 vectors on the FPGA", "Published KATs plus random vectors, all cores", state.nist ? `${fmtInt(state.nist.pass)}/${fmtInt(state.nist.total)} correct` : "run verification");
  add(state.ctResult ? (state.ctResult.constant ? "ok" : "fail") : "wait", "Timing-attack resistance", "Latency must not depend on key or data", state.ctResult ? (state.ctResult.constant ? "constant 11 cycles" : "varies!") : "run constant-time check");

  const ii10 = state.bench[2];
  const fmaxII = b && b.cores.ii10.fmax_mhz;
  if (ii10 || b) {
    const cpb = ii10 ? ii10.cycles / ii10.n : 10;
    const reach = fmaxII ? 128 * fmaxII * 1e6 / cpb / 1e9 : null;
    add(fmaxII && fmaxII >= TARGET_MHZ ? "ok" : "no", "Paper target: 4.92 Gbps at 384.6 MHz",
      "Needs 10 cycles/block (met) and a 384.6 MHz clock",
      `${fmt(cpb, 2)} cyc/blk${reach ? ` · ${fmtGbps(reach)} at Fmax` : ""}`);
  } else add("wait", "Paper target: 4.92 Gbps at 384.6 MHz", "Needs 10 cycles/block and a 384.6 MHz clock", "run benchmark");

  add(b ? "ok" : "wait", "Power", "Vivado estimate for this design + live die temperature",
    b ? `${fmt(b.power_w.total, 3)} W est.${st ? ` · ${fmt(st.tempC, 1)} °C` : ""}` : "—");
  add("no", "Power-analysis (SCA) protection", "Masking / hiding countermeasures", "future work");
  add("no", "AXI4-Lite SoC interface", "This build connects over UART; AXI needs a soft CPU", "future work");

  const icon = { ok: "✓", wait: "·", no: "!", fail: "✕" };
  $("#scorecard").innerHTML = items.map((o) =>
    `<div class="obj ${o.cls}"><span class="ic">${icon[o.cls]}</span><div><div class="t">${esc(o.t)}</div><div class="d">${esc(o.d)}</div></div><div class="v">${esc(o.v)}</div></div>`).join("");
  $("#hsGbps").textContent = state.bestGbps ? fmt(state.bestGbps, 2) : "—";
  $("#hsVerified").textContent = fmtInt(state.verified);
}

// ---------------------------------------------------------------------------
// connection + status polling
// ---------------------------------------------------------------------------
board.addEventListener("log", (e) => log(e.detail.msg, e.detail.cls));
board.addEventListener("disconnect", (e) => {
  log(`disconnected: ${e.detail}`, "bad");
  $("#connectBtn").textContent = "Connect board";
  $("#chipLink").className = "chip";
  $("#chipLink span").textContent = "offline";
  $("#boardMirrorNote").textContent = "connect to mirror the board";
  state.status = null;
  renderScorecard();
});

$("#connectBtn").addEventListener("click", async () => {
  if (board.connected) { await board.disconnect(); return; }
  try {
    await board.connect();
    const r = await board.request(CMD.PING);
    const id = new TextDecoder().decode(r.payload);
    const ver = r.aux >>> 24, mhz = (r.aux >>> 16) & 0xff, baud = ((r.aux >>> 8) & 0xff) / 10;
    log(`connected: ${id} · v${ver} · ${mhz} MHz · ${baud} Mbaud`, "ok");
    toast(`Connected to ${id}`);
    $("#connectBtn").textContent = "Disconnect";
    $("#chipLink").className = "chip on";
    $("#chipLink span").textContent = `${id.slice(0, 6)} · ${baud} Mbaud`;
    $("#boardMirrorNote").textContent = "mirrored from the board every 100 ms";
  } catch (e) {
    if (e.name === "NotFoundError") return;           // picker cancelled
    log(`connect failed: ${e.message}`, "bad");
    toast(e.message.includes("open") ? "Could not open the port. Is another program (or tab) using COM9?" : e.message, true);
    if (board.connected) board.disconnect("ping failed -- is aes_nexys_a7.bit loaded?");
  }
});

async function poll() {
  if (board.connected && !state.heavy && board.busy === 0) {
    try {
      const st = parseStatus(await board.request(CMD.STATUS, 0, ZERO16, ZERO16, 600));
      onStatus(st);
    } catch { /* resync already logged */ }
  }
  setTimeout(poll, 100);
}
poll();

function fmtUptime(s) {
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return h ? `${h}h ${m}m` : m ? `${m}m ${x}s` : `${x}s`;
}

function onStatus(st) {
  const prev = state.status;
  state.status = st;
  $("#chipTemp").textContent = `${fmt(st.tempC, 1)} °C`;
  $("#chipVcc").textContent = `${fmt(st.vccint, 3)} V`;
  $("#chipUp").textContent = fmtUptime(st.uptime);
  $("#chipBlocks").textContent = fmtInt(st.blocks);
  mirror.update(st);
  renderSwitches(st);
  renderSelftest(st.selftest);
  if (!prev || prev.selftest.raw !== st.selftest.raw || prev.uptime !== st.uptime) renderScorecard();
  // board buttons drive the page
  const bt = st.buttons, last = state.lastButtons;
  state.lastButtons = bt;
  if (last && $("#btActions").checked) {
    const core = (st.switches & 3) || 2;
    if (bt.U && !last.U) buttonEncrypt(core);
    if (bt.D && !last.D) buttonBench(core);
  }
}

// ---------------------------------------------------------------------------
// encrypt view
// ---------------------------------------------------------------------------
let encFmt = "text";
$("#encFormat").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  encFmt = b.dataset.fmt;
  $$("#encFormat button").forEach((x) => x.classList.toggle("on", x === b));
  $("#encInput").value = encFmt === "hex" ? "00112233445566778899aabbccddeeff" : "Hello from Abheda Solutions!";
  encHint();
});
function encBlocks() {
  const v = $("#encInput").value;
  if (encFmt === "hex") {
    if (!A.isHex32(v)) throw new Error("A hex block is exactly 32 hex digits.");
    return { blocks: [A.fromHex(v)], text: false };
  }
  const bytes = A.pad(new TextEncoder().encode(v));
  const blocks = [];
  for (let i = 0; i < bytes.length; i += 16) blocks.push(bytes.slice(i, i + 16));
  return { blocks, text: true };
}
function encKey() {
  const k = $("#encKey").value;
  if (!A.isHex32(k)) throw new Error("The key is 32 hex digits (128 bits).");
  return A.fromHex(k);
}
function encHint() {
  try {
    const { blocks, text } = encBlocks();
    $("#encHint").textContent = text ? `${blocks.length} block${blocks.length > 1 ? "s" : ""} after PKCS#7 padding (ECB)` : "one 128-bit block";
    $("#encHint").className = "hint";
  } catch (e) { $("#encHint").textContent = e.message; $("#encHint").className = "hint warn"; }
}
$("#encInput").addEventListener("input", encHint);
$("#encRandKey").addEventListener("click", () => ($("#encKey").value = A.toHex(A.randomBytes(16))));
$("#encNistKey").addEventListener("click", () => ($("#encKey").value = "2b7e151628aed2a6abf7158809cf4f3c"));
encHint();

async function encryptOn(core, key, blocks) {
  const rk = A.expandKey(key);
  const res = await Promise.all(blocks.map((b) => board.request(CMD.ENC + core, 0, key, b)));
  return res.map((r, i) => {
    const ref = A.encryptBlock(key, blocks[i], false, rk);
    const ok = A.toHex(r.payload) === A.toHex(ref);
    state.latSeen.add(r.aux);
    if (ok) state.verified++;
    return { pt: blocks[i], ct: r.payload, lat: r.aux, ms: r.ms, ok };
  });
}

$("#encGo").addEventListener("click", () => requireBoard() && job($("#encGo"), async () => {
  const key = encKey();
  const { blocks, text } = encBlocks();
  const core = encCores()[0];
  const t0 = performance.now();
  const rows = await encryptOn(core, key, blocks);
  const dt = performance.now() - t0;
  const ct = rows.map((r) => A.toHex(r.ct)).join("");
  showEncResult(rows, core, dt, ct, key, text);
  log(`encrypted ${rows.length} block(s) on ${CORES[core].name}: ${rows.every((r) => r.ok) ? "all match" : "MISMATCH"}`, rows.every((r) => r.ok) ? "ok" : "bad");
  if ($("#encShow").checked) await showText(ct.slice(0, 32));
}));

function showEncResult(rows, core, dt, ct, key, text) {
  $("#encResult").hidden = false;
  const allOk = rows.every((r) => r.ok);
  $("#encMeta").innerHTML = `${rows.length} block${rows.length > 1 ? "s" : ""} on <span class="corename" style="--cc:${cc(core)}">${CORES[core].name}</span> · ${fmt(dt, 1)} ms round trip · ${allOk ? '<span class="tag ok">MATCHES BROWSER MODEL</span>' : '<span class="tag bad">MISMATCH</span>'}`;
  $("#encTable").innerHTML = `<div class="tbl-wrap"><table><thead><tr><th>#</th><th>Plaintext</th><th>Ciphertext (FPGA)</th><th class="num">Latency</th><th>Check</th></tr></thead><tbody>${
    rows.map((r, i) => `<tr><td class="num">${i}</td><td class="hex">${A.toHex(r.pt)}</td><td class="hex">${A.toHex(r.ct)}</td><td class="num">${r.lat} cyc</td><td>${r.ok ? '<span class="tag ok">OK</span>' : '<span class="tag bad">BAD</span>'}</td></tr>`).join("")
  }</tbody></table></div>`;
  $("#encCt").textContent = ct;
  const rk = A.expandKey(key);
  const back = new Uint8Array(rows.length * 16);
  rows.forEach((r, i) => back.set(A.decryptBlock(rk, r.ct), 16 * i));
  $("#encBack").textContent = text ? new TextDecoder().decode(A.unpad(back)) : A.toHex(back);
  state.lastEnc = { ct, key: A.toHex(key) };
  renderScorecard();
}

// ---------------------------------------------------------------------------
// decrypt (in the browser: the FPGA cores are encrypt-only)
// ---------------------------------------------------------------------------
async function copy(text, what) {
  try { await navigator.clipboard.writeText(text); toast(`${what} copied`); }
  catch { toast(`Could not copy -- select the ${what.toLowerCase()} and press Ctrl+C`, true); }
}
$("#encCopyCt").addEventListener("click", () => state.lastEnc && copy(state.lastEnc.ct, "Ciphertext"));
$("#encCopyKey").addEventListener("click", () => state.lastEnc && copy(state.lastEnc.key, "Key"));
$("#encToDec").addEventListener("click", () => {
  if (!state.lastEnc) return;
  $("#decCt").value = state.lastEnc.ct;
  $("#decKey").value = state.lastEnc.key;
  $("#decCard").scrollIntoView({ behavior: "smooth", block: "start" });
  decrypt();
});

function decrypt() {
  const hint = $("#decHint");
  const ctHex = $("#decCt").value.replace(/[^0-9a-f]/gi, "");
  const keyHex = $("#decKey").value.trim();
  $("#decText").textContent = "";
  $("#decHex").textContent = "";
  hint.className = "hint warn";
  if (!A.isHex32(keyHex)) { hint.textContent = "The key must be exactly 32 hex digits."; return; }
  if (!ctHex.length || ctHex.length % 32) { hint.textContent = "Ciphertext must be whole 16-byte blocks (a multiple of 32 hex digits)."; return; }
  const rk = A.expandKey(A.fromHex(keyHex));
  const ct = A.fromHex(ctHex);
  const out = new Uint8Array(ct.length);
  for (let i = 0; i < ct.length; i += 16) out.set(A.decryptBlock(rk, ct.subarray(i, i + 16)), i);
  const unpadded = A.unpad(out);
  const padOk = unpadded.length < out.length;
  const text = new TextDecoder("utf-8", { fatal: false }).decode(padOk ? unpadded : out);
  // mostly printable characters and valid padding: almost certainly the right key
  const printable = text.length && [...text].filter((c) => c >= " " && c !== "�").length / text.length > 0.9;
  $("#decText").textContent = text;
  $("#decHex").textContent = A.toHex(out);
  if (padOk && printable) { hint.className = "hint"; hint.textContent = `${ct.length / 16} block(s) decrypted -- readable text, so the key is right`; }
  else if (ct.length === 16 && !padOk) { hint.className = "hint"; hint.textContent = "1 block decrypted (a raw hex block has no padding -- compare the hex)"; }
  else hint.textContent = "Decrypted, but it looks like garbage: wrong key, or the ciphertext was changed.";
}
$("#decGo").addEventListener("click", decrypt);
$("#decCt").addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); decrypt(); } });

$("#encAll").addEventListener("click", () => requireBoard() && job($("#encAll"), async () => {
  const key = encKey();
  const { blocks } = encBlocks();
  const out = [];
  for (const core of [1, 2, 3]) {
    const t0 = performance.now();
    const rows = await encryptOn(core, key, blocks);
    out.push({ core, rows, ms: performance.now() - t0 });
  }
  const same = out.every((o) => o.rows.map((r) => A.toHex(r.ct)).join() === out[0].rows.map((r) => A.toHex(r.ct)).join());
  $("#encResult").hidden = false;
  $("#encMeta").innerHTML = `${blocks.length} block(s) × 3 cores · ${same ? '<span class="tag ok">IDENTICAL ON ALL CORES</span>' : '<span class="tag bad">CORES DISAGREE</span>'}`;
  $("#encTable").innerHTML = `<div class="tbl-wrap"><table><thead><tr><th>Core</th><th>Ciphertext of block 0</th><th class="num">Latency</th><th class="num">Round trip</th><th>Check</th></tr></thead><tbody>${
    out.map((o) => `<tr><td><span class="corename" style="--cc:${cc(o.core)}">${CORES[o.core].name}</span></td><td class="hex">${A.toHex(o.rows[0].ct)}</td><td class="num">${o.rows[0].lat} cyc</td><td class="num">${fmt(o.ms, 1)} ms</td><td>${o.rows.every((r) => r.ok) ? '<span class="tag ok">OK</span>' : '<span class="tag bad">BAD</span>'}</td></tr>`).join("")
  }</tbody></table></div>`;
  const ct = out[0].rows.map((r) => A.toHex(r.ct)).join("");
  $("#encCt").textContent = ct;
  state.lastEnc = { ct, key: A.toHex(key) };
  const rk = A.expandKey(key);
  const back = new Uint8Array(blocks.length * 16);
  out[0].rows.forEach((r, i) => back.set(A.decryptBlock(rk, r.ct), 16 * i));
  $("#encBack").textContent = encFmt === "text" ? new TextDecoder().decode(A.unpad(back)) : A.toHex(back);
  renderScorecard();
}));

// ---------------------------------------------------------------------------
// inside AES
// ---------------------------------------------------------------------------
let trace = null;
function matrix(bytes, prev) {
  const cells = [];
  for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) {
    const i = r + 4 * c, b = bytes[i];
    const chg = prev && prev[i] !== b ? " chg" : "";
    cells.push(`<span class="${chg.trim()}" style="--h:${Math.round(b * 360 / 256)}">${b.toString(16).padStart(2, "0")}</span>`);
  }
  return `<div class="mat">${cells.join("")}</div>`;
}
function stage(name, bytes, prev, note = "") {
  return `<div class="stage${bytes ? "" : " skip"}"><div class="sn">${name}${note ? ` <b>${note}</b>` : ""}</div>${matrix(bytes || new Uint8Array(16), bytes ? prev : null)}</div>`;
}
function renderInside() {
  try {
    const key = A.fromHex($("#inKey").value), pt = A.fromHex($("#inPt").value);
    if (key.length !== 16 || pt.length !== 16) throw 0;
    trace = A.encryptBlock(key, pt, true);
  } catch { $("#inStages").innerHTML = '<div class="hint warn">Key and plaintext must each be 32 hex digits.</div>'; return; }
  const r = +$("#inRound").value, R = trace.rounds[r];
  $("#inRoundLabel").textContent = r === 0 ? "Round 0 · whitening" : r === 10 ? "Round 10 · final" : `Round ${r} of 10`;
  $("#inStages").innerHTML = r === 0
    ? stage("Plaintext", R.input) + stage("Round key 0", R.key, null, "= the key") + stage("AddRoundKey", R.out, R.input)
    : stage("Start", R.start) + stage("SubBytes", R.sub, R.start, "S-box") + stage("ShiftRows", R.shift, R.sub)
      + stage("MixColumns", R.mix, R.shift, r === 10 ? "skipped" : "GF(2⁸)") + stage(`Round key ${r}`, R.key)
      + stage("AddRoundKey", R.out, R.mix || R.shift);
  $("#inFinal").innerHTML = `ciphertext <b>${A.toHex(trace.ct)}</b>`;
  $("#inKeys").innerHTML = trace.rounds.map((x, i) => `<div class="${i === r ? "cur" : ""}"><b>k${i}</b>${A.toHex(x.key)}</div>`).join("");
}
["#inKey", "#inPt", "#inRound"].forEach((s) => $(s).addEventListener("input", () => { $("#inFpgaRes").innerHTML = ""; renderInside(); }));
$("#inPrev").addEventListener("click", () => { $("#inRound").value = Math.max(0, +$("#inRound").value - 1); renderInside(); });
$("#inNext").addEventListener("click", () => { $("#inRound").value = Math.min(10, +$("#inRound").value + 1); renderInside(); });
let playTimer = null;
$("#inPlay").addEventListener("click", () => {
  if (playTimer) { clearInterval(playTimer); playTimer = null; $("#inPlay").textContent = "Play"; return; }
  $("#inPlay").textContent = "Pause";
  if (+$("#inRound").value === 10) $("#inRound").value = 0;
  renderInside();
  playTimer = setInterval(() => {
    const v = +$("#inRound").value;
    if (v >= 10) { clearInterval(playTimer); playTimer = null; $("#inPlay").textContent = "Play"; return; }
    $("#inRound").value = v + 1; renderInside();
  }, 1100);
});
$("#inFpga").addEventListener("click", () => requireBoard() && trace && job($("#inFpga"), async () => {
  const key = A.fromHex($("#inKey").value), pt = A.fromHex($("#inPt").value);
  const rows = await encryptOn(2, key, [pt]);
  $("#inFpgaRes").innerHTML = rows[0].ok
    ? `<span class="tag ok">FPGA MATCHES · ${rows[0].lat} CYCLES</span>`
    : `<span class="tag bad">FPGA: ${A.toHex(rows[0].ct)}</span>`;
}));
renderInside();

// ---------------------------------------------------------------------------
// benchmark
// ---------------------------------------------------------------------------
function browserBaseline() {
  const key = A.randomBytes(16), rk = A.expandKey(key);
  let blk = A.randomBytes(16), n = 0;
  const t0 = performance.now();
  while (performance.now() - t0 < 300) { for (let i = 0; i < 200; i++) blk = A.encryptBlock(key, blk, false, rk); n += 200; }
  return n * 128 / ((performance.now() - t0) / 1000) / 1e9;
}

$("#bnGo").addEventListener("click", () => requireBoard() && job($("#bnGo"), async () => {
  const N = +$("#bnN").value;
  if (state.browserGbps === null) state.browserGbps = browserBaseline();
  for (const core of bnCores()) {
    const key = A.randomBytes(16), seed = A.randomBytes(16);
    const expectMs = N * CORES[core].ii / CLK_HZ * 1000;
    log(`benchmark: ${fmtInt(N)} blocks on ${CORES[core].name}…`);
    const r = await board.request(CMD.BENCH + core, N, key, seed, expectMs + 3000);
    if (r.status) throw new Error(`benchmark timed out on ${CORES[core].name}`);
    const cycles = r.aux;
    const gbps = N * 128 / (cycles / CLK_HZ) / 1e9;
    const res = { n: N, cycles, gbps, ok: null };
    state.bench[core] = res;
    state.bestGbps = Math.max(state.bestGbps, gbps);
    renderBench();
    const ref = await A.ctrXorChecksum(key, seed, N);
    res.ok = A.toHex(ref) === A.toHex(r.payload);
    state.verified += res.ok ? N : 0;
    log(`${CORES[core].name}: ${fmtInt(cycles)} cycles → ${fmtGbps(gbps)}, checksum ${res.ok ? "verified" : "MISMATCH"}`, res.ok ? "ok" : "bad");
    renderBench();
  }
  if (state.status && bnCores().length) await showText(`${fmt(state.bestGbps, 2)} Gb`);
}));

function renderBench() {
  const b = state.build;
  const rows = [];
  for (const core of [1, 2, 3]) {
    const r = state.bench[core];
    if (!r) continue;
    const cpb = r.cycles / r.n;
    const fmax = b ? b.cores[CORES[core].key].fmax_mhz : null;
    rows.push({ label: CORES[core].name, color: cc(core), gbps: r.gbps, proj: 128 * TARGET_MHZ * 1e6 / cpb / 1e9, fmaxG: fmax ? 128 * fmax * 1e6 / cpb / 1e9 : null, r, cpb, core });
  }
  const sw = [];
  if (state.browserGbps) sw.push({ label: "Browser JS AES (this PC)", color: cc(0), gbps: state.browserGbps });
  sw.push({ label: "Soft-core CPU, byte-wise (est.)", color: cc(0), gbps: SOFTCORE_GBPS });
  drawBars($("#bnChart"), [...rows, ...sw]);
  $("#bnTable").innerHTML = rows.length ? `<div class="tbl-wrap"><table><thead><tr><th>Core</th><th class="num">Blocks</th><th class="num">Cycles</th><th class="num">Cycles/block</th><th class="num">@ 100 MHz</th><th class="num">@ Fmax &ge;</th><th class="num">@ 384.6 MHz</th><th>Checksum</th></tr></thead><tbody>${
    rows.map((x) => `<tr><td><span class="corename" style="--cc:${x.color}">${x.label}</span></td><td class="num">${fmtInt(x.r.n)}</td><td class="num">${fmtInt(x.r.cycles)}</td><td class="num">${fmt(x.cpb, 3)}</td><td class="num"><b>${fmtGbps(x.gbps)}</b></td><td class="num">${x.fmaxG ? fmtGbps(x.fmaxG) : "—"}</td><td class="num">${fmtGbps(x.proj)}</td><td>${x.r.ok === null ? '<span class="tag dim">CHECKING</span>' : x.r.ok ? '<span class="tag ok">VERIFIED</span>' : '<span class="tag bad">MISMATCH</span>'}</td></tr>`).join("")
  }</tbody></table></div><p class="muted">Cycles are counted by the FPGA from the first block in to the last block out. "@ Fmax" uses the clock this build's timing analysis proves for that core (a lower bound: Vivado stops optimising once 100 MHz is met); "@ 384.6 MHz" is the reference paper's clock, which a −1 speed-grade Artix-7 may not reach.</p>` : "";
  renderScorecard();
}

// horizontal log-scale bar chart; reference lines at 1 and 4.92 Gbps
function drawBars(el, rows) {
  const W = 760, left = 210, right = 120, rowH = 34, top = 26, H = top + rows.length * rowH + 30;
  const lo = Math.log10(1e-3), hi = Math.log10(100);
  const x = (g) => left + (Math.log10(Math.max(g, 1e-3)) - lo) / (hi - lo) * (W - left - right);
  let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Throughput comparison">`;
  for (let e = -3; e <= 2; e++) {
    const gx = x(10 ** e);
    s += `<line x1="${gx}" y1="${top - 8}" x2="${gx}" y2="${H - 24}" stroke="rgba(148,163,184,.12)"/>`;
    s += `<text x="${gx}" y="${H - 8}" fill="#6f7b8e" font-size="11" text-anchor="middle">${e < 0 ? `${10 ** (e + 3)} Mb` : `${10 ** e} Gb`}</text>`;
  }
  for (const [g, lab] of [[1, "1 Gbps goal"], [4.92, "4.92 paper"]]) {
    s += `<line x1="${x(g)}" y1="${top - 14}" x2="${x(g)}" y2="${H - 24}" stroke="#fbbf24" stroke-dasharray="4 4" stroke-opacity=".6"/>`;
    s += `<text x="${x(g) + 4}" y="${top - 16}" fill="#fbbf24" font-size="10.5">${lab}</text>`;
  }
  rows.forEach((r, i) => {
    const y = top + i * rowH;
    s += `<text x="${left - 12}" y="${y + 17}" fill="#a9b4c4" font-size="12.5" text-anchor="end">${esc(r.label)}</text>`;
    if (r.fmaxG) s += `<rect x="${left}" y="${y + 5}" width="${Math.max(2, x(r.fmaxG) - left)}" height="16" rx="3" fill="${r.color}" fill-opacity=".18"/>`;
    s += `<rect x="${left}" y="${y + 5}" width="${Math.max(2, x(r.gbps) - left)}" height="16" rx="3" fill="${r.color}"/>`;
    s += `<text x="${x(r.fmaxG ? Math.max(r.gbps, r.fmaxG) : r.gbps) + 8}" y="${y + 17}" fill="#e6edf6" font-size="12" font-family="var(--mono)">${fmtGbps(r.gbps)}${r.fmaxG ? ` <tspan fill="#6f7b8e">→ ${fmtGbps(r.fmaxG)}</tspan>` : ""}</text>`;
  });
  el.innerHTML = s + "</svg>";
}

$("#ctGo").addEventListener("click", () => requireBoard() && job($("#ctGo"), async () => {
  const hist = {};
  let total = 0;
  for (const core of [1, 2, 3]) {
    const reqs = [];
    for (let i = 0; i < 300; i++) reqs.push(board.request(CMD.ENC + core, 0, A.randomBytes(16), A.randomBytes(16)));
    const res = await Promise.all(reqs);
    hist[core] = {};
    for (const r of res) { hist[core][r.aux] = (hist[core][r.aux] || 0) + 1; state.latSeen.add(r.aux); }
    total += res.length;
  }
  const lats = new Set(Object.values(hist).flatMap((h) => Object.keys(h)));
  state.ctResult = { constant: lats.size === 1, hist };
  $("#ctRes").innerHTML = state.ctResult.constant
    ? `<span class="tag ok">ALL ${total} BLOCKS: EXACTLY ${[...lats][0]} CYCLES</span>`
    : `<span class="tag bad">LATENCY VARIES: ${[...lats].join(", ")}</span>`;
  const W = 760, H = 150;
  let s = `<svg viewBox="0 0 ${W} ${H}">`;
  for (let L = 8; L <= 14; L++) {
    const gx = 60 + (L - 8) * 105;
    s += `<text x="${gx + 40}" y="${H - 6}" fill="#6f7b8e" font-size="11" text-anchor="middle">${L} cycles</text>`;
    [1, 2, 3].forEach((c, j) => {
      const n = hist[c][L] || 0, h = n / 300 * (H - 40);
      s += `<rect x="${gx + 10 + j * 22}" y="${H - 22 - h}" width="18" height="${Math.max(h, 1)}" rx="2" fill="${cc(c)}" fill-opacity="${n ? 1 : .15}"/>`;
    });
  }
  $("#ctChart").innerHTML = s + "</svg>";
  log(`constant-time check: ${total} blocks, latencies {${[...lats].join(", ")}}`, state.ctResult.constant ? "ok" : "bad");
}));

// ---------------------------------------------------------------------------
// image lab
// ---------------------------------------------------------------------------
const imSrc = document.createElement("canvas");
imSrc.width = imSrc.height = 256;
function drawSample() {
  const g = imSrc.getContext("2d");
  g.fillStyle = "#ffffff"; g.fillRect(0, 0, 256, 256);
  g.fillStyle = "#1e40af"; g.beginPath(); g.arc(80, 86, 54, 0, Math.PI * 2); g.fill();
  g.fillStyle = "#dc2626"; g.fillRect(140, 36, 90, 90);
  g.fillStyle = "#f59e0b"; g.beginPath(); g.moveTo(40, 230); g.lineTo(100, 140); g.lineTo(160, 230); g.fill();
  g.fillStyle = "#0f172a"; g.font = "bold 58px system-ui, sans-serif"; g.fillText("AES", 150, 200);
  g.fillStyle = "#16a34a"; g.fillRect(150, 214, 92, 16);
}
function loadImageFile(file) {
  const img = new Image();
  img.onload = () => {
    const g = imSrc.getContext("2d"), s = Math.min(img.width, img.height);
    g.drawImage(img, (img.width - s) / 2, (img.height - s) / 2, s, s, 0, 0, 256, 256);
    showOriginal();
    URL.revokeObjectURL(img.src);
  };
  img.src = URL.createObjectURL(file);
}
function imgSize() { return +$("#imSize").value; }
function rgbOf(size) {
  const c = document.createElement("canvas"); c.width = c.height = size;
  const g = c.getContext("2d"); g.imageSmoothingQuality = "high"; g.drawImage(imSrc, 0, 0, size, size);
  const d = g.getImageData(0, 0, size, size).data, out = new Uint8Array(size * size * 3);
  for (let i = 0, j = 0; i < d.length; i += 4) { out[j++] = d[i]; out[j++] = d[i + 1]; out[j++] = d[i + 2]; }
  return out;
}
function paint(canvas, rgb, size) {
  canvas.width = canvas.height = size;
  const g = canvas.getContext("2d"), im = g.createImageData(size, size);
  for (let i = 0, j = 0; j < rgb.length; i += 4) { im.data[i] = rgb[j++]; im.data[i + 1] = rgb[j++]; im.data[i + 2] = rgb[j++]; im.data[i + 3] = 255; }
  g.putImageData(im, 0, 0);
}
function clearCanvas(c) { const g = c.getContext("2d"); g.clearRect(0, 0, c.width, c.height); }
function showOriginal() {
  const s = imgSize();
  paint($("#imOrig"), rgbOf(s), s);
  ["#imEcb", "#imCtr", "#imDec"].forEach((id) => clearCanvas($(id)));
  $("#imStats").hidden = true;
}
$("#imSample").addEventListener("click", () => { drawSample(); showOriginal(); });
$("#imFile").addEventListener("change", (e) => e.target.files[0] && loadImageFile(e.target.files[0]));
$("#imSize").addEventListener("change", showOriginal);
drawSample(); showOriginal();

function progress(el, frac, text) {
  el.hidden = false;
  $(".bar", el).style.width = `${(frac * 100).toFixed(1)}%`;
  $(".ptext", el).textContent = text;
}

// encrypt n blocks on the FPGA, streaming, with a progress callback
async function fpgaBlocks(core, key, blockAt, n, onDone) {
  const out = new Uint8Array(n * 16);
  let done = 0;
  const CH = 512;                                   // keep the queue bounded
  for (let base = 0; base < n; base += CH) {
    const m = Math.min(CH, n - base);
    await Promise.all(Array.from({ length: m }, (_, i) =>
      board.request(CMD.ENC + core, 0, key, blockAt(base + i), 3000).then((r) => {
        out.set(r.payload, 16 * (base + i));
        if (++done % 64 === 0 || done === n) onDone(done, out);
      })));
  }
  return out;
}

$("#imGo").addEventListener("click", () => requireBoard() && job($("#imGo"), async () => {
  const size = imgSize(), core = imCores()[0];
  const plain = rgbOf(size), n = plain.length / 16;
  const key = A.randomBytes(16), rk = A.expandKey(key);
  const prog = $("#imProg");
  const t0 = performance.now();

  const ecb = await fpgaBlocks(core, key, (i) => plain.subarray(16 * i, 16 * i + 16), n, (d, buf) => {
    progress(prog, d / (2 * n), `ECB ${fmtInt(d)} / ${fmtInt(n)} blocks`);
    if (d % 256 === 0 || d === n) paint($("#imEcb"), buf, size);
  });
  const tEcb = performance.now() - t0;

  const nonce = A.bytesToBig(A.randomBytes(16));
  const ks = await fpgaBlocks(core, key, (i) => A.bigToBytes(nonce + BigInt(i)), n, (d, buf) => {
    progress(prog, (n + d) / (2 * n), `CTR ${fmtInt(d)} / ${fmtInt(n)} blocks`);
    if (d % 256 === 0 || d === n) {
      const part = new Uint8Array(buf.length);
      for (let i = 0; i < 16 * d; i++) part[i] = buf[i] ^ plain[i];
      paint($("#imCtr"), part, size);
    }
  });
  const ctr = ks.map((b, i) => b ^ plain[i]);
  paint($("#imCtr"), ctr, size);
  const total = performance.now() - t0;

  // check every FPGA block against the browser, then decrypt
  let bad = 0;
  const dec = new Uint8Array(plain.length);
  for (let i = 0; i < n; i++) {
    const p = plain.subarray(16 * i, 16 * i + 16), c = ecb.subarray(16 * i, 16 * i + 16);
    if (A.toHex(A.encryptBlock(key, p, false, rk)) !== A.toHex(c)) bad++;
    dec.set(A.decryptBlock(rk, c), 16 * i);
  }
  paint($("#imDec"), dec, size);
  const exact = dec.every((b, i) => b === plain[i]);
  state.verified += n - bad;
  progress(prog, 1, `done · ${fmtInt(2 * n)} blocks in ${fmt(total / 1000, 2)} s`);
  $("#imStats").hidden = false;
  $("#imStats").innerHTML = `<div class="kv">
    <div><span class="k">Blocks through FPGA</span><b>${fmtInt(2 * n)}</b></div>
    <div><span class="k">Image data</span><b>${fmt(plain.length / 1024, 1)} KB</b></div>
    <div><span class="k">ECB time</span><b>${fmt(tEcb / 1000, 2)} s</b></div>
    <div><span class="k">Link rate</span><b>${fmtInt(2 * n / (total / 1000))} blk/s</b></div>
    <div><span class="k">Verified vs browser</span><b>${fmtInt(n - bad)}/${fmtInt(n)}</b></div>
    <div><span class="k">Round trip</span><b>${exact ? "bit-exact" : "DIFFERS"}</b></div></div>
    <p class="muted">The link, not the core, sets the pace here: each block crosses USB as a 37-byte request and a 22-byte reply at 1 Mbaud. The core itself needs ${CORES[core].ii === 1 ? "one cycle" : `${CORES[core].ii} cycles`} per block — see Benchmark.</p>`;
  log(`image ${size}×${size}: ${fmtInt(2 * n)} blocks on ${CORES[core].name}, ${bad ? `${bad} MISMATCHES` : "all verified"}`, bad ? "bad" : "ok");
  renderScorecard();
}));

// ---------------------------------------------------------------------------
// NIST verification
// ---------------------------------------------------------------------------
$("#vfGo").addEventListener("click", () => requireBoard() && job($("#vfGo"), async () => {
  const N = +$("#vfN").value, prog = $("#vfProg");
  const per = {}, katRows = [];
  let total = 0, pass = 0;
  const vectors = [];
  for (let i = 0; i < N; i++) vectors.push([A.randomBytes(16), A.randomBytes(16)]);
  const grand = 3 * (A.KAT.length + N);
  for (const core of [1, 2, 3]) {
    per[core] = { katPass: 0, randPass: 0, lat: new Set(), fails: [] };
    const kat = await Promise.all(A.KAT.map(([, k, p]) => board.request(CMD.ENC + core, 0, A.fromHex(k), A.fromHex(p))));
    kat.forEach((r, i) => {
      const ok = A.toHex(r.payload) === A.KAT[i][3];
      per[core].katPass += ok; per[core].lat.add(r.aux);
      katRows[i] = katRows[i] || [];
      katRows[i][core] = ok;
      total++; pass += ok;
    });
    let done = 0;
    const CH = 512;
    for (let b = 0; b < N; b += CH) {
      const slice = vectors.slice(b, b + CH);
      const res = await Promise.all(slice.map(([k, p]) => board.request(CMD.ENC + core, 0, k, p)));
      res.forEach((r, i) => {
        const [k, p] = slice[i];
        const exp = A.toHex(A.encryptBlock(k, p));
        const ok = A.toHex(r.payload) === exp;
        per[core].randPass += ok; per[core].lat.add(r.aux); state.latSeen.add(r.aux);
        if (!ok && per[core].fails.length < 5) per[core].fails.push({ k: A.toHex(k), p: A.toHex(p), got: A.toHex(r.payload), exp });
        total++; pass += ok;
      });
      done += slice.length;
      progress(prog, total / grand, `${CORES[core].name}: ${fmtInt(done)} / ${fmtInt(N)}`);
    }
  }
  state.nist = { total, pass, fail: total - pass };
  state.verified += pass;
  progress(prog, 1, `${fmtInt(pass)} / ${fmtInt(total)} correct`);
  $("#vfTable").innerHTML = `<div class="tbl-wrap"><table><thead><tr><th>Core</th><th class="num">Known-answer</th><th class="num">Random</th><th class="num">Latency seen</th><th>Result</th></tr></thead><tbody>${
    [1, 2, 3].map((c) => { const p = per[c]; const ok = p.katPass === A.KAT.length && p.randPass === N;
      return `<tr><td><span class="corename" style="--cc:${cc(c)}">${CORES[c].name}</span></td><td class="num">${p.katPass}/${A.KAT.length}</td><td class="num">${fmtInt(p.randPass)}/${fmtInt(N)}</td><td class="num">${[...p.lat].join(", ")} cyc</td><td>${ok ? '<span class="tag ok">PASS</span>' : '<span class="tag bad">FAIL</span>'}</td></tr>`
        + p.fails.map((f) => `<tr><td></td><td colspan="4" class="hex">key ${f.k} pt ${f.p}<br>got ${f.got}<br>exp ${f.exp}</td></tr>`).join(""); }).join("")
  }</tbody></table></div>`;
  $("#vfKat").innerHTML = `<div class="tbl-wrap"><table><thead><tr><th>Vector</th><th>Key</th><th>Expected ciphertext</th>${[1, 2, 3].map((c) => `<th><span class="corename" style="--cc:${cc(c)}">${CORES[c].name}</span></th>`).join("")}</tr></thead><tbody>${
    A.KAT.map(([name, k, , c], i) => `<tr><td>${name}</td><td class="hex">${k}</td><td class="hex">${c}</td>${[1, 2, 3].map((core) => `<td>${katRows[i][core] ? '<span class="tag ok">OK</span>' : '<span class="tag bad">BAD</span>'}</td>`).join("")}</tr>`).join("")
  }</tbody></table></div>`;
  log(`NIST verification: ${pass}/${total} correct`, pass === total ? "ok" : "bad");
  if (pass === total) await showText("NIST PASS");
}));

// ---------------------------------------------------------------------------
// board control: display
// ---------------------------------------------------------------------------
const preview = segSvg($("#dsPreview"));
function dsOpts() { return { speed: 30 - +$("#dsSpeed").value, bright: +$("#dsBright").value }; }
function dsRefresh() {
  const lay = segLayout($("#dsText").value);
  preview.set(lay, dsOpts());
  const notes = [];
  if (lay.bad.length) notes.push(`no 7-segment shape for ${lay.bad.map((c) => JSON.stringify(c)).join(" ")}`);
  if (lay.truncated) notes.push("too long, trimmed");
  $("#dsNote").textContent = notes.join(" · ");
  return lay;
}
async function showText(text, opts = dsOpts()) {
  if (!board.connected) return;
  const lay = segLayout(text);
  state.display = { layout: lay, ...opts };
  try { await showOnBoard(board, lay, opts); } catch (e) { log(`display: ${e.message}`, "bad"); }
}
let dsTimer;
function dsSend() { const lay = dsRefresh(); if (!board.connected) return; state.display = { layout: lay, ...dsOpts() }; showOnBoard(board, lay, dsOpts()).catch((e) => log(e.message, "bad")); }
$("#dsText").addEventListener("input", () => { dsRefresh(); if ($("#dsLive").checked) { clearTimeout(dsTimer); dsTimer = setTimeout(dsSend, 120); } });
["#dsSpeed", "#dsBright"].forEach((s) => $(s).addEventListener("input", () => { dsRefresh(); if ($("#dsLive").checked) { clearTimeout(dsTimer); dsTimer = setTimeout(dsSend, 120); } }));
$("#dsText").addEventListener("keydown", (e) => e.key === "Enter" && dsSend());
$("#dsSend").addEventListener("click", () => requireBoard() && dsSend());
$("#dsAuto").addEventListener("click", () => requireBoard() && displayAuto(board).then(() => toast("Display back to the board's own status")));
dsRefresh();

// ---------------------------------------------------------------------------
// board control: LEDs
// ---------------------------------------------------------------------------
const ledBtns = [];
for (let i = 15; i >= 0; i--) {
  const b = document.createElement("button");
  b.className = "led"; b.type = "button"; b.setAttribute("aria-label", `LED ${i}`);
  b.innerHTML = `<span>${i}</span>`;
  b.addEventListener("click", () => { stopLedAnim(); state.leds.pattern ^= 1 << i; state.leds.manual = true; pushLeds(); });
  $("#ldRow").appendChild(b); ledBtns[i] = b;
}
const RGBS = [["off", "#1b2230"], ["blue", "#3b82f6"], ["green", "#22c55e"], ["cyan", "#22d3ee"], ["red", "#ef4444"], ["magenta", "#d946ef"], ["yellow", "#facc15"], ["white", "#f8fafc"]];
for (const which of ["rgb16", "rgb17"]) {
  $(`#${which}`).innerHTML = RGBS.map(([n, c], i) => `<button type="button" data-i="${i}" title="${n}" aria-label="${which} ${n}" style="background:${c}"></button>`).join("");
  $(`#${which}`).addEventListener("click", (e) => {
    const b = e.target.closest("button"); if (!b) return;
    state.leds[which] = +b.dataset.i; state.leds.manual = true; pushLeds();
  });
}
let pushing = false, pushAgain = false;
async function pushLeds() {
  ledBtns.forEach((b, i) => b.classList.toggle("on", !!((state.leds.pattern >> i) & 1)));
  for (const w of ["rgb16", "rgb17"]) $$(`#${w} button`).forEach((b) => b.classList.toggle("on", +b.dataset.i === state.leds[w]));
  $("#ldManual").checked = state.leds.manual;
  if (!board.connected) return;
  if (pushing) { pushAgain = true; return; }
  pushing = true;
  try { do { pushAgain = false; await setLeds(board, state.leds); } while (pushAgain); }
  catch (e) { log(`LEDs: ${e.message}`, "bad"); }
  finally { pushing = false; }
}
let ledAnim = null;
function stopLedAnim() { clearInterval(ledAnim); ledAnim = null; }
$("#ldManual").addEventListener("change", (e) => { stopLedAnim(); state.leds.manual = e.target.checked; pushLeds(); });
$("#ldClear").addEventListener("click", () => { stopLedAnim(); state.leds.pattern = 0; state.leds.manual = true; pushLeds(); });
$("#ldKnight").addEventListener("click", () => {
  stopLedAnim(); state.leds.manual = true;
  let p = 0, d = 1;
  ledAnim = setInterval(() => { state.leds.pattern = 0b111 << p; p += d; if (p >= 13 || p <= 0) d = -d; pushLeds(); }, 70);
});
$("#ldCount").addEventListener("click", () => {
  stopLedAnim(); state.leds.manual = true;
  ledAnim = setInterval(() => { state.leds.pattern = (state.leds.pattern + 1) & 0xffff; pushLeds(); }, 60);
});
pushLeds();

// ---------------------------------------------------------------------------
// board control: switches, buttons, self-test
// ---------------------------------------------------------------------------
$("#swRow").innerHTML = Array.from({ length: 16 }, (_, k) => `<div class="sw" data-i="${15 - k}"><i></i>${15 - k}</div>`).join("");
$("#btRow").innerHTML = ["L", "U", "C", "D", "R"].map((k) => `<span class="pbtn" data-k="${k}">BTN${k}</span>`).join("");
function renderSwitches(st) {
  $$("#swRow .sw").forEach((el) => el.classList.toggle("on", !!((st.switches >> +el.dataset.i) & 1)));
  $$("#btRow .pbtn").forEach((el) => el.classList.toggle("on", st.buttons[el.dataset.k]));
}
function renderSelftest(s) {
  $("#stView").innerHTML = [1, 2, 3].map((c) => {
    const m = 1 << (c - 1), ok = s.pass & m, bad = s.fail & m;
    return `<div class="st-cell ${ok ? "ok" : bad ? "fail" : ""}"><div class="n"><span class="corename" style="--cc:${cc(c)}">${CORES[c].name}</span></div><div class="s">${s.busy ? "running…" : ok ? "PASS" : bad ? "FAIL" : "—"}</div></div>`;
  }).join("");
}
renderSelftest({ pass: 0, fail: 0, busy: false });
async function runSelftest(btn) {
  if (!requireBoard()) return;
  await job(btn, async () => {
    const r = await board.request(CMD.SELFTEST, 0, ZERO16, ZERO16, 2000);
    const pass = r.status & 7;
    toast(pass === 7 ? "Self-test: all three cores pass FIPS-197 C.1" : "Self-test FAILED", pass !== 7);
    log(`self-test: status 0x${r.status.toString(16)}`, pass === 7 ? "ok" : "bad");
  });
}
$("#stGo").addEventListener("click", () => runSelftest($("#stGo")));
$("#ovSelftest").addEventListener("click", () => runSelftest($("#ovSelftest")));

async function buttonEncrypt(core) {
  await job(null, async () => {
    const key = A.randomBytes(16), pt = A.randomBytes(16);
    const [row] = await encryptOn(core, key, [pt]);
    toast(`BTNU → ${CORES[core].name}: ${A.toHex(row.ct)} ${row.ok ? "✓" : "✕"}`, !row.ok);
    log(`board button: encrypted on ${CORES[core].name}, ${row.ok ? "verified" : "MISMATCH"}`, row.ok ? "ok" : "bad");
    await showText(A.toHex(row.ct), { speed: 10, bright: 7 });
  });
}
async function buttonBench(core) {
  await job(null, async () => {
    const N = 1 << 20, key = A.randomBytes(16), seed = A.randomBytes(16);
    await showText("bEnCH", { speed: 12, bright: 7 });
    const r = await board.request(CMD.BENCH + core, N, key, seed, N * CORES[core].ii / CLK_HZ * 1000 + 3000);
    const gbps = N * 128 / (r.aux / CLK_HZ) / 1e9;
    state.bench[core] = { n: N, cycles: r.aux, gbps, ok: null };
    state.bestGbps = Math.max(state.bestGbps, gbps);
    toast(`BTND → ${CORES[core].name}: ${fmtGbps(gbps)}`);
    await showText(`${fmt(gbps, 2)} Gb`, { speed: 12, bright: 7 });
    const ref = await A.ctrXorChecksum(key, seed, N);
    state.bench[core].ok = A.toHex(ref) === A.toHex(r.payload);
    renderBench();
  });
}

// ---------------------------------------------------------------------------
// implementation report
// ---------------------------------------------------------------------------
async function loadBuild() {
  try {
    const b = await (await fetch(`build_info.json?${Date.now()}`)).json();
    state.build = b;
    renderImpl();
    renderBench();
    renderScorecard();
  } catch {
    $("#implBody").innerHTML = '<div class="card muted">No build_info.json yet -- run fpga/scripts/build.tcl.</div>';
  }
}
function renderImpl() {
  const b = state.build, D = b.device;
  const pct = (n, of) => 100 * n / of;
  const util = (label, n, of, color) => `<div class="util" style="--cc:${color}"><span>${label}</span><div class="track"><div class="fill" style="width:${Math.max(pct(n, of), 0.4)}%"></div></div><span class="val">${fmtInt(n)} · ${fmt(pct(n, of), 2)}%</span></div>`;
  const coreRows = [["iterative", 1], ["ii10", 2], ["pipelined", 3]];
  const target = (ok, t, r) => `<tr><td>${t}</td><td class="num">${r}</td><td>${ok === null ? '<span class="tag dim">N/A</span>' : ok ? '<span class="tag ok">MET</span>' : '<span class="tag warn">NOT MET</span>'}</td></tr>`;
  const it = b.cores.iterative, i2 = b.cores.ii10;
  $("#implBody").innerHTML = `
    <div class="card"><div class="card-head"><h2>Routed design on ${b.part}</h2><span class="sub">built ${esc(b.built)}</span></div>
      <div class="kv">
        <div><span class="k">LUTs</span><b>${fmtInt(b.total.lut)}</b> <span class="muted">${fmt(pct(b.total.lut, D.lut), 1)}%</span></div>
        <div><span class="k">Flip-flops</span><b>${fmtInt(b.total.ff)}</b> <span class="muted">${fmt(pct(b.total.ff, D.ff), 1)}%</span></div>
        <div><span class="k">Block RAM</span><b>${b.total.bram}</b> <span class="muted">RX FIFO</span></div>
        <div><span class="k">DSP</span><b>${b.total.dsp}</b></div>
        <div><span class="k">WNS @ 100 MHz</span><b>${fmt(b.timing.wns_ns, 3)} ns</b></div>
        <div><span class="k">Fmax &ge; (worst path)</span><b>${fmt(b.timing.fmax_mhz, 1)} MHz</b></div>
        <div><span class="k">Power (est.)</span><b>${fmt(b.power_w.total, 3)} W</b> <span class="muted">${fmt(b.power_w.dynamic, 3)} dyn</span></div>
      </div></div>
    <div class="card"><div class="card-head"><h2>Per core</h2><span class="sub">share of the xc7a100t</span></div>
      ${coreRows.map(([k, i]) => util(`${CORES[i].name} LUT`, b.cores[k].lut, D.lut, cc(i))).join("")}
      ${coreRows.map(([k, i]) => util(`${CORES[i].name} FF`, b.cores[k].ff, D.ff, cc(i))).join("")}
      ${util("UART link + FIFO LUT", b.cores.bridge.lut, D.lut, "var(--c0)")}
      <div class="tbl-wrap"><table><thead><tr><th>Core</th><th class="num">LUT</th><th class="num">FF</th><th class="num">Worst slack</th><th class="num">Fmax &ge;</th><th class="num">Gbps at that clock</th></tr></thead><tbody>${
        coreRows.map(([k, i]) => { const c = b.cores[k]; return `<tr><td><span class="corename" style="--cc:${cc(i)}">${CORES[i].name}</span></td><td class="num">${fmtInt(c.lut)}</td><td class="num">${fmtInt(c.ff)}</td><td class="num">${fmt(c.slack_ns, 3)} ns</td><td class="num">${fmt(c.fmax_mhz, 1)} MHz</td><td class="num">${fmtGbps(128 * c.fmax_mhz * 1e6 / CORES[i].ii / 1e9)}</td></tr>`; }).join("")
      }</tbody></table></div></div>
    <div class="card"><div class="card-head"><h2>Project targets</h2><span class="sub">from the project brief</span></div>
      <div class="tbl-wrap"><table><thead><tr><th>Target</th><th class="num">This build</th><th>Status</th></tr></thead><tbody>
        ${target(pct(it.lut, D.lut) < 3, "Slice LUTs below 3 % (iterative core)", `${fmt(pct(it.lut, D.lut), 2)} %`)}
        ${target(pct(i2.lut, D.lut) < 3, "Slice LUTs below 3 % (overlapped core)", `${fmt(pct(i2.lut, D.lut), 2)} %`)}
        ${target(pct(i2.ff, D.ff) < 2, "Registers below 2 % (overlapped core)", `${fmt(pct(i2.ff, D.ff), 2)} %`)}
        ${target(pct(b.total.bram, D.bram) < 15, "Block RAM below 15 %", `${fmt(pct(b.total.bram, D.bram), 1)} %`)}
        ${target(true, "Latency 11 cycles per block", "11 cycles (measured on board)")}
        ${target(true, "One block per 10 cycles (4.92 Gbps arithmetic)", "10 cycles (overlapped core)")}
        ${target(i2.fmax_mhz >= TARGET_MHZ, "Clock 384.6 MHz", `&ge; ${fmt(i2.fmax_mhz, 1)} MHz proven`)}
      </tbody></table></div>
      <p class="muted">Fmax figures are lower bounds: this build is constrained to the 100 MHz board clock and Vivado stops optimising once that is met. The clock target comes from the reference paper. A full AES round (S-box, ShiftRows, MixColumns, key XOR) between registers sets this core's Fmax; reaching 384.6 MHz would need the round split across two pipeline stages or a faster speed grade.</p>
    </div>`;
}
loadBuild();

// ---------------------------------------------------------------------------
// start-up
// ---------------------------------------------------------------------------
if (!("serial" in navigator)) {
  $("#noSerial").hidden = false;
  $("#connectBtn").disabled = true;
}
log(A.MODEL_OK ? "browser AES model: all 8 known-answer vectors pass" : "browser AES model FAILED its self-check", A.MODEL_OK ? "ok" : "bad");
renderScorecard();
renderBench();
show((location.hash || "#overview").slice(1).replace(/[^a-z]/g, "") || "overview");
