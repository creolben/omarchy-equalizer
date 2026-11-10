#!/usr/bin/env node
// Signals and measurements for tests/dsp-check.sh, which plays them through the
// real equalizer graph on a private PipeWire and records what comes out. The
// equalizer's own maths (Model.js) is the reference: a measured curve that
// disagrees with it means the panel draws, and the headroom assumes, something
// the graph does not do.
//
//   node tests/dsp-check.js gen impulse <out.wav> [amp]
//   node tests/dsp-check.js gen sine <out.wav> <freq> <ampL> <ampR> [seconds]
//   node tests/dsp-check.js response <rec.wav> <bands.json> <preamp> [tolerance-dB]
//   node tests/dsp-check.js flat <rec.wav> <expected-dB> [tolerance-dB]
//   node tests/dsp-check.js level <rec.wav>
//   node tests/dsp-check.js thd <rec.wav> <freq>
//   node tests/dsp-check.js trend <rec.wav>
//   node tests/dsp-check.js lag <rec4.wav>
//   node tests/dsp-check.js clicks <rec.wav> <freq>
//   node tests/dsp-check.js peak <rec.wav>
//   node tests/dsp-check.js gen gate <out.wav>
//   node tests/dsp-check.js gate <rec.wav>
//
// Every measurement prints one line and exits 0 on a pass, 1 on a fail, so the
// shell side only has to count.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const RATE = 48000;
const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), model);

function writeWav(file, chans) {
  const n = chans[0].length, data = Buffer.alloc(n * chans.length * 4);
  for (let i = 0; i < n; i++)
    for (let c = 0; c < chans.length; c++) data.writeFloatLE(chans[c][i], (i * chans.length + c) * 4);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12);
  h.writeUInt32LE(16, 16); h.writeUInt16LE(3, 20); h.writeUInt16LE(chans.length, 22); h.writeUInt32LE(RATE, 24);
  h.writeUInt32LE(RATE * chans.length * 4, 28); h.writeUInt16LE(chans.length * 4, 32); h.writeUInt16LE(32, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  fs.writeFileSync(file, Buffer.concat([h, data]));
}

// pw-record writes WAVE_FORMAT_EXTENSIBLE with extra chunks, so walk them.
function readWav(file) {
  const b = fs.readFileSync(file);
  let off = 12, ch = 2, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4), size = b.readUInt32LE(off + 4);
    if (id === 'fmt ') ch = b.readUInt16LE(off + 10);
    if (id === 'data') { data = b.subarray(off + 8, off + 8 + Math.min(size, b.length - off - 8)); break; }
    off += 8 + size + (size & 1);
  }
  if (!data) throw new Error('no data chunk in ' + file);
  const n = Math.floor(data.length / (4 * ch)), out = [];
  for (let c = 0; c < ch; c++) out.push(new Float64Array(n));
  for (let i = 0; i < n; i++) for (let c = 0; c < ch; c++) out[c][i] = data.readFloatLE((i * ch + c) * 4);
  return out;
}

function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const a = -2 * Math.PI / len, wr = Math.cos(a), wi = Math.sin(a);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const p = i + k, q = p + len / 2;
        const xr = re[q] * cr - im[q] * ci, xi = re[q] * ci + im[q] * cr;
        re[q] = re[p] - xr; im[q] = im[p] - xi; re[p] += xr; im[p] += xi;
        const t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t;
      }
    }
  }
}

const IMPULSE_AMP = 0.1;
const GATE_LEAD = 0.6, GATE_BURSTS = 6, GATE_PILOT = 1025;
const N = 32768;
// The impulse response of one channel, as dB at any frequency. The window
// starts just before the strongest sample, so the graph's latency (the
// limiter's lookahead) does not matter.
function impulseResponse(sig) {
  let pk = 0;
  for (let i = 0; i < sig.length; i++) if (Math.abs(sig[i]) > Math.abs(sig[pk])) pk = i;
  const start = Math.max(0, pk - 512), re = new Float64Array(N), im = new Float64Array(N);
  for (let i = 0; i < N && start + i < sig.length; i++) re[i] = sig[start + i] / IMPULSE_AMP;
  fft(re, im);
  return f => {
    const k = Math.round(f * N / RATE);
    return { db: 20 * Math.log10(Math.hypot(re[k], im[k]) + 1e-30), f: k * RATE / N };
  };
}

