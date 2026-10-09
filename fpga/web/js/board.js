// board.js -- the FPGA over Web Serial (protocol: fpga/rtl/aes_uart_bridge.v)
//
// request(cmd, arg, key, data) -> Promise<{cmd, status, aux, payload}>
//
// Requests are queued and up to WINDOW of them kept in flight; the FPGA's
// 4 KB receive FIFO absorbs them, so the link never idles waiting for the
// Windows FTDI driver's latency timer. Responses come back in order.

export const CMD = {
  PING: 0x00, ENC: 0x00 /* + core */, BENCH: 0x10 /* + core */,
  DISP_WRITE: 0x20, DISP_SHOW: 0x21, LEDS: 0x22, STATUS: 0x30, SELFTEST: 0x40,
};
export const CORES = {
  1: { key: "iterative", name: "Iterative", full: "aes128_iterative", ii: 11 },
  2: { key: "ii10", name: "Overlapped", full: "aes128_iterative_ii10", ii: 10 },
  3: { key: "pipelined", name: "Pipelined", full: "aes128_pipelined", ii: 1 },
};

const REQ = 37, RESP = 22, WINDOW = 64;
const ZERO = new Uint8Array(16);

export class Board extends EventTarget {
  constructor() {
    super();
    this.port = null;
    this.writer = null;
    this.reader = null;
    this.baud = 1_000_000;
    this.toSend = [];           // not yet written
    this.inflight = [];         // written, awaiting a response (in order)
    this.rx = new Uint8Array(0);
    this.writing = false;
    this.stats = { tx: 0, rx: 0, requests: 0, errors: 0 };
    this.watchdog = null;
  }

  get connected() { return !!this.port; }
  get busy() { return this.toSend.length + this.inflight.length; }

  async connect() {
    const port = await navigator.serial.requestPort({ filters: [{ usbVendorId: 0x0403 }] });
    await port.open({ baudRate: this.baud, bufferSize: 65536 });
    this.port = port;
    this.writer = port.writable.getWriter();
    this.readLoop();
    this.watchdog = setInterval(() => this.checkTimeouts(), 50);
    navigator.serial.addEventListener("disconnect", this.onUnplug = (e) => {
      if (e.target === this.port) this.disconnect("board unplugged");
    });
  }

  async disconnect(reason = "disconnected") {
    clearInterval(this.watchdog);
    const port = this.port;
    this.port = null;
    this.failAll(new Error(reason));
    try { if (this.reader) await this.reader.cancel(); } catch {}
    try { if (this.writer) this.writer.releaseLock(); } catch {}
    try { if (port) await port.close(); } catch {}
    this.writer = this.reader = null;
    this.dispatchEvent(new CustomEvent("disconnect", { detail: reason }));
  }

  request(cmd, arg = 0, key = ZERO, data = ZERO, timeoutMs = 1500) {
    if (!this.port) return Promise.reject(new Error("not connected"));
    return new Promise((resolve, reject) => {
      this.toSend.push({ cmd, arg, key, data, timeoutMs, resolve, reject });
      this.pump();
    });
  }

  // write as many queued requests as the window allows, in one USB write
  async pump() {
    if (this.writing || !this.port) return;
    const wait = (this.muteUntil || 0) - performance.now();
    if (wait > 0) { setTimeout(() => this.pump(), wait + 1); return; }
    this.writing = true;
    try {
      while (this.toSend.length && this.inflight.length < WINDOW) {
        const n = Math.min(this.toSend.length, WINDOW - this.inflight.length);
        const batch = this.toSend.splice(0, n);
        const buf = new Uint8Array(REQ * n);
        const now = performance.now();
        batch.forEach((r, i) => {
          const o = i * REQ;
          buf[o] = r.cmd;
          buf[o + 1] = (r.arg >>> 24) & 0xff; buf[o + 2] = (r.arg >>> 16) & 0xff;
          buf[o + 3] = (r.arg >>> 8) & 0xff;  buf[o + 4] = r.arg & 0xff;
          buf.set(r.key, o + 5);
          buf.set(r.data, o + 21);
          // queued requests wait their turn: allow ~0.5 ms each on top
          r.deadline = now + r.timeoutMs + 0.5 * (this.inflight.length + i);
          r.sentAt = now;
        });
        this.inflight.push(...batch);
        await this.writer.write(buf);
        this.stats.tx += buf.length;
      }
    } catch (e) {
      this.failAll(e);
    } finally {
      this.writing = false;
    }
  }

