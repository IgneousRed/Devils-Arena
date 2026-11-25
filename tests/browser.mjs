import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createServer} from 'node:http';
import {cp, mkdir, mkdtemp, readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
const {chromium, webkit} = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE).href);

const selectedEngine = process.argv[2];
if (process.argv.length > 3 || (selectedEngine && !['--engine=chromium', '--engine=webkit'].includes(selectedEngine))) {
  throw new Error('Usage: tests/browser.mjs [--engine=chromium|--engine=webkit]');
}

const root = resolve('.');
const fixture = await mkdtemp(resolve('.work/browser-'));
for (const directory of ['src', 'apps', 'scripts', 'tools', 'web', 'assets', 'nix']) {
  await cp(resolve(root, directory), resolve(fixture, directory), {recursive:true});
}
for (const file of ['LICENSE', 'flake.nix', 'flake.lock']) {
  await cp(resolve(root, file), resolve(fixture, file));
}
await cp(resolve(root, '.vendor/odin_ui'), resolve(fixture, '.vendor/odin_ui'), {recursive:true});
await mkdir(resolve(fixture, '.work'), {recursive:true});
const server = spawn('./scripts/run.sh', ['--port', '0'], {
  cwd:fixture, detached:true, env:process.env,
});
let output = '';
for (const stream of [server.stdout, server.stderr]) stream.on('data', data => {output += data;});
let origin;

async function waitFor(predicate, label) {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await delay(100);
  }
  throw new Error(`${label}\n${output}`);
}

async function status() {return (await fetch(origin + '/__dev/status')).json();}
const frames = page => page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))));
const ready = async page => {
  await page.waitForFunction(() => document.getElementById('status')?.hidden, null, {timeout:30000});
  await frames(page);
};
const snapshot = page => page.evaluate(() => {
  const size = wasmExports.web_snapshot();
  return JSON.parse(new TextDecoder().decode(new Uint8Array(wasmExports.memory.buffer, wasmExports.web_reload_buffer(), size)));
});
const restore = (page, data) => page.evaluate(data => {
  const bytes = new TextEncoder().encode(JSON.stringify(data));
  new Uint8Array(wasmExports.memory.buffer, wasmExports.web_reload_buffer(), bytes.length).set(bytes);
  return wasmExports.web_restore(bytes.length);
}, data);
const controls = page => page.evaluate(() => {
  const canvas = document.getElementById('canvas');
  const size = wasmExports.web_controls(canvas.clientWidth, canvas.clientHeight);
  return JSON.parse(new TextDecoder().decode(new Uint8Array(wasmExports.memory.buffer, wasmExports.web_reload_buffer(), size)));
});

async function click(page, kind, combatant = 0, acknowledged) {
  if (!acknowledged) {
    const before = (await snapshot(page)).data;
    acknowledged = () => waitFor(async () => {
      const after = (await snapshot(page)).data;
      switch (kind) {
        case 'Reset': return after.notice === 3 && after.facts.items.every(items => items.every(spell => spell === 0));
        case 'Load': return after.notice === 2;
        case 'Save': return after.notice === 1;
        case 'Pick': return after.facts.items[0].includes(combatant);
        case 'Start_Battle': case 'Restart_Battle': return after.facts.battle.seed === before.facts.battle.seed + 1;
        case 'Pick_Items': return after.facts.battle.phase === 0;
        case 'Select': return after.ui.selected === combatant;
        case 'Cycle_Speed': return after.facts.session.speed_index === (before.facts.session.speed_index + 1) % 4;
        default: throw new Error(`Missing application acknowledgment for ${kind}`);
      }
    }, `${kind} was not acknowledged by the application`);
  }
  for (let attempt = 0; attempt < 12; attempt++) {
    const button = (await controls(page)).find(item => item.kind === kind && (kind === 'Pick' ? item.spell : item.combatant) === combatant);
    assert.ok(button, `Missing ${kind} control`);
    const {rect:r, clip:c} = button;
    const left = Math.max(r.x, c.x), right = Math.min(r.x+r.width, c.x+c.width);
    const top = Math.max(r.y, c.y), bottom = Math.min(r.y+r.height, c.y+c.height);
    if (right-left > 4 && bottom-top > 4) {
      await page.mouse.move((left+right)/2, (top+bottom)/2);
      const sampledBefore = await page.evaluate(() => window.devilRecording.presses);
      await page.mouse.down();
      try {
        // Keep the press available until the game samples it or acknowledges the action.
        await waitFor(() => page.evaluate(previous => window.devilRecording.presses > previous, sampledBefore),
          `${kind} press was not sampled by the application`);
        await acknowledged();
      } finally {
        await page.mouse.up();
      }
      await frames(page);
      return;
    }
    await page.mouse.move(c.x+c.width/2, c.y+c.height/2);
    await page.mouse.wheel(0, r.y < c.y ? -500 : 500);
    await frames(page);
  }
  throw new Error(`Could not scroll ${kind} into view`);
}