// Checked frequencies: a dense log grid, kept off 20 Hz where a 0.7 s window's
// resolution starts to show, and off the very top where the graph's
// oversampling filters live.
const GRID = [];
for (let i = 0; i <= 60; i++) GRID.push(25 * Math.pow(18000 / 25, i / 60));

function steady(sig) {
  let mx = 0;
  for (const v of sig) mx = Math.max(mx, Math.abs(v));
  let first = -1, last = -1;
  for (let i = 0; i < sig.length; i++) if (Math.abs(sig[i]) > mx * 0.1) { if (first < 0) first = i; last = i; }
  return { first, last, mx };
}

function done(ok, text) {
  console.log((ok ? 'ok   ' : 'FAIL ') + text);
  process.exit(ok ? 0 : 1);
}

const [, , cmd, ...args] = process.argv;
if (cmd === 'gen') {
  const [kind, out] = args;
  if (kind === 'impulse') {
    const n = Math.round(RATE * 1.5), L = new Float32Array(n), R = new Float32Array(n);
    const amp = Number(args[2] || IMPULSE_AMP);
    L[Math.round(RATE * 0.25)] = amp; R[Math.round(RATE * 0.25)] = amp;
    writeWav(out, [L, R]);
  } else if (kind === 'sine') {
    const f = Number(args[2]), aL = Number(args[3]), aR = Number(args[4]), secs = Number(args[5] || 0.8);
    const lead = Math.round(RATE * 0.3), len = Math.round(RATE * secs), n = lead + len + Math.round(RATE * 0.3);
    const L = new Float32Array(n), R = new Float32Array(n);
    for (let i = 0; i < len; i++) {
      const v = Math.sin(2 * Math.PI * f * i / RATE);
      L[lead + i] = aL * v; R[lead + i] = aR * v;
    }
    writeWav(out, [L, R]);
  } else if (kind === 'gate') {
    // The balanced headroom's gate (docs/spec-v4.md §3.5.2): pink noise at a
    // 12 dB crest factor, normalised to -0.1 dBFS peak; every 500 ms a
    // full-scale 50 Hz burst of four cycles in its place; and under all of it a
    // -30 dBFS pilot at 1025 Hz (an exact bin of a 40 ms window, and no
    // harmonic of 50 Hz), alone for the first 0.6 s as the reference.
    const n = Math.round(RATE * (GATE_LEAD + GATE_BURSTS * 0.5 + 0.3)), L = new Float32Array(n);
    let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, seed = 12345;
    const white = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x3fffffff - 1; };
    const pink = new Float64Array(n);
    let sq = 0;
    for (let i = 0; i < n; i++) {
      // Paul Kellet's pink filter.
      const w = white();
      b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759; b2 = 0.96900 * b2 + w * 0.1538520;
      b3 = 0.86650 * b3 + w * 0.3104856; b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980;
      pink[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362; b6 = w * 0.115926;
      sq += pink[i] * pink[i];
    }
    const rms = Math.sqrt(sq / n), clipAt = rms * 4;          // 12 dB crest
    let mx = 0;
    for (let i = 0; i < n; i++) { pink[i] = Math.max(-clipAt, Math.min(clipAt, pink[i])); mx = Math.max(mx, Math.abs(pink[i])); }
    const noiseScale = Math.pow(10, -0.1 / 20) / mx * 0.95;  // room for the pilot
    const pilot = 0.0316;
    for (let i = 0; i < n; i++) {
      const t = i / RATE;
      let v = pilot * Math.sin(2 * Math.PI * GATE_PILOT * t);
      if (t >= GATE_LEAD) {
        const rel = (t - GATE_LEAD) % 0.5, k = Math.floor((t - GATE_LEAD) / 0.5);
        if (k < GATE_BURSTS && rel < 4 / 50) v += 0.965 * Math.sin(2 * Math.PI * 50 * rel);
        else if (k < GATE_BURSTS) v += pink[i] * noiseScale;
      }
      L[i] = v;
    }
    writeWav(out, [L, L]);
  } else {
    done(false, 'unknown signal ' + kind);
  }
  process.exit(0);
}

