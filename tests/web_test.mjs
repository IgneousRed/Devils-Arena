import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {runInNewContext} from 'node:vm';

const source = readFileSync(new URL('../web/dev.js', import.meta.url), 'utf8');
const SNAPSHOT = 'devils-due.dev.snapshot';

test('replay upload reports startup failure instead of waiting indefinitely', async () => {
  const recordingSource = readFileSync(new URL('../web/recording.js', import.meta.url), 'utf8');
  const elements = {button:{}, input:{}, '[role=status]':{textContent:''}};
  const tools = {style:{}, querySelector:selector => elements[selector]};
  const timers = new Map();
  let nextTimer = 0;
  const context = {
    location:{search:''}, window:{},
    document:{createElement:() => tools, body:{append() {}},
      getElementById:() => ({textContent:'Unable to run the game. Please reload the page.'})},
    TextEncoder, TextDecoder,
    setTimeout(callback, milliseconds) {timers.set(++nextTimer, {callback, milliseconds}); return nextTimer;},
    clearTimeout:id => timers.delete(id),
  };
  runInNewContext(recordingSource, context);
  const input = {files:[{size:2, text:async () => '{}'}], value:'recording.jsonl'};
  const upload = elements.input.onchange({target:input});
  await new Promise(setImmediate); // Let the selected file finish reading across the VM boundary.
  assert.equal(timers.size, 1);
  const deadline = [...timers.values()][0];
  assert.equal(deadline.milliseconds, 30000);
  deadline.callback(); // Advance the deadline without a real-time wait.
  await upload;
  assert.match(elements['[role=status]'].textContent, /Replay player did not start: Unable to run the game/);
  assert.equal(input.value, '', 'Allow the same recording to be selected after recovery');
  assert.equal(timers.size, 0, 'Clean up the startup deadline after rejection');
  assert.equal(context.window.devilRecording.playing, false, 'A failed startup must not pause the live game');
});

function recovery(snapshot, archives = [], rejectArchive = false) {
  const values = new Map([[SNAPSHOT, snapshot], ...archives]);
  const events = new Map();
  const documentEvents = new Map();
  const timers = new Map();
  const navigations = [];
  const banner = {style:{}};
  let statusResponse;
  let nextTimer = 0;
  const context = {
    location: {pathname:`/${'a'.repeat(32)}/`, replace:path => navigations.push(path)},
    document: {hidden:false, createElement:() => banner, addEventListener:(name, callback) => documentEvents.set(name, callback)},
    sessionStorage: {
      getItem:key => values.get(key) ?? null,
      setItem(key, value) {
        if (rejectArchive && key.startsWith(`${SNAPSHOT}.v`)) throw new Error('storage full');
        values.set(key, value);
      },
      removeItem:key => values.delete(key),
    },
    window: {addEventListener:(name, callback) => events.set(name, callback)},
    setTimeout(callback) {timers.set(++nextTimer, callback); return nextTimer;},
    clearTimeout:id => timers.delete(id), fetch:() => new Promise(resolve => {statusResponse = resolve;}),
    TextDecoder, TextEncoder, Uint8Array,
  };
  const memory = {buffer:new ArrayBuffer(16384)};
  let live = JSON.stringify({...JSON.parse(snapshot), version:3});
  const exports = {
    memory, web_reload_capacity:() => 16384, web_reload_buffer:() => 0,
    web_restore:() => true,
    web_snapshot() {
      const bytes = new TextEncoder().encode(live);
      new Uint8Array(memory.buffer).set(bytes);
      return bytes.length;
    },
  };
  runInNewContext(source, context);
  return {
    values, events, documentEvents, timers, navigations, banner, document:context.document, storage:context.sessionStorage, exports, api:context.window.devilDev,
    setSnapshot(data) {live = JSON.stringify(data);},
    respond(status) {statusResponse({ok:true, json:async () => status});},
  };
}

