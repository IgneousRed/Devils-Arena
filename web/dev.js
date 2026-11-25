// Debug builds activate recovery only on the local server's immutable version URLs.
(() => {
  // Keep recovery keys stable so older tabs and snapshots survive project renames.
  const SNAPSHOT = 'devils-due.dev.snapshot';
  const PENDING = 'devils-due.dev.pending';
  const BLOCKED = 'devils-due.dev.blocked';
  const POLL_INTERVAL_MS = 1000;
  const STARTUP_TIMEOUT_MS = 30000;
  if (location.search === '?replay') return;
  const version = location.pathname.split('/')[1];
  if (!/^[a-f0-9]{32}$/.test(version)) return;
  let api, switching = false, stopped = '';
  const banner = document.createElement('div');
  banner.style.cssText = 'position:fixed;right:8px;top:8px;z-index:10;max-width:480px;padding:8px;background:#182832;color:#fff;font:14px sans-serif';
  document.addEventListener('DOMContentLoaded', () => document.body.append(banner));
  const show = text => {
    banner.textContent = [stopped, text].filter(Boolean).join(' ');
    banner.hidden = !banner.textContent;
  };
  show('Starting development build…');

  function failed(error) {
    clearTimeout(startup);
    if (api && !switching) {
      // A stopped frame loop can still expose its last committed state. Keep
      // recovery and polling alive so a source fix can replace this instance.
      stopped = `Game stopped: ${error}. Waiting for a source fix.`;
      show('');
      preserve();
      return;
    }
    switching = true;
    api = undefined;
    show(`Update could not start: ${error}. Recovery snapshot retained.`);
    try {
      const pending = JSON.parse(sessionStorage.getItem(PENDING));
      if (pending && pending.to === version) {
        sessionStorage.setItem(BLOCKED, version);
        sessionStorage.removeItem(PENDING);
        location.replace(`/${pending.from}/`);
      }
    } catch (error) {show(`Recovery paused: ${error}. Snapshot retained.`);}
  }
  let startup;
  function watchStartup() {
    clearTimeout(startup);
    // Hidden tabs can suspend the first animation frame that acknowledges startup.
    if (!api && !switching && !document.hidden) {
      startup = setTimeout(() => {if (!document.hidden) failed('startup timed out');}, STARTUP_TIMEOUT_MS);
    }
  }
  document.addEventListener('visibilitychange', watchStartup);
  watchStartup();
  function capture(exports = api) {
    const size = exports.web_snapshot();
    if (!size) throw new Error('could not capture the active session');
    return new TextDecoder().decode(new Uint8Array(exports.memory.buffer, exports.web_reload_buffer(), size));
  }
  function preserve() {
    if (!api || switching) return false;
    try {sessionStorage.setItem(SNAPSHOT, capture());return true;}
    catch (error) {show(`Recovery paused: ${error}. Snapshot retained.`);return false;}
  }
  window.addEventListener('pagehide', preserve);
  window.devilDev = {
    failed,
    ready(exports) {
      if (switching) return false;
      try {
        const snapshot = sessionStorage.getItem(SNAPSHOT);
        if (snapshot) {
          const bytes = new TextEncoder().encode(snapshot);
          if (bytes.length > exports.web_reload_capacity()) throw new Error('snapshot too large');
          new Uint8Array(exports.memory.buffer, exports.web_reload_buffer(), bytes.length).set(bytes);
          if (!exports.web_restore(bytes.length)) throw new Error('snapshot schema or constraints are incompatible');
          const sourceVersion = JSON.parse(snapshot).version;
          const restored = JSON.parse(capture(exports));
          // Preserve the source schema before future captures replace the active recovery key.
          if (restored.version !== sourceVersion) {
            const prefix = `${SNAPSHOT}.v${sourceVersion}`;
            let original = prefix;
            // Older tabs can migrate different snapshots from the same schema.
            // Retain every distinct source; repeated restoration reuses its key.
            for (let index = 1; sessionStorage.getItem(original) && sessionStorage.getItem(original) !== snapshot; index++) {
              original = `${prefix}.${index}`;
            }
            sessionStorage.setItem(original, snapshot);
          }
        }
        return true;
      } catch (error) {failed(error);return false;}
    },
    started(exports) {
      if (switching) return false;
      try {
        // Restoration alone cannot prove the new renderer can draw its first frame.
        const pending = JSON.parse(sessionStorage.getItem(PENDING));
        const accepted = pending?.to === version;
        const blocked = accepted ? null : sessionStorage.getItem(BLOCKED);
        if (accepted) sessionStorage.removeItem(BLOCKED);
        sessionStorage.removeItem(PENDING);
        clearTimeout(startup);
        show(blocked ? 'Update rejected; recovered the previous session. See the terminal before retrying.' : '');
        api = exports;
        return true;
      } catch (error) {failed(error);return false;}
    },
  };

  async function poll() {
    try {
      const response = await fetch('/__dev/status', {cache:'no-store'});
      if (!response.ok) throw new Error('development server unavailable');
      const status = await response.json();
      if (status.error || status.building) show(status.error || 'Building changes…');
      else if (api && status.version === version && !sessionStorage.getItem(BLOCKED)) show('');
      if (!api || switching || !status.version || status.version === version || status.version === sessionStorage.getItem(BLOCKED)) return;
      // Store the recovery data before navigating; storage failure leaves this instance running.
      if (!preserve()) return;
      sessionStorage.setItem(PENDING, JSON.stringify({from:version, to:status.version}));
      switching = true;
      location.replace(`/${status.version}/`);
    } catch (error) {show(`Live reload paused: ${error}. Current game retained.`);}
    finally {if (!switching) setTimeout(poll, POLL_INTERVAL_MS);}
  }
  poll();
})();