const rec = readWav(args[0]);

if (cmd === 'response') {
  // Both channels against the model of these bands and this preamp.
  const bands = JSON.parse(fs.readFileSync(args[1], 'utf8'));
  const preamp = Number(args[2] || 0), tol = Number(args[3] || 0.1);
  let worst = 0, at = 0, chan = 0;
  for (let c = 0; c < 2; c++) {
    const h = impulseResponse(rec[c]);
    for (const f of GRID) {
      const got = h(f);
      const want = model.responseDb(bands, preamp, got.f, RATE);
      // Deep notches and stopbands are measured to the noise of the window, so
      // only the part of the curve above -40 dB is held to the tolerance.
      if (want < -40 && got.db < -40) continue;
      const err = got.db - want;
      if (Math.abs(err) > Math.abs(worst)) { worst = err; at = got.f; chan = c; }
    }
  }
  done(Math.abs(worst) <= tol, 'worst ' + worst.toFixed(3) + ' dB at ' + at.toFixed(0) + ' Hz (ch' + chan + '), tolerance ' + tol);
}

if (cmd === 'flat') {
  // A flat response at a known level: the null test, and the A/B.
  const want = Number(args[1] || 0), tol = Number(args[2] || 0.05);
  let worst = 0, at = 0;
  for (let c = 0; c < 2; c++) {
    const h = impulseResponse(rec[c]);
    for (const f of GRID) {
      const got = h(f), err = got.db - want;
      if (Math.abs(err) > Math.abs(worst)) { worst = err; at = got.f; }
    }
  }
  done(Math.abs(worst) <= tol, 'flat at ' + want.toFixed(2) + ' dB: worst ' + worst.toFixed(3) + ' dB at ' + at.toFixed(0) + ' Hz');
}

if (cmd === 'level') {
  // Steady-state peak of each channel over the middle of the burst, as "L R".
  const s = rec.map(steady);
  const a = Math.min(...s.map(x => x.first < 0 ? Infinity : x.first)), z = Math.max(...s.map(x => x.last));
  const from = a + Math.floor((z - a) * 0.3), to = a + Math.floor((z - a) * 0.7);
  const peak = rec.map(sig => { let p = 0; for (let i = from; i < to; i++) p = Math.max(p, Math.abs(sig[i])); return p; });
  console.log(peak.map(p => p.toFixed(4)).join(' '));
  process.exit(0);
}

if (cmd === 'thd') {
  // THD (harmonics 2..10) of channel 0 over the middle of the burst.
  const f0 = Number(args[1]);
  const x = rec[0], s = steady(x), M = 16384, start = s.first + Math.floor((s.last - s.first - M) / 2);
  const re = new Float64Array(M), im = new Float64Array(M);
  for (let i = 0; i < M; i++) {
    const t = 2 * Math.PI * i / (M - 1);
    re[i] = x[start + i] * (0.35875 - 0.48829 * Math.cos(t) + 0.14128 * Math.cos(2 * t) - 0.01168 * Math.cos(3 * t));
  }
  fft(re, im);
  const power = k => { let p = 0; for (let j = k - 4; j <= k + 4; j++) if (j > 0 && j < M / 2) p += re[j] * re[j] + im[j] * im[j]; return p; };
  const fund = power(Math.round(f0 * M / RATE));
  let harm = 0;
  for (let h = 2; h <= 10 && h * f0 < RATE / 2; h++) harm += power(Math.round(h * f0 * M / RATE));
  console.log((100 * Math.sqrt(harm / fund)).toFixed(3));
  process.exit(0);
}

if (cmd === 'lag') {
  // Samples between the impulse that went in (channel 2) and the one that came
  // out (channel 0) of a four-channel recording.
  const at = sig => { let k = 0; for (let i = 0; i < sig.length; i++) if (Math.abs(sig[i]) > Math.abs(sig[k])) k = i; return k; };
  console.log(String(at(rec[0]) - at(rec[2])));
  process.exit(0);
}