try {
  const deadline = Date.now() + 60000;
  while (!output.match(/localhost:(\d+)/)) {
    if (server.exitCode !== null || Date.now() > deadline) throw new Error(output || 'Development server did not start');
    await delay(50);
  }
  origin = `http://127.0.0.1:${output.match(/localhost:(\d+)/)[1]}`;
  await waitFor(async () => Boolean((await status()).version), 'Initial debug build failed');
  for (const [name, engine] of [['chromium', chromium], ['webkit', webkit]]) {
    if (selectedEngine && selectedEngine !== `--engine=${name}`) continue;
    const browser = await engine.launch({headless:true});
    try {
      const context = await browser.newContext({viewport:{width:960, height:800}, deviceScaleFactor:2});
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(String(error)));
      page.on('console', message => {if (message.type() === 'error') console.error(`${name}: ${message.text()}`);});
      await page.route('**/*', async route => {
        if (route.request().resourceType() !== 'document' || new URL(route.request().url()).pathname === '/') return route.continue();
        const response = await route.fetch();
        const body = (await response.text()).replace('if (window.devilRecording.playing)',
          'if (window.suspendGameFrames || window.devilRecording.playing)');
        await route.fulfill({response, body});
      });
      await page.goto(`${origin}/${(await status()).version}/`);
      await ready(page);
      // A browser animation frame is not an acknowledgment that the game sampled a press.
      const pressFixture = await snapshot(page);
      pressFixture.data.facts.combatants[1].health = 1;
      assert.ok(await restore(page, pressFixture));
      const select = (await controls(page)).find(control => control.kind === 'Reset').rect;
      await page.evaluate(() => {window.suspendGameFrames = true;});
      await page.mouse.move(select.x + select.width / 2, select.y + select.height / 2);
      await page.mouse.down();
      await frames(page);
      await page.mouse.up();
      await frames(page);
      assert.equal((await snapshot(page)).data.facts.combatants[1].health, 1, 'Browser animation frames do not acknowledge application input');
      await page.evaluate(() => {window.suspendGameFrames = false;});
      await frames(page);
      assert.ok(await restore(page, pressFixture));
      await page.evaluate(() => {window.suspendGameFrames = true;});
      const acknowledged = click(page, 'Reset');
      await frames(page);
      assert.equal((await snapshot(page)).data.ui.selected, 0);
      await page.evaluate(() => {window.suspendGameFrames = false;});
      await acknowledged;
      assert.equal((await snapshot(page)).data.facts.combatants[1].health, 0, 'Acknowledgment keeps the press available until sampled');
      await page.screenshot({path:resolve(fixture, `${name}-desktop.png`)});
      assert.equal((await snapshot(page)).data.ui.selected, 0);
      assert.ok(!(await controls(page)).some(item => item.kind === 'Start_Battle'),
        'Empty inventories must explain the requirement instead of offering entry');
      await click(page, 'Select', 1, () => waitFor(
        async () => (await snapshot(page)).data.ui.selected === 1,
        'Selection did not reach combatant 1'));
      assert.equal((await snapshot(page)).data.ui.selected, 1);
      await click(page, 'Cycle_Speed', 0, () => waitFor(
        async () => (await snapshot(page)).data.facts.session.speed_index === 1,
        'Simulation speed did not advance'));
      assert.equal((await snapshot(page)).data.facts.session.speed_index, 1);

      const seeded = await snapshot(page);
      seeded.data.facts.combatants[1].health = 42.75;
      seeded.data.facts.activity[0].dodges = 4294967295;
      assert.ok(await restore(page, seeded));
      await click(page, 'Save', 0, () => waitFor(
        () => page.evaluate(() => localStorage.getItem('devils-due.save') !== null),
        'Save did not write player facts'));
      const saved = await page.evaluate(() => localStorage.getItem('devils-due.save'));
      assert.deepEqual(JSON.parse(saved).facts, seeded.data.facts);
      await page.evaluate(() => {
        window.originalStorageWrite = Storage.prototype.setItem;
        Storage.prototype.setItem = function(key, value) {
          if (this === localStorage && key === 'devils-due.save') throw new Error('storage fixture');
          return window.originalStorageWrite.call(this, key, value);
        };
      });
      await click(page, 'Save', 0, () => waitFor(
        async () => (await snapshot(page)).data.notice === 5,
        'Save did not report the storage error'));
      assert.equal((await snapshot(page)).data.notice, 5, 'A failed write must show a storage error');
      await page.screenshot({path:resolve(fixture, `${name}-storage-error.png`)});
      assert.equal(await page.evaluate(() => localStorage.getItem('devils-due.save')), saved);
      await page.evaluate(() => {Storage.prototype.setItem = window.originalStorageWrite; delete window.originalStorageWrite;});
      await click(page, 'Reset');
      assert.equal((await snapshot(page)).data.facts.combatants[1].health, 0);
      await click(page, 'Load');
      assert.deepEqual((await snapshot(page)).data.facts, seeded.data.facts);
      assert.equal((await snapshot(page)).data.ui.selected, 0);
      const recorded = await page.evaluate(() => window.devilRecording.text());
      const events = recorded.trim().split('\n').map(line => JSON.parse(line));
      assert.ok(events.some(event => event.kind === 0 && event.frame.left_pressed));
      assert.ok(events.some(event => event.kind === 2 && event.storage.write_ok));
      assert.ok(events.some(event => event.kind === 2 && new TextDecoder().decode(new Uint8Array(event.storage.bytes || [])).includes('42.75')));
      assert.ok(events.some(event => event.kind === 2 && event.storage.write_ok === false && event.storage.read_ok === false));
      // Host storage is unavailable during replay; recorded success/failure results must suffice.
      await page.addInitScript(() => {
        if (location.search === '?replay') {
          Storage.prototype.getItem = Storage.prototype.setItem = () => {throw new Error('Replay accessed storage');};
        }
      });
      const unchanged = await snapshot(page);
      console.log(`${name}: verifying boundary recording`);
      const verified = await page.evaluate(async recording => {
        const original = Storage.prototype.setItem;
        Storage.prototype.setItem = function() {throw new Error('Replay must not write storage');};
        try {return await window.devilRecording.verify(recording);}
        finally {Storage.prototype.setItem = original;}
      }, recorded);
      assert.equal(verified.matched, true);
      assert.deepEqual(verified.final, unchanged);
      assert.deepEqual(await snapshot(page), unchanged, 'Playback preserves the live session');
      const wrongVersion = [...events];
      wrongVersion[0] = {...wrongVersion[0], build:'another-version'};
      await assert.rejects(page.evaluate(text => window.devilRecording.verify(text), wrongVersion.map(event => JSON.stringify(event)).join('\n')), /different application version/);
      const before = await snapshot(page);
      const edited = structuredClone(before);
      edited.data.facts.combatants[1].health = 17;
      assert.ok(await restore(page, edited));
      await page.keyboard.down('Control');
      await page.keyboard.down('l');
      try {
        await frames(page);
      } finally {
        await page.keyboard.up('l');
        await page.keyboard.up('Control');
      }
      await frames(page);
      assert.deepEqual(await snapshot(page), edited, 'Browser shortcuts must not execute game load');
      await page.locator('#canvas').focus();
      assert.ok(await restore(page, before));
      const claimed = structuredClone(before);
      claimed.data.facts.items[1][0] = 2;
      claimed.data.facts.items[0][15] = 3;
      assert.ok(await restore(page, claimed));
      const picks = (await controls(page)).filter(item => item.kind === 'Pick');
      assert.ok(!picks.some(item => item.spell === 2), 'An opponent-owned item must not offer an unusable Pick control');
      assert.ok(picks.some(item => item.spell === 1), 'Available items must remain pickable');
      assert.ok((await controls(page)).some(item => item.kind === 'Start_Battle'), 'An owned item in any saved slot makes the build eligible');
      assert.deepEqual(await snapshot(page), claimed, 'Displaying ownership must not change the imported state');
      assert.ok(await restore(page, before));
      const invalid = structuredClone(before);
      invalid.data.facts.session.speed_index = 255;
      assert.equal(await restore(page, invalid), 0);
      assert.deepEqual(await snapshot(page), before);
      invalid.version = 99;
      assert.equal(await restore(page, invalid), 0);
      assert.deepEqual(await snapshot(page), before);
      for (const malformed of [
        '['.repeat(8000) + ']'.repeat(8000),
        JSON.stringify(before).replace('"version":3', '"version":18446744073709551617'),
      ]) {
        assert.equal(await page.evaluate(data => {
          const bytes = new TextEncoder().encode(data);
          new Uint8Array(wasmExports.memory.buffer, wasmExports.web_reload_buffer(), bytes.length).set(bytes);
          return wasmExports.web_restore(bytes.length);
        }, malformed), 0);
        assert.deepEqual(await snapshot(page), before, 'Malformed JSON cannot terminate or change the Wasm instance');
      }

      await page.setViewportSize({width:375, height:480});
      await frames(page);
      await page.mouse.move(180, 300);
      await page.mouse.wheel(0, 400);
      await frames(page);
      assert.ok((await snapshot(page)).data.ui.scroll > 0, 'Narrow view must scroll');
      const excess = await snapshot(page);
      excess.data.ui.scroll = 1e6;
      assert.ok(await restore(page, excess));
      await frames(page);
      const priorY = (await controls(page)).find(item => item.kind === 'Cycle_Speed').rect.y;
      await page.mouse.wheel(0, -24);
      await frames(page);
      assert.ok((await controls(page)).find(item => item.kind === 'Cycle_Speed').rect.y > priorY,
        'The first upward scroll must move the visible content even after the viewport shrinks');
      await click(page, 'Select', 1, () => waitFor(
        async () => (await snapshot(page)).data.ui.selected === 1,
        'Selection did not reach combatant 1'));
      assert.equal((await snapshot(page)).data.ui.selected, 1);
      for (const {clip} of await controls(page)) {
        assert.ok(clip.x >= 0 && clip.y >= 0 && clip.x+clip.width <= 376 && clip.y+clip.height <= 481);
      }
      await page.setViewportSize({width:960, height:800});
      await frames(page);
      let preserved = await snapshot(page);
      const previous = page.url();
      const theme = resolve(fixture, 'src/main.odin');
      await writeFile(theme, (await readFile(theme, 'utf8')) + `\n// ${name} reload fixture\n`);
      await page.waitForURL(url => url.href !== previous, {timeout:60000});
      await ready(page);
      assert.deepEqual(await snapshot(page), preserved, 'Successful source reload preserves facts, UI and notice');
      assert.equal(await page.evaluate(() => localStorage.getItem('devils-due.save')), saved);
      preserved.data.facts.combatants[1].health += 1;
      assert.ok(await restore(page, preserved));
      await page.reload();
      await ready(page);
      assert.deepEqual(await snapshot(page), preserved, 'Refresh must retain edits made after the last source reload');
      console.log(`${name}: Wasm startup, pointer input, HiDPI, scrolling, saves, rollback and source reload passed`);

      if (name === 'chromium') {
        const stopped = page.url();
        preserved.data.facts.combatants[1].health += 1;
        assert.ok(await restore(page, preserved));
        await page.evaluate(() => {
          wasmExports = {...wasmExports, web_frame() {throw new Error('running-frame fixture');}};
        });
        await page.waitForFunction(() => !document.getElementById('status').hidden);
        assert.deepEqual(JSON.parse(await page.evaluate(() => sessionStorage.getItem('devils-due.dev.snapshot'))), preserved,
          'A stopped frame loop captures progress made since startup');
        await writeFile(theme, (await readFile(theme, 'utf8')) + '\n// Recover the stopped frame loop\n');
        await page.waitForURL(url => url.href !== stopped, {timeout:60000});
        await ready(page);
        assert.deepEqual(await snapshot(page), preserved, 'A source fix can resume the stopped game from its latest facts');
        console.log('chromium: running-frame failure preserves progress and reloads a source fix');
        for (const [relative, from, to] of [
          ['src/state/state.odin', 'RELOAD_VERSION :: u32(3)', 'RELOAD_VERSION :: u32(99)'],
          ['web/index.html', 'wasmExports.web_frame(', '(() => {throw new Error("first-frame fixture");})('],
        ]) {
          const previous = page.url();
          const source = resolve(fixture, relative);
          const original = await readFile(source, 'utf8');
          assert.ok(original.includes(from));
          await writeFile(source, original.replace(from, to));
          await waitFor(async () => {
            const current = await status();
            return current.version && !previous.includes(current.version) && !current.building;
          }, `Recovery fixture did not publish: ${relative}`);
          const rejected = (await status()).version;
          await page.waitForFunction(version => sessionStorage.getItem('devils-due.dev.blocked') === version, rejected, {timeout:60000});
          await ready(page);
          assert.equal(page.url(), previous, 'Startup failure returns to the prior build');
          assert.deepEqual(await snapshot(page), preserved);
          assert.deepEqual(JSON.parse(await page.evaluate(() => sessionStorage.getItem('devils-due.dev.snapshot'))), preserved);
          await writeFile(source, original);
          await page.waitForURL(url => url.href !== previous, {timeout:60000});
          await ready(page);
          assert.deepEqual(await snapshot(page), preserved);
        }
        console.log('chromium: incompatible snapshot, first-frame failure recovery and retained original passed');
      }
      await click(page, 'Reset');
      assert.ok(!(await controls(page)).some(item => item.kind === 'Start_Battle'));
      for (let spell = 1; spell <= 5; spell++) {
        await click(page, 'Pick', spell);
        assert.ok((await controls(page)).some(item => item.kind === 'Start_Battle'),
          'A picked item enables arena entry');
      }
      await click(page, 'Start_Battle');
      // Pick phase can be scrolled; return to the arena before sending aimed input.
      await page.mouse.wheel(0, -4000);
      await frames(page);
      let battle = await snapshot(page);
      assert.equal(battle.data.facts.battle.phase, 1);
      const fractional = structuredClone(battle);
      fractional.data.facts.combatants[0].health = 0.25;
      assert.ok(await restore(page, fractional));
      await frames(page);
      assert.equal((await snapshot(page)).data.facts.combatants[0].health, 0.25);
      await page.screenshot({path:resolve(fixture, `${name}-fractional-health.png`)});
      assert.ok(await restore(page, battle));
      const arena = (await controls(page)).find(item => item.kind === 'Arena').rect;
      const scale = Math.min(arena.width, arena.height) / 1120;
      const center = {x:arena.x + arena.width / 2, y:arena.y + arena.height / 2};
      await page.mouse.move(center.x + 170 * scale, center.y);
      await page.keyboard.down('d');
      await waitFor(async () => (await snapshot(page)).data.facts.bodies[0].x > -170, 'WASD did not move player 1');
      await page.keyboard.up('d');
      battle = await snapshot(page);
      assert.ok(battle.data.facts.bodies[0].x > -170, 'WASD moves player 1');
      assert.equal(battle.data.facts.bodies[1].x, 170, 'Dummy does not move by itself');
      await page.mouse.move(center.x + (battle.data.facts.bodies[1].x - battle.data.facts.bodies[0].x) * scale, center.y);
      battle.data.facts.cooldowns[0][0] = 0; // Input fixture; initial cooldowns are checked by the simulation tests.
      battle.data.facts.combatants[1].reflex = 0; // Deterministic critical-only hit for this input fixture.
      assert.ok(await restore(page, battle));
      await page.keyboard.down('q');
      await waitFor(async () => (await snapshot(page)).data.facts.cooldowns[0][0] > 0, 'Held Fireball did not cast');
      await page.keyboard.up('q');
      // Catch-up is capped, so a slow browser can simulate less than wall-clock time.
      await waitFor(async () => {
        const facts = (await snapshot(page)).data.facts;
        return facts.combatants[1].health < 100 && facts.bodies[1].x > 170;
      }, 'Aimed Fireball did not damage and push the dummy');
      battle = await snapshot(page);
      battle.data.facts.cooldowns[0][1] = 0;
      battle.data.facts.cooldowns[0][3] = 0;
      assert.ok(await restore(page, battle));
      await page.mouse.move(center.x + (battle.data.facts.bodies[1].x - battle.data.facts.bodies[0].x) * scale, center.y);
      const beforeTeleport = battle.data.facts.bodies[0].x;
      await page.keyboard.down('e');
      await page.keyboard.down('f');
      await waitFor(async () => {
        const cooldowns = (await snapshot(page)).data.facts.cooldowns[0];
        return cooldowns[1] > 0 && cooldowns[3] > 0;
      }, 'Independent held keys did not cast');
      await page.keyboard.up('e');
      await page.keyboard.up('f');
      await frames(page);
      const held = (await snapshot(page)).data.facts;
      assert.ok(held.cooldowns[0][1] > 0 && held.cooldowns[0][3] > 0, `Independent held keys: ${JSON.stringify(held.cooldowns[0])}`);
      assert.ok(held.bodies[0].x > beforeTeleport + 100, 'Teleport changes position');
      const combatReplay = await page.evaluate(async () => window.devilRecording.verify(window.devilRecording.text()));
      assert.equal(combatReplay.matched, true, 'Movement, casts, timing and restore events reproduce active combat');
      assert.equal(combatReplay.final.data.facts.battle.phase, 1);
      await page.screenshot({path:resolve(fixture, `${name}-battle.png`)});
      await click(page, 'Restart_Battle');
      battle = await snapshot(page);
      assert.equal(battle.data.facts.combatants[1].health, 100);
      assert.equal(battle.data.facts.bodies[0].x, -170);
      assert.equal(battle.data.facts.items[0].filter(Boolean).length, 5);
      // Upgrade a complete v1 development snapshot and retain the original source.
      await click(page, 'Pick_Items');
      const legacy2 = structuredClone(battle);
      legacy2.version = 2;
      delete legacy2.data.facts.battle.seed;
      for (const body of legacy2.data.facts.bodies) delete body.lava_ticks;
      for (const c of legacy2.data.facts.combatants) {
        delete c.reflex;
        delete c.mastery;
        c.agility = 0;
        c.speed = 0; // Preserve the common legacy zero-Speed state without inventing 0/0 behavior.
      }
      await page.evaluate(data => {
        sessionStorage.setItem('devils-due.dev.snapshot', JSON.stringify(data));
        window.addEventListener('pagehide', () => sessionStorage.setItem('devils-due.dev.snapshot', JSON.stringify(data)), {once:true});
      }, legacy2);
      await page.reload();
      await ready(page);
      const upgraded2 = await snapshot(page);
      assert.equal(upgraded2.version, 3);
      assert.equal(upgraded2.data.facts.battle.ticks, legacy2.data.facts.battle.ticks);
      assert.deepEqual(upgraded2.data.facts.cooldowns, legacy2.data.facts.cooldowns);
      assert.equal(upgraded2.data.notice, 6, 'An undefined zero-Speed ratio pauses without resetting progress');
      assert.deepEqual(JSON.parse(await page.evaluate(() => sessionStorage.getItem('devils-due.dev.snapshot.v2'))), legacy2);
      const legacy = structuredClone(preserved);
      for (const c of legacy.data.facts.combatants) {delete c.reflex; delete c.mastery; c.agility = 6;}
      legacy.version = 1;
      for (const key of ['items', 'cooldowns', 'bodies', 'battle', 'spells']) delete legacy.data.facts[key];
      await page.evaluate(data => {
        sessionStorage.setItem('devils-due.dev.snapshot', JSON.stringify(data));
        window.addEventListener('pagehide', () => sessionStorage.setItem('devils-due.dev.snapshot', JSON.stringify(data)), {once:true});
      }, legacy);
      await page.reload();
      await ready(page);
      const migrated = await snapshot(page);
      assert.equal(migrated.version, 3);
      assert.deepEqual(migrated.data.facts.combatants, legacy.data.facts.combatants.map(({agility, ...c}) => ({...c, reflex:100, mastery:100})));
      assert.deepEqual(migrated.data.ui, legacy.data.ui);
      assert.deepEqual(JSON.parse(await page.evaluate(() => sessionStorage.getItem('devils-due.dev.snapshot.v1'))), legacy);
      console.log(`${name}: item picks, WASD, aimed casting, cooldowns, dummy knockback, held casts, restart and v1/v2 migration passed`);
      await page.screenshot({path:resolve(fixture, `${name}.png`)});
      assert.deepEqual(errors, [], 'No uncaught browser errors');
      const interrupted = await context.newPage();
      try {
        await interrupted.goto(origin);
        await ready(interrupted);
        await interrupted.evaluate(() => {
          const capture = window.devilRecording.capture;
          window.devilRecording.capture = line => {
            capture(line);
            if (JSON.parse(line).kind === 0) throw new Error('failure after input capture fixture');
          };
        });
        await interrupted.waitForFunction(() => !document.getElementById('status').hidden);
        const retained = await interrupted.evaluate(() => window.devilRecording.text());
        assert.equal(JSON.parse(retained.trim().split('\n').at(-2)).kind, 0,
          'The input that triggers a processing failure remains recorded');
      } finally {await interrupted.close();}
    } finally {
      await browser.close();
    }
  }
  const release = createServer(async (request, response) => {
    const name = request.url === '/' ? 'index.html' : request.url.slice(1);
    const types = {'index.html':'text/html', 'game.js':'text/javascript', 'odin.js':'text/javascript', 'recording.js':'text/javascript', 'game.wasm':'application/wasm'};
    if (!Object.hasOwn(types, name)) {response.writeHead(404).end(); return;}
    try {
      const bytes = await readFile(resolve(root, '.work/build/release-check', name));
      response.writeHead(200, {'Content-Type':types[name]}).end(bytes);
    } catch {response.writeHead(500).end();}
  });
  await new Promise(done => release.listen(0, '127.0.0.1', done));
  const browser = await chromium.launch({headless:true});
  try {
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${release.address().port}`);
    await ready(page);
    assert.equal(await page.evaluate(() => typeof wasmExports.web_snapshot), 'undefined');
    assert.equal(await page.evaluate(() => typeof window.devilDev), 'undefined');
    console.log('Release: optimized Wasm starts without development exports or recovery client');
    await page.close();
    for (const resource of ['odin.js', 'game.js', 'game.wasm']) {
      const broken = await browser.newPage();
      try {
        const errors = [];
        broken.on('pageerror', error => errors.push(String(error)));
        await broken.route(`**/${resource}`, route => route.abort());
        await broken.goto(`http://127.0.0.1:${release.address().port}`);
        await broken.waitForFunction(() => !document.getElementById('status').hidden &&
          document.getElementById('status').textContent.includes('Unable to run'));
        assert.deepEqual(errors, [], `Failed ${resource} must not cascade into uncaught errors`);
      } finally {
        await broken.close();
      }
    }
    for (const resource of ['odin.js', 'game.js']) {
      const broken = await browser.newPage();
      try {
        const errors = [];
        broken.on('pageerror', error => errors.push(String(error)));
        await broken.route(`**/${resource}`, route => route.fulfill({
          contentType:'text/javascript', body:'throw new Error("execution failure fixture")',
        }));
        await broken.goto(`http://127.0.0.1:${release.address().port}`);
        await broken.waitForFunction(() => !document.getElementById('status').hidden &&
          document.getElementById('status').textContent.includes('Unable to run'));
        assert.deepEqual(errors, ['Error: execution failure fixture'],
          `Failed ${resource} execution must preserve its error without cascading`);
        await broken.unroute(`**/${resource}`);
        await broken.reload();
        await ready(broken);
      } finally {
        await broken.close();
      }
    }
    console.log('Release: failed script/Wasm downloads and script execution show recoverable errors');
  } finally {
    await browser.close();
    await new Promise(done => release.close(done));
  }
  console.log(`Browser fixtures and screenshots: ${fixture}`);
} catch (error) {
  console.error(output);
  throw error;
} finally {
  if (server.exitCode === null) {
    process.kill(-server.pid, 'SIGINT');
    await once(server, 'exit');
  }
}
