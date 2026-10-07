import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const pages = [
  new URL('../Resources/WebAssets/index.html', import.meta.url),
  ...process.argv.slice(2).map(path => pathToFileURL(resolve(path))),
];

for (const page of pages) {
  const html = await readFile(page, 'utf8');
  const source = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];
  const scriptPolicy = html.match(/script-src ([^;]+)/)[1];
  const hash = createHash('sha256').update(source, 'utf8').digest('base64');
  assert.ok(scriptPolicy.includes(`'sha256-${hash}'`), 'CSP must match the exact bootstrap script');
  assert.ok(!scriptPolicy.includes('unsafe-inline'), 'inline event handlers must remain blocked');
  const releases = {};
  let active = 0, maximumActive = 0;
  const svg = {viewBox: {baseVal: {width: 100, height: 100}}, style: {}, setAttribute() {}, getBoundingClientRect: () => ({width: 100, height: 100})};
  const element = {innerHTML: '', style: {}, replaceChildren(node) { this.innerHTML = node.markup; }, querySelector: () => svg};
  const createElement = () => ({style: {}, set innerHTML(value) { svg.markup = value; }, querySelector: () => svg, remove() {}});
  const engine = {
    mermaidAPI: {defaultConfig: {secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'suppressErrorRendering', 'maxEdges']}},
    initialize(config) {
      assert.equal(config.securityLevel, 'strict');
      assert.equal(config.htmlLabels, false);
      assert.equal(config.flowchart.htmlLabels, false);
      assert.ok(config.secure.includes('htmlLabels'));
      assert.ok(config.secure.includes('dompurifyConfig'));
    },
    render(id, text) {
      active++;
      maximumActive = Math.max(maximumActive, active);
      return new Promise(resolve => releases[text] = () => {
        active--;
        resolve({svg: `<svg>${text}</svg>`});
      });
    },
  };
  let holdFrames = false;
  const frames = [];
  const context = {window: {}, mermaid: engine, document: {fonts: {ready: Promise.resolve()}, getElementById: () => element, createElement, body: {appendChild() {}}}, requestAnimationFrame: callback => holdFrames ? frames.push(callback) : queueMicrotask(callback), setTimeout, clearTimeout};
  vm.runInNewContext(source, context);
  const tick = () => new Promise(resolve => setImmediate(resolve));
  const waitFor = async key => {
    for (let tries = 0; !releases[key] && tries < 1_000; tries++) await tick();
    assert.ok(releases[key], `engine did not start ${key}`);
  };
  const old = context.window.renderDiagram('older', false, 320, 17).catch(() => null);
  await waitFor('older');
  const latest = context.window.renderDiagram('newer', true, 320, 17);
  await tick();
  if (releases.newer) {
    releases.newer();
    await latest;
    releases.older();
  } else {
    releases.older();
    await waitFor('newer');
    releases.newer();
  }
  await Promise.race([
    Promise.all([old, latest]),
    new Promise((_, reject) => setTimeout(() => reject(new Error('render did not settle')), 2_000)),
  ]);
  assert.equal(element.innerHTML, '<svg>newer</svg>');
  assert.equal(maximumActive, 1);
  const cancelled = context.window.renderDiagram('cancelled', false, 320, 17, 7).catch(() => null);
  await waitFor('cancelled');
  context.window.cancelDiagram(7);
  releases.cancelled();
  await cancelled;
  assert.equal(element.innerHTML, '<svg>newer</svg>');
  const recovered = context.window.renderDiagram('recovered', false, 320, 17, 8);
  await waitFor('recovered');
  releases.recovered();
  await recovered;
  assert.equal(element.innerHTML, '<svg>recovered</svg>');
  holdFrames = true;
  const betweenFrames = context.window.renderDiagram('betweenFrames', false, 320, 17, 9).catch(() => null);
  await waitFor('betweenFrames');
  releases.betweenFrames();
  for (let tries = 0; !frames.length && tries < 1_000; tries++) await tick();
  assert.ok(frames.length, 'render did not reach the frame gate');
  context.window.cancelDiagram(9);
  while (frames.length) frames.shift()();
  await betweenFrames;
  assert.equal(element.innerHTML, '<svg>recovered</svg>');
}
console.log(`Mermaid latest DOM, serialized engine, cancellation and recovery regression passed on ${pages.length} page(s).`);