  async readLoop() {
    while (this.port && this.port.readable) {
      this.reader = this.port.readable.getReader();
      try {
        for (;;) {
          const { value, done } = await this.reader.read();
          if (done) break;
          this.onBytes(value);
        }
      } catch (e) {
        if (this.port) this.dispatchEvent(new CustomEvent("log", { detail: { msg: `read error: ${e.message}`, cls: "bad" } }));
      } finally {
        try { this.reader.releaseLock(); } catch {}
      }
      if (!this.port) break;
    }
  }

  onBytes(chunk) {
    this.stats.rx += chunk.length;
    if (performance.now() < (this.muteUntil || 0)) return;   // draining after a resync
    const b = new Uint8Array(this.rx.length + chunk.length);
    b.set(this.rx); b.set(chunk, this.rx.length);
    let off = 0;
    while (b.length - off >= RESP) {
      const r = this.inflight[0];
      if (!r) { off = b.length; break; }               // unsolicited: drop
      const echo = b[off];
      if (echo !== r.cmd && echo !== 0xee) {             // out of step
        off = b.length;
        this.resync("response out of step");
        break;
      }
      this.inflight.shift();
      const v = new DataView(b.buffer, b.byteOffset + off, RESP);
      const resp = {
        cmd: echo, status: b[off + 1], aux: v.getUint32(2),
        payload: b.slice(off + 6, off + 22), ms: performance.now() - r.sentAt,
      };
      off += RESP;
      this.stats.requests++;
      if (echo === 0xee) r.reject(new Error(`board rejected command 0x${r.cmd.toString(16)}`));
      else r.resolve(resp);
    }
    this.rx = b.slice(off);
    if (this.toSend.length) this.pump();
  }

  checkTimeouts() {
    const head = this.inflight[0];
    if (head && performance.now() > head.deadline) this.resync("no response from the board");
  }

  // drop everything outstanding, let the FPGA discard any partial frame
  resync(why) {
    this.stats.errors++;
    this.failAll(new Error(why));
    this.rx = new Uint8Array(0);
    // the FPGA may still be answering queued requests: ignore the line until
    // they are out and any partial frame has timed out (20 ms) on its side
    this.muteUntil = performance.now() + 150;
    this.dispatchEvent(new CustomEvent("log", { detail: { msg: `link resync: ${why}`, cls: "bad" } }));
  }

  failAll(err) {
    for (const r of this.inflight.splice(0)) r.reject(err);
    for (const r of this.toSend.splice(0)) r.reject(err);
  }
}

// ---------------------------------------------------------------------------
// 7-segment font: bit 0 = a ... bit 6 = g, bit 7 = DP (same as the FPGA)
// ---------------------------------------------------------------------------
const UPPER = {
  "0":0x3F,"1":0x06,"2":0x5B,"3":0x4F,"4":0x66,"5":0x6D,"6":0x7D,"7":0x07,"8":0x7F,"9":0x6F,
  "A":0x77,"B":0x7C,"C":0x39,"D":0x5E,"E":0x79,"F":0x71,"G":0x3D,"H":0x76,"I":0x30,"J":0x1E,
  "K":0x75,"L":0x38,"M":0x37,"N":0x54,"O":0x3F,"P":0x73,"Q":0x67,"R":0x50,"S":0x6D,"T":0x78,
  "U":0x3E,"V":0x3E,"W":0x7E,"X":0x76,"Y":0x6E,"Z":0x5B,
  " ":0x00,"-":0x40,"_":0x08,"=":0x48,"\"":0x22,"'":0x02,"[":0x39,"]":0x0F,"(":0x39,")":0x0F,
  "?":0x53,"!":0x82,"/":0x52,"\\":0x64,"|":0x30,"^":0x23,"°":0x63,"<":0x58,">":0x4C,"~":0x01,
  "+":0x46,"*":0x63,"#":0x49,
};
const LOWER = { c: 0x58, h: 0x74, o: 0x5C, u: 0x1C, i: 0x10, n: 0x54, r: 0x50, t: 0x78 };

