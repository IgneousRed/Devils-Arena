// Record the values consumed by the application boundary. Runtime/GPU resources
// are reconstructed; player storage is never consulted or changed by playback.
(() => {
  const MAX_BYTES = 64 * 1024 * 1024;
  const STARTUP_TIMEOUT_MS = 30000;
  const replayMode = location.search === '?replay';
  const lines = [];
  let exports, header, size = 0, presses = 0, error = '', playing = false, disposed = false;
  let attached;
  const ready = new Promise(resolve => {attached = resolve;});
  const encoder = new TextEncoder(), decoder = new TextDecoder();
  const tools = document.createElement('details');
  tools.style.cssText = 'position:fixed;bottom:8px;right:8px;z-index:20;max-width:320px;padding:8px;background:#201a24;color:#efe4d6;font:14px sans-serif;border:1px solid #6b586f;border-radius:6px';
  tools.innerHTML = '<summary>Replay tools</summary><p>Recordings stay in this tab. Download before closing or updating.</p><button type="button">Download recording</button> <label>Replay recording <input type="file" accept=".jsonl"></label><p role="status"></p>';
  const message = tools.querySelector('[role=status]');
  if (!replayMode) document.body.append(tools);
  function checkpoint() {
    const count = exports.web_recording_checkpoint();
    if (!count) throw new Error('Could not capture recording state');
    return JSON.parse(decoder.decode(new Uint8Array(exports.memory.buffer, exports.web_recording_buffer(), count)));
  }
  function apply(event, draw = false) {
    const bytes = encoder.encode(JSON.stringify(event));
    if (bytes.length > exports.web_recording_capacity()) throw new Error('Recording event is too large');
    new Uint8Array(exports.memory.buffer, exports.web_recording_buffer(), bytes.length).set(bytes);
    if (!exports.web_recording_apply(bytes.length, draw ? 1 : 0)) throw new Error('Invalid recording event');
  }
  function parse(text) {
    if (encoder.encode(text).length > MAX_BYTES) throw new Error('Recording exceeds 64 MiB');
    const records = text.trimEnd().split('\n').map(line => JSON.parse(line));
    const first = records.shift(), end = records.pop();
    if (first?.format !== 1 || !/^[a-f0-9]{64}$/.test(header.build) || first.build !== header.build) throw new Error('Recording belongs to a different application version');
    if (!first.initial || !end?.final) throw new Error('Recording is incomplete');
    for (const event of records) {
      if (![0, 1, 2].includes(event.kind)) throw new Error('Unknown recording event');
    }
    return {first, events:records, end};
  }
  async function waitReady() {
    let timer;
    try {await Promise.race([ready, new Promise((_, reject) => {timer = setTimeout(() => reject(new Error(`Replay player did not start: ${document.getElementById('status').textContent}`)), STARTUP_TIMEOUT_MS);})]);}
    finally {clearTimeout(timer);}
  }
  async function run(text, animate) {
    await waitReady();
    if (!replayMode) throw new Error('Playback requires an isolated player');
    if (disposed) throw new Error('Replay closed');
    const {first, events, end} = parse(text);
    apply({kind:1, frame:{width:1,height:1,pixel_ratio:1,scroll:0,mouse_x:0,mouse_y:0,seconds:0,focused:false,left_pressed:false,save_pressed:false,load_pressed:false,close:false,keys:0}, storage:{bytes:[],read_ok:false,write_ok:false}, data:Array.from(encoder.encode(JSON.stringify(first.initial)))});
    let frames = 0;
    for (let index = 0; index < events.length; index++) {
      if (disposed) throw new Error('Replay closed');
      let event = events[index];
      if (event.kind === 2) throw new Error('Orphaned storage result');
      if (event.kind === 0 && events[index + 1]?.kind === 2) {
        event = {...event, storage:events[++index].storage};
      }
      if (animate && event.kind === 0 && window.frameElement) {
        window.frameElement.style.width = `${event.frame.width / event.frame.pixel_ratio}px`;
        window.frameElement.style.height = `${event.frame.height / event.frame.pixel_ratio}px`;
      }
      apply(event, animate);
      if (event.kind === 0) frames++;
      if (animate) await new Promise(resolve => requestAnimationFrame(resolve));
      else if (index % 120 === 119) await new Promise(resolve => {
        // Message tasks yield without background-iframe timer throttling.
        const channel = new MessageChannel();
        channel.port1.onmessage = () => {channel.port1.close(); channel.port2.close(); resolve();};
        channel.port2.postMessage(null);
      });
    }
    const final = checkpoint();
    if (JSON.stringify(final) !== JSON.stringify(end.final)) throw new Error('Playback diverged from the recorded final state');
    return {matched:true, frames, final};
  }
  async function playback(text, animate) {
    await waitReady();
    const recording = parse(text); // Reject other versions before pausing or allocating a player.
    if (playing) throw new Error('A recording is already playing');
    playing = true;
    const overlay = document.createElement('div');
    overlay.style.cssText = animate ? 'position:fixed;inset:0;background:#131016;z-index:30;display:flex;flex-direction:column' : 'position:fixed;left:-20000px;top:0;width:960px;height:800px;pointer-events:none';
    const close = document.createElement('button');
    close.textContent = 'Close replay and return to game';
    const player = document.createElement('iframe');
    player.title = 'Recorded game';
    player.style.cssText = 'border:0;flex:1;width:100%;min-height:0';
    const firstFrame = recording.events.find(event => event.kind === 0)?.frame;
    if (firstFrame && animate) {
      player.style.width = `${firstFrame.width / firstFrame.pixel_ratio}px`;
      player.style.height = `${firstFrame.height / firstFrame.pixel_ratio}px`;
      player.style.flex = 'none';
      overlay.style.overflow = 'auto';
    }
    overlay.append(close, player);
    document.body.append(overlay);
    let cancelled = false, cancel;
    const cancellation = new Promise((_, reject) => {cancel = reject;});
    close.onclick = () => {cancelled = true; cancel(new Error('Replay closed'));};
    try {
      let startupTimer;
      try {await Promise.race([cancellation, new Promise((_, reject) => {
        startupTimer = setTimeout(() => reject(new Error('Replay player did not start within 30 seconds')), STARTUP_TIMEOUT_MS);
      }), new Promise((resolve, reject) => {
        player.onload = resolve;
        player.onerror = () => reject(new Error('Could not load replay player'));
        player.src = `${location.pathname}?replay`;
      }).then(() => player.contentWindow.devilRecording.ready)]);}
      finally {clearTimeout(startupTimer);}
      const result = await Promise.race([cancellation, player.contentWindow.devilRecording.run(text, animate)]);
      message.textContent = `Replay matched: ${result.frames} frames.`;
      return result;
    } catch (failure) {
      if (!cancelled) message.textContent = String(failure.message);
      throw failure;
    } finally {
      player.contentWindow?.devilRecording?.dispose();
      overlay.remove(); playing = false; document.getElementById('canvas').focus();
    }
  }
  window.devilRecording = {
    replayMode, ready,
    get playing() {return playing;},
    get count() {return lines.length - 1;},
    get presses() {return presses;},
    capture(line) {
      const event = JSON.parse(line);
      if (!header) {header = event;}
      if (event.kind === 0 && event.frame.left_pressed) presses++;
      if (replayMode || error) return;
      size += encoder.encode(line).length + 1;
      if (size > MAX_BYTES - 32768) {error = 'Recording reached 64 MiB and is incomplete. Start a new tab to record again.'; message.textContent = error; tools.open = true; return;}
      lines.push(line);
    },
    attach(instance) {exports = instance; attached(); if (disposed) exports.web_recording_close();},
    text() {
      if (error) throw new Error(error);
      if (!exports) throw new Error('Game has not started');
      return [...lines, JSON.stringify({final:checkpoint()})].join('\n') + '\n';
    },
    download() {
      const blob = new Blob([this.text()], {type:'application/x-ndjson'});
      const url = URL.createObjectURL(blob), link = document.createElement('a');
      link.href = url; link.download = `devils-arena-${header.build.slice(0,12)}.jsonl`; link.click();
      setTimeout(() => URL.revokeObjectURL(url), 0);
    },
    verify:text => playback(text, false),
    play:text => playback(text, true),
    run,
    dispose() {
      if (replayMode && !disposed) {disposed = true; if (exports) exports.web_recording_close();}
    },
  };
  tools.querySelector('button').onclick = () => {
    try {window.devilRecording.download(); message.textContent = 'Recording downloaded.';}
    catch (failure) {message.textContent = failure.message;}
  };
  tools.querySelector('input').onchange = async event => {
    try {
      const file = event.target.files[0];
      if (!file) return;
      if (file.size > MAX_BYTES) throw new Error('Recording exceeds 64 MiB');
      await window.devilRecording.play(await file.text());
    } catch (failure) {message.textContent = failure.message;}
    finally {event.target.value = '';}
  };
})();
