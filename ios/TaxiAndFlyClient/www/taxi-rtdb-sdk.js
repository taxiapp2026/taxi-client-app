/**
 * Drop-in Firebase RTDB replacement for taxi apps (VPS).
 * VPS production backend
 */

const VPS_URL = "http://167.233.49.140";
const API_KEY = (typeof window !== "undefined" && window.TAXI_API_KEY) || "bcfdddb083fa919977ebb3177bae87276442ef85e04205a0";

let _resolvedApiUrl = null;
let _resolvePromise = null;
let _ioPromise = null;
let _lastForceResolveAt = 0;

let _healthDiscovered = new Set();

function normalizeApiUrl(url) {
  const u = String(url || "").trim().replace(/\/$/, "");
  if (!u) return VPS_URL;
  // Same VPS on :3000 and :80 — always use nginx (:80) to avoid flip-flop delays.
  if (/^http:\/\/167\.233\.49\.140:3000$/i.test(u)) return VPS_URL;
  return u;
}

function getCandidates() {
  const w = typeof window !== "undefined" ? window : {};
  const fromCfg = Array.isArray(w.TAXI_API_CANDIDATES) ? w.TAXI_API_CANDIDATES : [];
  const single = w.TAXI_API_URL || "";
  let last = null;
  try { last = localStorage.getItem("taxi_last_api_url"); } catch (e) {}
  const base = [VPS_URL];
  const isLocal = (u) => /^(https?:\/\/)?(127\.0\.0\.1|localhost|10\.0\.2\.2)(:|\/|$)/i.test(String(u));
  return [...new Set([last, single, ...fromCfg, ...base, ..._healthDiscovered].filter(Boolean))]
    .filter((u) => !isLocal(u))
    .map((u) => normalizeApiUrl(String(u).replace(/\/$/, "")))
    .filter((u, i, arr) => arr.indexOf(u) === i);
}

async function probeUrl(url) {
  const target = normalizeApiUrl(url);
  try {
    const res = await fetchWithTimeout(`${target}/health`, {}, 2500);
    if (res.ok) return true;
    return false;
  } catch (e) {
    return false;
  }
}

export async function resolveApiUrl(force) {
  if (!force && _resolvedApiUrl) return _resolvedApiUrl;
  if (force) {
    const now = Date.now();
    if (now - _lastForceResolveAt < 30000 && _resolvedApiUrl) return _resolvedApiUrl;
    _lastForceResolveAt = now;
    _resolvedApiUrl = null;
    _resolvePromise = null;
    _ioPromise = null;
  }
  const w = typeof window !== "undefined" ? window : {};
  const preset = normalizeApiUrl(w.TAXI_API_URL ? String(w.TAXI_API_URL).replace(/\/$/, "") : "");
  if (!force && preset && !/^(https?:\/\/)?(127\.0\.0\.1|localhost|10\.0\.2\.2)(:|\/|$)/i.test(preset)) {
    if (await probeUrl(preset)) {
      _resolvedApiUrl = preset;
      return preset;
    }
  }
  if (!force && _resolvePromise) return _resolvePromise;
  _resolvePromise = (async () => {
    const candidates = getCandidates();
    for (const url of candidates) {
      if (await probeUrl(url)) {
        const hit = normalizeApiUrl(url);
        _resolvedApiUrl = hit;
        _ioPromise = null;
        try {
          localStorage.setItem("taxi_last_api_url", hit);
          if (typeof window !== "undefined") window.TAXI_API_URL = hit;
        } catch (e) {}
        return hit;
      }
    }
    _resolvedApiUrl = VPS_URL;
    return _resolvedApiUrl;
  })();
  return _resolvePromise;
}

async function apiBase() {
  await resolveApiUrl(false);
  return _resolvedApiUrl || VPS_URL;
}

const FETCH_TIMEOUT_MS = 8000;
const FETCH_WRITE_TIMEOUT_MS = 15000;

function monitorSource() {
  if (typeof window !== "undefined" && window.__TAXI_MONITOR_SOURCE) return String(window.__TAXI_MONITOR_SOURCE);
  if (typeof window !== "undefined" && window.Android) return "driver";
  return "client";
}