export function segEncode(text) {
  const segs = [], bad = new Set();
  for (const ch of text) {
    if (ch === "." || ch === ",") {
      if (segs.length && !(segs[segs.length - 1] & 0x80)) segs[segs.length - 1] |= 0x80;
      else segs.push(0x80);
      continue;
    }
    let s = LOWER[ch];
    if (s === undefined) s = UPPER[ch.toUpperCase()];
    if (s === undefined) { bad.add(ch); s = 0; }
    segs.push(s);
  }
  return { segs, bad: [...bad] };
}

// what the display will hold for a piece of text
export function segLayout(text, { mode = "auto", align = "left" } = {}) {
  const { segs, bad } = segEncode(text);
  const scroll = mode === "scroll" || (mode === "auto" && segs.length > 8);
  let out, truncated = false;
  if (scroll) {
    out = segs.slice(0, 60);
    truncated = segs.length > 60;
    out = out.concat([0, 0, 0, 0]);
    while (out.length < 8) out.push(0);
  } else {
    out = segs.slice(0, 8);
    truncated = segs.length > 8;
    const padN = new Array(8 - out.length).fill(0);
    out = align === "right" ? padN.concat(out) : out.concat(padN);
  }
  return { segs: out, scroll, bad, truncated };
}

// send a layout to the board: buffer writes, then show
export async function showOnBoard(board, layout, { bright = 7, speed = 12 } = {}) {
  const segs = layout.segs;
  const jobs = [];
  for (let off = 0; off < segs.length; off += 16) {
    const chunk = new Uint8Array(16);
    chunk.set(segs.slice(off, off + 16));
    jobs.push(board.request(CMD.DISP_WRITE, off, ZERO, chunk));
  }
  const flags = 0x10 | ((bright & 7) << 1) | (layout.scroll ? 1 : 0);
  jobs.push(board.request(CMD.DISP_SHOW, ((flags << 24) | ((speed & 0xff) << 16) | ((segs.length & 0xff) << 8)) >>> 0));
  await Promise.all(jobs);
}

export const displayAuto = (board) => board.request(CMD.DISP_SHOW, 0);

export function setLeds(board, { manual, pattern = 0, rgb16 = 0, rgb17 = 0 }) {
  const data = new Uint8Array(16);
  data[14] = (pattern >> 8) & 0xff;
  data[15] = pattern & 0xff;
  const arg = ((manual ? 1 : 0) << 31) | ((rgb17 & 7) << 3) | (rgb16 & 7);
  return board.request(CMD.LEDS, arg >>> 0, ZERO, data);
}

export function parseStatus(r) {
  const p = r.payload, v = new DataView(p.buffer, p.byteOffset, 16);
  const tempCode = v.getUint16(4) >> 4, vccCode = v.getUint16(6) >> 4;
  const st = p[3];
  return {
    flags: r.status,
    ledManual: !!(r.status & 0x80), pageMode: !!(r.status & 0x40), overflow: !!(r.status & 1),
    uptime: r.aux,
    switches: v.getUint16(0),
    buttons: { C: !!(p[2] & 16), U: !!(p[2] & 8), L: !!(p[2] & 4), R: !!(p[2] & 2), D: !!(p[2] & 1) },
    selftest: { busy: !!(st & 0x80), ran: !!(st & 0x40), fail: (st >> 3) & 7, pass: st & 7, raw: st },
    tempC: tempCode * 503.975 / 4096 - 273.15,
    vccint: vccCode * 3 / 4096,
    blocks: v.getUint32(8),
    frames: v.getUint32(12),
  };
}
