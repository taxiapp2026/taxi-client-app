/**
 * Επικοινωνία πελάτη — ίδιο πράσινο monitor όπως Αεροδρόμιο → Αθήνα.
 */
(function () {
  if (window.__monitorCommSimpleV1) return;
  window.__monitorCommSimpleV1 = true;

  function esc(v) {
    return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function isEn() {
    try {
      return String(window.lang || localStorage.getItem('appLang') || 'el').toLowerCase() === 'en';
    } catch (e) {
      return false;
    }
  }

  function hideLegacy() {
    try {
      [
        'driverUnconfirmedOverlay', 'findNewDriverOverlay', 'clientWaitExpiredOverlay',
        'clientCancelReasonOverlay', 'driverReadyOverlay', 'driverReadyAitiologiaOverlay',
        'driverMessageOverlay', 'driverWaitingOverlay'
      ].forEach(function (id) {
        var el = document.getElementById(id);
        if (el) el.style.display = 'none';
      });
      document.body.classList.remove('no-scroll');
      document.body.style.overflow = '';
    } catch (e) {}
  }

  function liveShell(msg, extra) {
    return '' +
      '<div class="airport-live-panel">' +
        '<div class="airport-live-screen">' +
          '<div class="airport-live-message">' + msg + '</div>' +
          (extra || '') +
        '</div>' +
      '</div>';
  }

  function btns(yesOn, noOn, yesLabel, noLabel) {
    return '<div class="cm-row">' +
      '<button type="button" class="airport-arrived-small" onclick="' + yesOn + '">' + yesLabel + '</button>' +
      '<button type="button" class="airport-arrived-small" style="background:#444;" onclick="' + noOn + '">' + noLabel + '</button>' +
    '</div>';
  }

  function ensureBox() {
    var info = document.getElementById('info');
    if (!info) return null;
    info.classList.add('client-monitor-host');
    info.style.display = 'block';
    var box = document.getElementById('clientCentralMonitor');
    if (!box) {
      box = document.createElement('div');
      box.id = 'clientCentralMonitor';
      info.innerHTML = '';
      info.appendChild(box);
    }
    return box;
  }

  function paint(msg, extra) {
    hideLegacy();
    var box = ensureBox();
    if (!box) return;
    box.className = '';
    box.classList.remove('uc-monitor-flow', 'cm-gold', 'cm-red', 'cm-green');
    box.innerHTML = liveShell(msg, extra);
  }

  window.__cmSimplePaint = function (msg, extra) { paint(msg, extra); };

  function patchClientMonitor() {
    if (!window.ClientMonitor) return false;
    window.ClientMonitor.render = function (_mode, _title, inner) {
      try {
        if (document.getElementById('clientMonitorAitiologiaText')) return;
        var st = window.__clientMonitorState || {};
        if (
          !window.__forceDriverReadyMonitorRender &&
          st.type === 'driverReady' &&
          document.getElementById('driverReadyMonitorCountdown')
        ) return;
      } catch (e) {}
      hideLegacy();
      var box = ensureBox();
      if (box) {
        box.className = '';
        box.innerHTML = String(inner || liveShell(isEn() ? 'WAITING' : 'ΑΝΑΜΟΝΗ'));
      }
    };
    window.ClientMonitor.idle = function () {
      try {
        var st = window.__clientMonitorState || {};
        if (st.type === 'driverReady' || st.type === 'athens230_aitiologia' || st.type === 'expired_aitiologia') return;
        if (document.getElementById('clientMonitorAitiologiaText')) return;
      } catch (e) {}
      window.__clientMonitorState = { type: 'idle' };
      paint(isEn() ? 'WAITING' : 'ΑΝΑΜΟΝΗ');
    };
    window.ClientMonitor.hidePopups = hideLegacy;
    return true;
  }

  window._cmRender = function (_mode, _title, inner) {
    try {
      if (document.getElementById('clientMonitorAitiologiaText')) return;
      var st = window.__clientMonitorState || {};
      if (
        !window.__forceDriverReadyMonitorRender &&
        st.type === 'driverReady' &&
        document.getElementById('driverReadyMonitorCountdown')
      ) return;
    } catch (e) {}
    hideLegacy();
    var box = ensureBox();
    if (box) {
      box.className = '';
      box.innerHTML = String(inner || liveShell(isEn() ? 'WAITING' : 'ΑΝΑΜΟΝΗ'));
    }
  };

  window._cmIdle = function () {
    try {
      var st = window.__clientMonitorState || {};
      if (st.type === 'driverReady' || st.type === 'athens230_aitiologia' || st.type === 'expired_aitiologia') return;
      if (document.getElementById('clientMonitorAitiologiaText')) return;
    } catch (e) {}
    try { window.__clientMonitorState = { type: 'idle' }; } catch (e) {}
    if (window.ClientMonitor && typeof window.ClientMonitor.idle === 'function') window.ClientMonitor.idle();
    else paint(isEn() ? 'WAITING' : 'ΑΝΑΜΟΝΗ');
  };

  var origReady = window.showDriverReadyOverlay;
  if (typeof origReady === 'function') {
    window.showDriverReadyOverlay = function (bookingId, bookingData) {
      origReady.apply(this, arguments);
      var bid = esc(String(bookingId || ''));
      paint(
        isEn() ? 'DRIVER READY' : 'Ο ΟΔΗΓΟΣ ΕΤΟΙΜΟΣ',
        '<div id="driverReadyMonitorCountdown" class="airport-live-message" style="font-family:monospace;font-size:22px;">--:--:--</div>' +
        '<button type="button" class="airport-arrived-small" style="width:100%;margin-top:8px;" onclick="closeDriverReadyOverlay(\'' + bid + '\')">' +
        (isEn() ? 'OK' : 'ΟΚ') + '</button>'
      );
    };
  }

  var origAit = window._openAthens230ClientAitiologia;
  if (typeof origAit === 'function') {
    window._openAthens230ClientAitiologia = function (bookingId, bookingData) {
      origAit.apply(this, arguments);
      paint(
        isEn() ? 'EXPLANATION' : 'ΑΙΤΙΟΛΟΓΙΑ',
        '<textarea id="clientMonitorAitiologiaText" class="cm-ta" placeholder="' + esc(isEn() ? 'Write...' : 'Γράψτε...') + '"></textarea>' +
        '<button type="button" class="airport-arrived-small" style="width:100%;margin-top:8px;" onclick="_clientMonitorSubmitAitiologia()">' +
        (isEn() ? 'SEND' : 'ΑΠΟΣΤΟΛΗ') + '</button>'
      );
    };
  }

  var _css = document.createElement('style');
  _css.textContent =
    '#clientCentralMonitor .cm-row{display:flex!important;gap:8px!important;width:100%!important;margin-top:8px!important;}' +
    '#clientCentralMonitor .cm-ta{width:100%!important;margin-top:8px!important;min-height:70px!important;border-radius:10px!important;border:1px solid rgba(25,255,119,.35)!important;background:rgba(0,0,0,.45)!important;color:#19ff77!important;padding:10px!important;font-size:15px!important;}' +
    '#clientCentralMonitor .client-monitor-title{display:none!important;}';
  document.head.appendChild(_css);

  function boot() {
    if (!patchClientMonitor()) {
      setTimeout(boot, 120);
      return;
    }
    try {
      var st = window.__clientMonitorState && window.__clientMonitorState.type;
      if (!st || st === 'idle') window.ClientMonitor.idle();
    } catch (e) {}
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
  setTimeout(boot, 400);
  setTimeout(boot, 1500);
})();