if (cmd === 'trend') {
  // Peak level of channel 0 in the first and the last second of the burst,
  // as "first last": the leveler moves a steady tone from one to the other.
  const x = rec[0], s = steady(x), sec = RATE;
  const peakIn = (a, b) => { let p = 0; for (let i = Math.max(a, 0); i < Math.min(b, x.length); i++) p = Math.max(p, Math.abs(x[i])); return p; };
  const db = p => (20 * Math.log10(p + 1e-12)).toFixed(1);
  console.log(db(peakIn(s.first + Math.floor(sec * 0.2), s.first + sec)) + ' ' + db(peakIn(s.last - sec, s.last - Math.floor(sec * 0.1))));
  process.exit(0);
}

if (cmd === 'clicks') {
  // The largest sample-to-sample jump of channel 0 against what a clean tone
  // of the local amplitude can do (2 A sin(pi f / fs)), in dB over 25 ms
  // windows: a gain step that clicks shows as a jump far above the tone's own.
  const f0 = Number(args[1]), x = rec[0], s = steady(x), W = Math.round(RATE * 0.025);
  const own = 2 * Math.sin(Math.PI * f0 / RATE);
  let worst = -Infinity;
  for (let a = s.first + Math.round(RATE * 0.05); a + W < s.last - Math.round(RATE * 0.05); a += W) {
    let pk = 0, jump = 0;
    for (let i = a; i < a + W; i++) { pk = Math.max(pk, Math.abs(x[i])); jump = Math.max(jump, Math.abs(x[i] - x[i - 1])); }
    if (pk < 1e-4) continue;
    worst = Math.max(worst, 20 * Math.log10(jump / (pk * own)));
  }
  console.log(worst.toFixed(2));
  process.exit(0);
}

if (cmd === 'peak') {
  // The largest sample anywhere in the recording, either channel, in dBFS.
  let p = 0;
  for (const sig of rec) for (const v of sig) p = Math.max(p, Math.abs(v));
  console.log((20 * Math.log10(p + 1e-12)).toFixed(2));
  process.exit(0);
}

if (cmd === 'gate') {
  // The gate's three numbers: the worst THD of a burst (harmonics 2..10 over
  // its middle two cycles), the most the pilot moves during a burst against
  // its level alone (dB), and the largest sample (dBFS). The recording starts
  // at the graph's latency, so the bursts are found by their 50 Hz energy.
  const x = rec[0], N = 1920;                         // 40 ms: 2 cycles of 50 Hz
  const bin = (seg, f) => { let re = 0, im = 0; for (let i = 0; i < seg.length; i++) { const w = 2 * Math.PI * f * i / RATE; re += seg[i] * Math.cos(w); im -= seg[i] * Math.sin(w); } return Math.hypot(re, im) * 2 / seg.length; };
  // The first sample of signal: the pilot alone starts the recording.
  let start = 0;
  while (start < x.length && Math.abs(x[start]) < 0.005) start++;
  const ref = bin(x.subarray(start + Math.round(RATE * 0.2), start + Math.round(RATE * 0.2) + N), GATE_PILOT);
  // The first burst is the first loud sample after the pilot alone; the rest
  // follow every 500 ms. Each is measured over its middle two cycles, past the
  // limiter's attack and clear of the noise either side.
  let onset = start + Math.round(RATE * 0.4);
  while (onset < x.length && Math.abs(x[onset]) < 0.3) onset++;
  let worstThd = 0, worstPump = 0, found = 0;
  for (let k = 0; k < GATE_BURSTS; k++) {
    const a = onset + Math.round(RATE * (k * 0.5 + 0.02));
    if (a + N > x.length) break;
    const seg = x.subarray(a, a + N), fund = bin(seg, 50);
    if (fund < 0.1) continue;
    found++;
    let harm = 0;
    for (let h = 2; h <= 10; h++) harm += Math.pow(bin(seg, 50 * h), 2);
    worstThd = Math.max(worstThd, 100 * Math.sqrt(harm) / fund);
    worstPump = Math.max(worstPump, Math.abs(20 * Math.log10(bin(seg, GATE_PILOT) / ref)));
  }
  let p = 0;
  for (const sig of rec) for (const v of sig) p = Math.max(p, Math.abs(v));
  console.log(worstThd.toFixed(2) + ' ' + worstPump.toFixed(2) + ' ' + (20 * Math.log10(p + 1e-12)).toFixed(2) + ' ' + found);
  process.exit(0);
}

done(false, 'unknown command ' + cmd);