function monitorTelemetry(category, message, meta = {}) {
  try {
    const m = meta || {};
    const payload = {
      source: monitorSource(),
      group: m.group || category,
      category,
      eventType: m.eventType || null,
      message: String(message || "").slice(0, 500),
      meta: m,
      at: Date.now(),
      bookingId: m.bookingId || null,
      driverPin: m.driverPin || null,
      clientPhone: m.clientPhone || null,
      level: m.level || "info",
      success: m.success !== undefined ? m.success : null,
      error: m.error || null,
      button: m.button || null,
      action: m.action || null,
      result: m.result || null,
      request: m.request || null,
      response: m.response || null,
    };
    getSocket()
      .then((socket) => {
        const emit = () => {
          try {
            socket.emit("monitor:telemetry", payload);
          } catch (e) {}
        };
        if (socket.connected) emit();
        else socket.once("connect", emit);
      })
      .catch(() => {});
    apiBase()
      .then((base) => {
        fetch(`${base}/internal/monitor/telemetry`, {
          method: "POST",
          headers: headers(),
          body: JSON.stringify(payload),
          keepalive: true,
        }).catch(() => {});
      })
      .catch(() => {});
  } catch (e) {}
}

function shouldTraceHttp(shortUrl, method) {
  const u = String(shortUrl || "");
  if (u.includes("/internal/monitor/")) return false;
  if (u === "/health" || u.endsWith("/health")) return false;
  if (u.includes("/serverMessage")) return false;
  if (method === "POST" && /\/api\/bookings\/?$/.test(u)) return true;
  if (/\/api\/bookings\//.test(u) && method !== "GET") return true;
  return false;
}

if (typeof window !== "undefined") {
  window.__taxiMonitorLog = (source, category, message, meta) => {
    const prev = window.__TAXI_MONITOR_SOURCE;
    if (source) window.__TAXI_MONITOR_SOURCE = source;
    monitorTelemetry(category, message, meta || {});
    if (source) window.__TAXI_MONITOR_SOURCE = prev;
  };
  window.__taxiMonitorNetwork = (phase, endpoint, details) => {
    monitorTelemetry("network", `${phase} ${endpoint}`, {
      group: "network",
      eventType: "network_" + phase,
      phase,
      endpoint,
      ...details,
    });
  };
}

function loadMonitorBridge() {
  if (typeof document === "undefined" || document.querySelector("script[data-taxi-monitor-bridge]")) return;
  apiBase().then((base) => {
    const s = document.createElement("script");
    s.src = `${base}/taxi-monitor-bridge.js?v=${Date.now()}`;
    s.dataset.taxiMonitorBridge = "1";
    s.async = true;
    document.head.appendChild(s);
  }).catch(() => {});
}

async function fetchWithTimeout(url, opts = {}, ms = FETCH_TIMEOUT_MS) {
  const ctrl = typeof AbortController !== "undefined" ? new AbortController() : null;
  const timer = ctrl ? setTimeout(() => ctrl.abort(), ms) : null;
  const method = (opts && opts.method) || "GET";
  const shortUrl = String(url).replace(/^https?:\/\/[^/]+/, "");
  const t0 = Date.now();
  let reqBody;
  try {
    if (opts && opts.body && typeof opts.body === "string" && opts.body.length < 600) {
      reqBody = opts.body;
    }
  } catch (e) {}
  const traceHttp = shouldTraceHttp(shortUrl, method);
  try {
    const res = await fetch(url, ctrl ? { ...opts, signal: ctrl.signal } : opts);
    const latency = Date.now() - t0;
    if (traceHttp) {
      if (method === "POST" && /\/api\/bookings\/?$/.test(shortUrl) && res.ok) {
        try {
          const clone = res.clone();
          const j = await clone.json();
          const bookingId = j && (j.id || j.bookingId);
          monitorTelemetry("client", "Create booking OK", {
            group: "client",
            eventType: "create_booking",
            bookingId,
            success: true,
            request: reqBody ? { body: reqBody } : null,
            response: { statusCode: res.status, latency, id: bookingId },
          });
        } catch (e) {}
      } else {
        monitorTelemetry("network", `${method} ${shortUrl} → ${res.status} (${latency}ms)`, {
          group: "network",
          eventType: "http_response",
          endpoint: shortUrl,
          latency,
          success: res.ok,
        });
      }
    }
    return res;
  } catch (e) {
    const latency = Date.now() - t0;
    if (traceHttp) {
      monitorTelemetry("network", `✗ ${method} ${shortUrl}`, {
        group: "network",
        eventType: "http_error",
        endpoint: shortUrl,
        latency,
        level: "error",
        success: false,
        error: e && e.message,
      });
    }
    throw e;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

if (typeof window !== "undefined") {
  setTimeout(loadMonitorBridge, 8000);
}

async function withApiRetry(fn) {
  try {
    return await fn();
  } catch (e) {
    if (e && (e.name === "AbortError" || String(e.message || "").includes("abort"))) throw e;
    const now = Date.now();
    if (now - _lastForceResolveAt < 30000) throw e;
    _lastForceResolveAt = now;
    _resolvedApiUrl = null;
    _resolvePromise = null;
    _ioPromise = null;
    await resolveApiUrl(true);
    return await fn();
  }
}

function resolveApiKey() {
  if (typeof window !== "undefined" && window.TAXI_API_KEY) {
    return String(window.TAXI_API_KEY).trim();
  }
  return API_KEY || "";
}

function headers() {
  const h = { "Content-Type": "application/json" };
  const key = resolveApiKey();
  if (key) h["X-API-Key"] = key;
  if (typeof window !== "undefined" && window.__taxiAuthToken) {
    h["Authorization"] = `Bearer ${window.__taxiAuthToken}`;
  }
  return h;
}

function normPath(p) {
  return String(p || "").replace(/^\/+|\/+$/g, "").replace(/\.json$/i, "");
}

function generatePushId() {
  const t = Date.now().toString(36);
  const r = Math.random().toString(36).slice(2, 10);
  return `-${t}${r}`.slice(0, 20);
}

class DataSnapshot {
  constructor(val, refObj) {
    this._val = val;
    this.ref = refObj;
  }
  val() { return this._val; }
  exists() { return this._val !== null && this._val !== undefined; }
  get key() { return this.ref && this.ref.key ? this.ref.key : null; }
  child(path) {
    const parts = normPath(path).split("/").filter(Boolean);
    let value = this._val;
    for (const part of parts) {
      value = value !== null && typeof value === "object" ? value[part] : null;
    }
    return new DataSnapshot(value, new Ref(null, [this.ref && this.ref.path, ...parts].filter(Boolean).join("/")));
  }
  forEach(action) {
    if (this._val === null || typeof this._val !== "object") return false;
    for (const [key, value] of Object.entries(this._val)) {
      const childRef = new Ref(null, [this.ref && this.ref.path, key].filter(Boolean).join("/"));
      if (action(new DataSnapshot(value, childRef)) === true) return true;
    }
    return false;
  }
}

class Ref {
  constructor(db, path) {
    this._db = db;
    this.path = normPath(path);
  }
  key() {
    const parts = this.path.split("/");
    return parts[parts.length - 1] || null;
  }
  get key() {
    const parts = this.path.split("/");
    return parts[parts.length - 1] || null;
  }
  toString() { return this.path; }
}

async function getSocket() {
  const base = await apiBase();
  if (!_ioPromise) {
    _ioPromise = new Promise((resolve, reject) => {
      if (typeof window === "undefined") return reject(new Error("no window"));
      if (window.io) return resolve(window.io(base, { transports: ["websocket", "polling"] }));
      const s = document.createElement("script");
      s.src = `${base}/socket.io/socket.io.min.js`;
      s.onload = () => {
        if (window.io) resolve(window.io(base, { transports: ["websocket", "polling"] }));
        else reject(new Error("Socket.IO loaded without window.io"));
      };
      s.onerror = () => {
        try { s.remove(); } catch (e) {}
        reject(new Error("Socket.IO script load failed"));
      };
      document.head.appendChild(s);
    });
  }
  try {
    return await _ioPromise;
  } catch (e) {
    _ioPromise = null;
    throw e;
  }
}

const listeners = new Map();

async function ensureSocketListener(path) {
  const socket = await getSocket();
  if (!socket.__taxiRtdbBound) {
    socket.__taxiRtdbBound = true;
    socket.on("connect", () => {
      for (const subPath of listeners.keys()) {
        try { socket.emit("rtdb:subscribe", { path: subPath }); } catch (e) { console.error(e); }
      }
    });
    socket.on("rtdb:change", async ({ path: chPath }) => {
      for (const [subPath, cbs] of Array.from(listeners.entries())) {
        if (!cbs || cbs.size === 0) continue;
        if (chPath === subPath || chPath.startsWith(subPath + "/") || subPath.startsWith(chPath + "/")) {
          try {
            const fresh = await apiGet(subPath);
            const snap = new DataSnapshot(fresh, new Ref(null, subPath));
            Array.from(cbs).forEach((cb) => { try { cb(snap); } catch (e) { console.error(e); } });
          } catch (e) {
            if (subPath.indexOf("/chat") < 0) console.error("rtdb:change refresh failed", subPath, e);
          }
        }
      }
    });
  }
  if (!listeners.has(path)) {
    listeners.set(path, new Set());
    if (socket.connected) socket.emit("rtdb:subscribe", { path });
  }
}

async function apiGet(path) {
  return withApiRetry(async () => {
    const base = await apiBase();
    const res = await fetchWithTimeout(`${base}/rtdb/${encodeURI(path)}`, { headers: headers() });
    if (res.status === 404) {
      const clean = normPath(path);
      const cut = clean.lastIndexOf("/");
      if (cut > 0) {
        const parent = clean.slice(0, cut);
        const key = clean.slice(cut + 1);
        try {
          const parentRes = await fetchWithTimeout(`${base}/rtdb/${encodeURI(parent)}`, { headers: headers() });
          if (parentRes.ok) {
            const parentVal = await parentRes.json();
            if (parentVal && typeof parentVal === "object" && Object.prototype.hasOwnProperty.call(parentVal, key)) {
              return parentVal[key];
            }
          }
        } catch (e) {}
      }
      return null;
    }
    if (!res.ok) throw new Error(`GET ${path} ${res.status}`);
    return res.json();
  });
}

async function apiPut(path, body) {
  return withApiRetry(async () => {
    const base = await apiBase();
    const res = await fetchWithTimeout(`${base}/rtdb/${encodeURI(path)}`, {
      method: "PUT", headers: headers(), body: JSON.stringify(body),
    });
    if (!res.ok) {
      const isScalar = body === null || ["string", "number", "boolean"].includes(typeof body);
      if (res.status === 400 && isScalar) {
        const clean = normPath(path);
        const cut = clean.lastIndexOf("/");
        if (cut > 0) {
          const parent = clean.slice(0, cut);
          const key = clean.slice(cut + 1);
          const patch = {};
          patch[key] = body;
          return apiPatch(parent, patch);
        }
      }
      throw new Error(`PUT ${path} ${res.status}`);
    }
    return res.json();
  });
}

async function apiPatch(path, body) {
  return withApiRetry(async () => {
    const base = await apiBase();
    const res = await fetchWithTimeout(`${base}/rtdb/${encodeURI(path)}`, {
      method: "PATCH", headers: headers(), body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`PATCH ${path} ${res.status}`);
    return res.json();
  });
}

export function createTaxiDb() { return { __taxi: true }; }
export function getDatabase(_app) { return createTaxiDb(); }
export function ref(db, path) { return new Ref(db, path); }

export async function get(refOrQuery) {
  if (refOrQuery && refOrQuery.__query) {
    const q = refOrQuery;
    const base = await apiBase();
    const url = `${base}/rtdb-query?path=${encodeURIComponent(q.collection)}&orderBy=${encodeURIComponent(q.field)}&equalTo=${encodeURIComponent(q.equals)}`;
    const res = await fetchWithTimeout(url, { headers: headers() });
    if (!res.ok) throw new Error("query failed");
    const val = await res.json();
    return new DataSnapshot(val, ref(null, q.collection));
  }
  const r = refOrQuery;
  const val = await apiGet(r.path);
  return new DataSnapshot(val, r);
}

export async function getFast(r, timeoutMs = 1500) {
  const w = typeof window !== "undefined" ? window : {};
  const base = _resolvedApiUrl || String(w.TAXI_API_URL || VPS_URL).replace(/\/$/, "");
  const res = await fetchWithTimeout(
    `${base}/rtdb/${encodeURI(r.path)}`,
    { headers: headers(), cache: "no-store" },
    timeoutMs
  );
  if (res.status === 404) return new DataSnapshot(null, r);
  if (!res.ok) throw new Error(`GET fast ${r.path} ${res.status}`);
  return new DataSnapshot(await res.json(), r);
}

export async function set(r, value) { await apiPut(r.path, value); }
export async function update(r, patch) { await apiPatch(r.path, patch); }

async function collectionPushAsync(r, data) {
  return withApiRetry(async () => {
    const collection = normPath(r.path);
    const base = await apiBase();
    const res = await fetchWithTimeout(`${base}/rtdb/${encodeURIComponent(collection)}/push`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify(data),
    });
    if (!res.ok) throw new Error(`push ${collection} ${res.status}`);
    const j = await res.json();
    const id = String(j.name || generatePushId());
    return ref(r._db, `${collection}/${id}`);
  });
}

/** Firebase-compatible push — με data επιστρέφει Promise (server /push). */
export function push(r, data) {
  const collection = normPath(r.path);
  if (data !== undefined) {
    return collectionPushAsync(r, data);
  }
  const id = generatePushId();
  return ref(r._db, `${collection}/${id}`);
}

export function onValue(r, cb) {
  const path = r.path;
  let active = true;
  ensureSocketListener(path).then(() => {
    if (!active) return;
    if (!listeners.has(path)) listeners.set(path, new Set());
    listeners.get(path).add(cb);
    apiGet(path)
      .then((val) => { if (active) cb(new DataSnapshot(val, r)); })
      .catch(console.error);
  }).catch(console.error);
  return () => {
    active = false;
    off(r, cb);
  };
}

export function off(r, cb) {
  const path = r.path;
  const set = listeners.get(path);
  if (!set) return;
  if (cb) set.delete(cb);
  else set.clear();
  if (set.size === 0) listeners.delete(path);
}

export function query(r, orderByChild, equalToFn) {
  const field = orderByChild && orderByChild._field;
  const equals = equalToFn && equalToFn._value;
  return { __query: true, collection: r.path, field, equals };
}

export function orderByChild(field) { return { _field: field }; }
export function equalTo(value) { return { _value: value }; }
export function serverTimestamp() { return Date.now(); }

let _authUser = null;
const _authCbs = new Set();

export function getAuth() { return { currentUser: _authUser }; }

export async function signInAnonymously(_auth) {
  if (_authUser) {
    _authCbs.forEach((cb) => { try { cb(_authUser); } catch (e) {} });
    return { user: _authUser };
  }
  try {
    const base = await apiBase();
    const res = await fetchWithTimeout(
      `${base}/api/auth/anonymous`,
      { method: "POST", headers: headers() },
      5000
    );
    if (!res.ok) throw new Error("auth " + res.status);
    const j = await res.json();
    _authUser = { uid: j.uid || j.token || "anon" };
    if (typeof window !== "undefined") window.__taxiAuthToken = j.token || j.uid;
  } catch (e) {
    console.warn("VPS auth fallback", e);
    _authUser = { uid: "local_" + Date.now() };
    if (typeof window !== "undefined") window.__taxiAuthToken = _authUser.uid;
  }
  _authCbs.forEach((cb) => { try { cb(_authUser); } catch (e) {} });
  return { user: _authUser };
}

export function onAuthStateChanged(_auth, cb) {
  _authCbs.add(cb);
  if (_authUser) cb(_authUser);
  return () => _authCbs.delete(cb);
}

export function initializeApp() { return { __taxiApp: true }; }
export function getStorage() { return { __storage: true }; }
export function refStorage(_storage, path) { return { path: normPath(path), __fileRef: true }; }

export async function uploadBytes(fileRef, file) {
  const buf = await file.arrayBuffer();
  const bytes = new Uint8Array(buf);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  const b64 = btoa(binary);
  const payload = {
    name: file.name,
    contentType: file.type || "application/octet-stream",
    base64: b64,
    uploadedAt: Date.now(),
  };
  await apiPut(`files/${fileRef.path}`, payload);
  return { ref: fileRef };
}

export async function getDownloadURL(fileRef) {
  const base = await apiBase();
  return `${base}/files/${encodeURI(fileRef.path)}`;
}