test('distinct originals from the same schema survive later capture', () => {
  const first = JSON.stringify({version:2, data:{marker:'first'}});
  const second = JSON.stringify({version:2, data:{marker:'second'}});
  const run = recovery(second, [[`${SNAPSHOT}.v2`, first]]);
  assert.equal(run.api.ready(run.exports), true);
  assert.equal(run.api.ready(run.exports), true, 'Restoring twice reuses the existing archive');
  assert.equal(run.api.started(run.exports), true);
  run.events.get('pagehide')();
  assert.equal(run.values.get(`${SNAPSHOT}.v2`), first);
  assert.equal(run.values.get(`${SNAPSHOT}.v2.1`), second);
  assert.equal(run.values.size, 3);
  assert.equal(JSON.parse(run.values.get(SNAPSHOT)).version, 3);
});

test('archive failure keeps the original recovery data', () => {
  const original = JSON.stringify({version:1, data:{marker:'retained'}});
  const run = recovery(original, [], true);
  assert.equal(run.api.ready(run.exports), false);
  assert.equal(run.api.started(run.exports), false);
  run.events.get('pagehide')();
  assert.equal(run.values.get(SNAPSHOT), original);
});

test('a hidden tab can wait for its first frame without rejecting the build', () => {
  const original = JSON.stringify({version:3, data:{marker:'retained'}});
  const run = recovery(original);
  assert.equal(run.api.ready(run.exports), true);
  const queuedTimeout = [...run.timers.values()][0];
  run.document.hidden = true;
  run.documentEvents.get('visibilitychange')();
  assert.equal(run.timers.size, 0, 'Do not time out while animation frames are suspended');
  queuedTimeout(); // A callback already queued before the visibility event is also harmless.
  run.document.hidden = false;
  run.documentEvents.get('visibilitychange')();
  assert.equal(run.timers.size, 1, 'Resume the startup deadline when the tab becomes visible');
  assert.equal(run.api.started(run.exports), true);
  assert.equal(run.timers.size, 0);
  assert.equal(run.values.get(SNAPSHOT), original);
});

test('a visible startup that never draws still times out', () => {
  const original = JSON.stringify({version:3, data:{marker:'retained'}});
  const run = recovery(original);
  assert.equal(run.api.ready(run.exports), true);
  [...run.timers.values()][0]();
  assert.equal(run.api.started(run.exports), false);
  assert.equal(run.values.get(SNAPSHOT), original);
});

test('a running game failure preserves progress and can load a source fix', async () => {
  const original = JSON.stringify({version:3, data:{marker:'before startup'}});
  const run = recovery(original);
  assert.equal(run.api.ready(run.exports), true);
  assert.equal(run.api.started(run.exports), true);
  const latest = {version:3, data:{marker:'progress after startup'}};
  run.setSnapshot(latest);
  run.api.failed(new Error('render fixture'));
  assert.deepEqual(JSON.parse(run.values.get(SNAPSHOT)), latest, 'Capture the last committed state when the frame loop stops');
  run.events.get('pagehide')();
  assert.deepEqual(JSON.parse(run.values.get(SNAPSHOT)), latest, 'Refresh can still capture a stopped game');
  run.respond({version:'a'.repeat(32), building:false, error:''});
  await new Promise(setImmediate);
  assert.equal(run.banner.hidden, false, 'A healthy server response cannot hide a stopped frame loop');
  assert.match(run.banner.textContent, /Game stopped:.*Waiting for a source fix/);
  [...run.timers.values()][0]();
  const next = 'b'.repeat(32);
  run.respond({version:next, building:false, error:''});
  await new Promise(setImmediate); // Drain the resolved status request without a clock-based wait.
  assert.deepEqual(run.navigations, [`/${next}/`], 'A later source build can recover without a manual refresh');
  assert.deepEqual(JSON.parse(run.values.get('devils-due.dev.pending')), {from:'a'.repeat(32), to:next});
});

