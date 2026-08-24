/**
 * Taxi Monitor Bridge — live E2E instrumentation for Client/Driver WebView.
 * Button/screen events appear in Admin Blackbox within ~1s (Socket.IO + HTTP fallback).
 */
(function (global) {
  if (global.__taxiMonitorBridgeInstalled) return;
  global.__taxiMonitorBridgeInstalled = true;

  const SOURCE = global.__TAXI_MONITOR_SOURCE || (global.Android ? "driver" : "client");

  const SCREEN_SELECTORS = [
    { id: "step1", name: "driver_step1", kind: "overlay" },
    { id: "step2", name: "driver_step2", kind: "overlay" },
    { id: "clientChatOverlay", name: "client_chat", cls: "open", kind: "overlay" },
    { id: "client-monitor-box", name: "client_monitor", kind: "overlay" },
    { id: "infoOverlay", name: "info_overlay", kind: "overlay" },
    { id: "bookingForm", name: "booking_form", kind: "screen" },
    { id: "priceResult", name: "price_result", kind: "screen" },
    { id: "waitingOverlay", name: "waiting_overlay", kind: "overlay" },
    { id: "driverReadyOverlay", name: "driver_ready", kind: "overlay" },
    { id: "cannotFindOverlay", name: "cannot_find", kind: "overlay" },
    { id: "newDriverOverlay", name: "new_driver", kind: "overlay" },
    { id: "unconfirmedOverlay", name: "unconfirmed", kind: "overlay" },
    { id: "aitiologiaOverlay", name: "aitiologia", kind: "overlay" },
    { id: "folderOverlay", name: "folder", kind: "overlay" },
    { id: "cancelConfirmOverlay", name: "cancel_confirm", kind: "overlay" },
    { id: "loginScreen", name: "login", kind: "screen" },
    { id: "homeScreen", name: "home", kind: "screen" },
  ];

  let _lastScreenState = { screens: [], overlays: [], at: 0 };
  let _lastVisibleNames = new Set();
  let _activeTimers = {};
  let _hookTimer = null;
  let _traceSocket = null;
  let _traceSocketUrl = null;

  function traceApiUrl() {
    try {
      if (global.TAXI_API_URL) return String(global.TAXI_API_URL).replace(/\/$/, "");
      return String(localStorage.getItem("taxi_last_api_url") || "http://167.233.49.140").replace(/\/$/, "");
    } catch (e) {
      return "http://167.233.49.140:3000";
    }
  }

  function emitTraceSocket(payload) {
    try {
      const url = traceApiUrl();
      if (!_traceSocket || _traceSocketUrl !== url) {
        _traceSocketUrl = url;
        if (typeof global.io === "function") {
          _traceSocket = global.io(url, { transports: ["websocket", "polling"] });
        } else if (!global.__taxiTraceSocketLoading) {
          global.__taxiTraceSocketLoading = true;
          const s = global.document.createElement("script");
          s.src = url + "/socket.io/socket.io.min.js";
          s.onload = function () {
            global.__taxiTraceSocketLoading = false;
            _traceSocket = global.io(url, { transports: ["websocket", "polling"] });
            _traceSocket.emit("monitor:telemetry", payload);
          };
          global.document.head.appendChild(s);
          return;
        }
      }
      if (_traceSocket) {
        const fire = () => {
          try {
            _traceSocket.emit("monitor:telemetry", payload);
          } catch (e) {}
        };
        if (_traceSocket.connected) fire();
        else _traceSocket.once("connect", fire);
      }
    } catch (e) {}
  }

  function send(category, message, meta) {
    const m = meta || {};
    const payload = {
      source: SOURCE,
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
    };
    emitTraceSocket(payload);
    try {
      if (typeof global.__taxiMonitorLog === "function") {
        global.__taxiMonitorLog(SOURCE, category, message, m);
      }
    } catch (e) {}
  }

  function sendEvent(eventType, opts) {
    const o = opts || {};
    const group = o.group || (SOURCE === "driver" ? "driver" : "client");
    send(o.category || group, o.message || eventType, {
      eventType,
      group,
      bookingId: o.bookingId || o.booking_id || null,
      driverPin: o.driverPin || o.driver_pin || global.driverPin || global.currentDriverPin || null,
      clientPhone: o.clientPhone || null,
      button: o.button || null,
      action: o.action || eventType,
      result: o.result || null,
      success: o.success !== undefined ? o.success : null,
      error: o.error || null,
      request: o.request || null,
      response: o.response || null,
      level: o.level || (o.success === false || o.error ? "error" : "info"),
      ...o.meta,
    });
  }

  function bookingId() {
    return global.currentBookingId || (global.__clientMonitorState && global.__clientMonitorState.bookingId) || null;
  }

  function isVisible(el) {
    if (!el) return false;
    try {
      const st = global.getComputedStyle(el);
      if (st.display === "none" || st.visibility === "hidden" || Number(st.opacity) === 0) return false;
      if (el.classList && el.classList.contains("hidden")) return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    } catch (e) {
      return false;
    }
  }

  function scanScreenState() {
    const visible = [];
    const overlays = [];
    for (const s of SCREEN_SELECTORS) {
      const el = global.document.getElementById(s.id);
      if (!el) continue;
      let vis = isVisible(el);
      if (s.cls && el.classList) vis = vis || el.classList.contains(s.cls);
      if (vis) {
        const entry = { name: s.name, id: s.id, kind: s.kind || "screen", z: parseInt(global.getComputedStyle(el).zIndex, 10) || 0 };
        if (entry.kind === "overlay") overlays.push(entry);
        else visible.push(entry);
      }
    }
    if (global.__clientMonitorState && global.__clientMonitorState.type && global.__clientMonitorState.type !== "idle") {
      visible.push({ name: "monitor_" + global.__clientMonitorState.type, id: "clientMonitorState", kind: "screen", z: 0 });
    }
    return { screens: visible, overlays, at: Date.now() };
  }

  function detectOverlap(state, cause) {
    const all = [...state.screens, ...state.overlays];
    if (all.length < 2) return;
    const sorted = all.slice().sort((a, b) => b.z - a.z);
    const front = sorted[0];
    const back = sorted[1];
    if (front.name === back.name) return;
    sendEvent("SCREEN_OVERLAP_ERROR", {
      group: "screen",
      category: "screen",
      message: `SCREEN_OVERLAP: ${front.name} πάνω από ${back.name}`,
      level: "error",
      bookingId: bookingId(),
      meta: { frontScreen: front.name, backScreen: back.name, cause, visible: all.map((x) => x.name) },
    });
  }

  function reportScreen(cause) {
    const state = scanScreenState();
    const allNames = new Set([...state.screens, ...state.overlays].map((s) => s.name));
    for (const name of allNames) {
      if (!_lastVisibleNames.has(name)) {
        const entry = [...state.screens, ...state.overlays].find((s) => s.name === name);
        const isOverlay = entry && entry.kind === "overlay";
        sendEvent(isOverlay ? "overlay_opened" : "screen_opened", {
          group: "screen",
          category: "screen",
          message: isOverlay ? `Overlay: ${name}` : `Οθόνη: ${name}`,
          bookingId: bookingId(),
          meta: { screen: name, cause },
        });
      }
    }
    _lastVisibleNames = allNames;

    const changed =
      JSON.stringify(state.screens.map((s) => s.name)) !== JSON.stringify(_lastScreenState.screens.map((s) => s.name)) ||
      JSON.stringify(state.overlays.map((s) => s.name)) !== JSON.stringify(_lastScreenState.overlays.map((s) => s.name));
    if (changed) {
      sendEvent("screen_state", {
        group: "screen",
        category: "screen",
        message: `State: ${[...state.screens, ...state.overlays].map((s) => s.name).join(", ") || "idle"}`,
        bookingId: bookingId(),
        meta: { screens: state.screens, overlays: state.overlays, cause },
      });
      detectOverlap(state, cause);
      _lastScreenState = state;
    }
  }

  function reportTimer(name, phase, opts) {
    const o = opts || {};
    const key = name + ":" + (o.bookingId || "");
    if (phase === "started") _activeTimers[key] = { name, startedAt: Date.now(), remaining: o.remaining };
    if (phase === "expired" || phase === "cancelled") delete _activeTimers[key];
    sendEvent("timer_" + phase, {
      group: "timer",
      category: "timer",
      message: `Timer ${name}: ${phase}${o.remaining != null ? " (" + o.remaining + "ms)" : ""}`,
      bookingId: o.bookingId || null,
      driverPin: o.driverPin || null,
      meta: { timer: name, phase, remaining: o.remaining, ...o },
    });
  }

  function wrapFn(target, name, before, after) {
    const fn = target[name];
    if (typeof fn !== "function" || fn.__taxiWrapped) return false;
    const wrapped = function (...args) {
      let out;
      try {
        if (before) before(name, args);
      } catch (e) {}
      out = fn.apply(this, args);
      try {
        if (after) {
          const r = after(name, args, out);
          if (r && typeof r.then === "function") {
            r.then((v) => {
              try {
                after(name, args, v, true);
              } catch (e) {}
            }).catch((err) => {
              sendEvent("error", { group: SOURCE, message: name + " failed: " + (err && err.message), level: "error", error: err && err.message });
            });
          }
        }
      } catch (e) {}
      return out;
    };
    wrapped.__taxiWrapped = true;
    target[name] = wrapped;
    return true;
  }

  function installFunctionHooks() {
    const hooks =
      SOURCE === "driver"
        ? [
            {
              name: "showBooking",
              event: "incoming_booking",
              msg: (args) => "Incoming booking: " + args[0],
              bid: (args) => args[0],
            },
            {
              name: "accept",
              event: "step1_yes",
              msg: () => "Step1 ΝΑΙ",
              bid: () => bookingId(),
            },
            {
              name: "cannotStep1",
              event: "step1_no",
              msg: () => "Step1 ΟΧΙ",
              bid: () => bookingId(),
            },
            {
              name: "step1Timeout",
              event: "step1_timeout",
              msg: () => "Step1 timeout",
              bid: () => bookingId(),
            },
            {
              name: "sendOffer",
              event: "offer_sent",
              msg: () => "Offer sent",
              bid: () => bookingId(),
            },
            {
              name: "doLogout",
              event: "logout",
              msg: () => "Logout",
            },
          ]
        : [
            {
              name: "__clientShowPriceReal",
              event: "show_price",
              msg: () => "Δείξε Τιμή / price overlay",
            },
            {
              name: "acceptOffer",
              event: "accept_offer",
              msg: (args) => "Accept offer " + args[0],
              bid: (args) => args[0],
            },
            {
              name: "cancelBooking",
              event: "reject_offer",
              msg: (args) => "Reject/decline offer " + args[0],
              bid: (args) => args[0],
            },
            {
              name: "declineRetry",
              event: "reject_offer",
              msg: () => "Decline retry / new driver NO",
              bid: () => bookingId(),
            },
            {
              name: "goBack",
              event: "back",
              msg: () => "Back",
              bid: () => bookingId(),
            },
          ];

    for (const h of hooks) {
      wrapFn(global, h.name, function (_name, args) {
        sendEvent(h.event, {
          group: SOURCE,
          category: "action",
          message: h.msg(args),
          bookingId: h.bid ? h.bid(args) : bookingId(),
          button: h.name,
        });
        setTimeout(() => reportScreen("hook:" + h.name), 30);
      });
    }

    if (SOURCE === "driver" && typeof global.setActiveFromAndroid === "function") {
      wrapFn(global, "setActiveFromAndroid", function (_name, args) {
        const on = args[0] === 1 || args[0] === true || args[0] === "1";
        sendEvent(on ? "active_on" : "active_off", {
          group: "driver",
          category: "action",
          message: on ? "Active ON" : "Active OFF",
          driverPin: global.driverPin || global.currentDriverPin || null,
        });
      });
    }

    const step2Cancel = global.document.querySelector('[onclick*="cancelStep2"],#btnCancelStep2');
    if (step2Cancel && !step2Cancel.__taxiClickHook) {
      step2Cancel.__taxiClickHook = true;
      step2Cancel.addEventListener("click", function () {
        sendEvent("step2_cancel", { group: "driver", message: "Step2 cancel", bookingId: bookingId() });
      }, true);
    }
  }

  function installClickMapper() {
    if (global.__taxiClickMonitorInstalled) return;
    global.__taxiClickMonitorInstalled = true;
    global.document.addEventListener(
      "click",
      function (e) {
        try {
          const el = e.target && e.target.closest ? e.target.closest("button,.main,.gold,[onclick]") : null;
          if (!el) return;
          const label = (el.id || el.textContent || el.getAttribute("onclick") || "").trim().replace(/\s+/g, " ").slice(0, 100);
          if (!label) return;
          const t = label.toLowerCase();
          let eventType = "button_press";
          if (SOURCE === "client") {
            if (/δείξε|show.*price|τιμή/i.test(t)) eventType = "show_price";
            else if (/κράτηση|book/i.test(t)) eventType = "make_booking";
            else if (/ακύρωση|cancel/i.test(t)) eventType = "cancel";
            else if (/ναι|yes|accept/i.test(t)) eventType = "accept_offer";
            else if (/όχι|no|decline/i.test(t)) eventType = "reject_offer";
            else if (/πίσω|back/i.test(t)) eventType = "back";
          } else {
            if (/cannotstep1|btnno|όχι/i.test(t)) eventType = "step1_no";
            else if (/accept|ναι|yes/i.test(t)) eventType = "step1_yes";
            else if (/offer|προσφορ|sendoffer/i.test(t)) eventType = "offer_sent";
            else if (/cancel|ακύρωση/i.test(t)) eventType = "step2_cancel";
            else if (/logout/i.test(t)) eventType = "logout";
          }
          sendEvent(eventType, {
            group: SOURCE,
            category: "click",
            message: "Κλικ: " + label,
            button: label,
            bookingId: bookingId(),
          });
          setTimeout(() => reportScreen("click:" + eventType), 30);
        } catch (x) {}
      },
      true
    );
  }

  function watchDriverSteps() {
    if (SOURCE !== "driver") return;
    const step1 = global.document.getElementById("step1");
    const step2 = global.document.getElementById("step2");
    let was1 = false;
    let was2 = false;
    setInterval(function () {
      const v1 = step1 && isVisible(step1);
      const v2 = step2 && isVisible(step2);
      if (v1 && !was1) {
        sendEvent("step1_opened", { group: "driver", message: "Step1 opened", bookingId: bookingId() });
        reportTimer("step1", "started", { bookingId: bookingId(), remaining: 30000 });
        reportScreen("step1_open");
      }
      if (!v1 && was1) reportTimer("step1", "cancelled", { bookingId: bookingId() });
      if (v2 && !was2) {
        sendEvent("step2_opened", { group: "driver", message: "Step2 opened", bookingId: bookingId() });
        reportTimer("step2", "started", { bookingId: bookingId() });
        reportScreen("step2_open");
      }
      if (!v2 && was2) reportTimer("step2", "cancelled", { bookingId: bookingId() });
      was1 = v1;
      was2 = v2;
    }, 400);
  }

  function watchClientMonitorState() {
    if (SOURCE !== "client") return;
    let lastType = null;
    setInterval(function () {
      const st = global.__clientMonitorState || {};
      const t = st.type || "idle";
      if (t !== lastType) {
        sendEvent("screen_state", {
          group: "screen",
          category: "screen",
          message: "Monitor state → " + t,
          bookingId: st.bookingId || null,
          meta: { monitorType: t, previous: lastType },
        });
        lastType = t;
        reportScreen("monitor_state:" + t);
      }
    }, 300);
  }

  function watchOverlayMutations() {
    const obs = new MutationObserver(function () {
      reportScreen("mutation");
    });
    try {
      obs.observe(global.document.body, { attributes: true, childList: true, subtree: true, attributeFilter: ["style", "class"] });
    } catch (e) {}
  }

  function watchNetwork() {
    global.addEventListener("online", function () {
      sendEvent("network_online", { group: "network", category: "network", message: "Network: ONLINE" });
    });
    global.addEventListener("offline", function () {
      sendEvent("network_offline", { group: "network", category: "network", message: "Network: OFFLINE", level: "warn" });
    });
    if (!global.navigator.onLine) {
      sendEvent("network_offline", { group: "network", category: "network", message: "Network: OFFLINE (startup)", level: "warn" });
    }
  }

  function boot() {
    sendEvent("app_opened", { group: SOURCE, message: SOURCE === "driver" ? "Driver app opened" : "Client app opened" });
    installClickMapper();
    installFunctionHooks();
    _hookTimer = setInterval(installFunctionHooks, 800);
    setTimeout(function () {
      if (_hookTimer) clearInterval(_hookTimer);
    }, 180000);
    watchDriverSteps();
    watchClientMonitorState();
    watchOverlayMutations();
    watchNetwork();
    setInterval(() => reportScreen("periodic"), 1500);
    reportScreen("boot");
  }

  global.__taxiMonitorEvent = sendEvent;
  global.__taxiMonitorScreen = reportScreen;
  global.__taxiMonitorTimer = reportTimer;
  global.__taxiMonitorIncoming = function (id, meta) {
    sendEvent("incoming_booking", { group: "driver", message: "Incoming booking: " + id, bookingId: id, meta });
  };

  if (global.document.readyState === "loading") {
    global.document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})(typeof window !== "undefined" ? window : globalThis);