test('failed capture after a running game error retains recovery data and permits a later retry', async () => {
  const original = JSON.stringify({version:3, data:{marker:'retained'}});
  const run = recovery(original);
  assert.equal(run.api.ready(run.exports), true);
  assert.equal(run.api.started(run.exports), true);
  const capture = run.exports.web_snapshot;
  run.exports.web_snapshot = () => 0;
  run.api.failed(new Error('runtime fixture'));
  assert.equal(run.values.get(SNAPSHOT), original);
  run.exports.web_snapshot = capture;
  run.respond({version:'b'.repeat(32), building:false, error:''});
  await new Promise(setImmediate);
  assert.deepEqual(run.navigations, [`/${'b'.repeat(32)}/`]);
  assert.equal(run.values.get(SNAPSHOT), original);
});

test('failed startup acknowledgment cannot expose a running recovery API', async () => {
  const original = JSON.stringify({version:3, data:{marker:'retained'}});
  const run = recovery(original);
  assert.equal(run.api.ready(run.exports), true);
  const read = run.storage.getItem;
  run.storage.getItem = key => {
    if (key === 'devils-due.dev.blocked') throw new Error('storage fixture');
    return read(key);
  };
  assert.equal(run.api.started(run.exports), false);
  run.storage.getItem = read;
  assert.equal(run.api.started(run.exports), false, 'A late callback must not revive the rejected startup');
  run.respond({version:'b'.repeat(32), building:false, error:''});
  await new Promise(setImmediate);
  assert.deepEqual(run.navigations, []);
  assert.equal(run.values.get(SNAPSHOT), original);
});

test('source navigation waits for a successful snapshot write and retries after storage recovers', async () => {
  const original = JSON.stringify({version:3, data:{marker:'before startup'}});
  const run = recovery(original);
  assert.equal(run.api.ready(run.exports), true);
  assert.equal(run.api.started(run.exports), true);
  const latest = {version:3, data:{marker:'latest'}};
  run.setSnapshot(latest);
  const write = run.storage.setItem;
  run.storage.setItem = () => {throw new Error('storage full');};
  run.respond({version:'b'.repeat(32), building:false, error:''});
  await new Promise(setImmediate);
  assert.deepEqual(run.navigations, []);
  assert.equal(run.values.get(SNAPSHOT), original);
  run.storage.setItem = write;
  [...run.timers.values()][0](); // Advance the scheduled poll by callback, not elapsed time.
  run.respond({version:'b'.repeat(32), building:false, error:''});
  await new Promise(setImmediate);
  assert.deepEqual(run.navigations, [`/${'b'.repeat(32)}/`]);
  assert.deepEqual(JSON.parse(run.values.get(SNAPSHOT)), latest);
});

test('a failed startup cannot resume when pending Wasm initialization completes', async () => {
  const html = readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
  const inline = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]).join('\n');
  const events = new Map();
  const status = {hidden:false, textContent:'Loading'};
  const canvas = {addEventListener() {}};
  let finishFetch, ready = 0, started = 0;
  const context = {
    document: {getElementById:id => id === 'status' ? status : canvas,
      createElement:() => ({}), body:{append() {}}},
    window: {addEventListener:(name, callback) => events.set(name, callback)},
    console:{error() {}, log() {}},
    odin: {WasmMemoryInterface:class {setIntSize() {} setExports() {} setMemory() {}},
      setupDefaultImports:() => ({})},
    fetch:() => new Promise(resolve => {finishFetch = resolve;}),
    WebAssembly:{instantiate:async () => ({instance:{exports:{memory:{}}}})},
    wasmExports:{_start() {started++;}, web_start() {started++;}},
    requestAnimationFrame() {throw new Error('A failed startup must not schedule rendering');},
  };
  runInNewContext(inline, context);
  context.Module.instantiateWasm({}, () => {ready++;});
  events.get('error')({target:context.window, message:'startup fixture', error:new Error('startup fixture')});
  finishFetch({ok:true, arrayBuffer:async () => new ArrayBuffer(0)});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ready, 0, 'A late successful download must not revive a rejected startup');
  context.Module.onRuntimeInitialized();
  assert.equal(started, 0);
  assert.equal(status.hidden, false);
  assert.match(status.textContent, /Unable to run/);
});
