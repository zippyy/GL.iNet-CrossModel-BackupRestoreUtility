'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const view = fs.readFileSync(path.join(root, 'openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/view/glinet_crossmodel/index.htm'), 'utf8');

if (/<header\s+class=["']gcm-top["']/.test(view)) {
  throw new Error('The app banner uses <header> and inherits LuCI global-navigation stacking styles.');
}

if (!/<section\s+class=["']gcm-top["']\s+aria-labelledby=["']gcm-title["']/.test(view)) {
  throw new Error('The app banner must use a locally scoped, labelled section.');
}

if (!/<h2\s+id=["']gcm-title["']>/.test(view)) {
  throw new Error('The app banner section must retain an accessible heading relationship.');
}

const layoutStart = view.indexOf('<main class="gcm-layout">');
const utilitiesStart = view.indexOf('<aside class="gcm-stack">', layoutStart);
const layoutEnd = view.indexOf('</main>', utilitiesStart);
const libraryStart = view.indexOf('<section class="gcm-section gcm-library">', layoutStart);

if (layoutStart < 0 || utilitiesStart < 0 || layoutEnd < 0 || libraryStart < 0 || libraryStart > utilitiesStart) {
  throw new Error('Numbered sections 1, 2, and 3 must remain together in the primary workflow column.');
}

if (!/#gcm-app td:nth-child\(6\)::before\{content:"Actions"\}/.test(view)) {
  throw new Error('The profile library must expose labelled stacked rows at the narrow breakpoint.');
}

const responsiveLayouts = Array.from(view.matchAll(/@media\(max-width:(\d+)px\)\{#gcm-app \.gcm-layout\{grid-template-columns:1fr\}/g));
if (!responsiveLayouts.some((match) => Number(match[1]) >= 1024)) {
  throw new Error('The responsive workflow must activate at a 1024px CSS viewport before the profile table is squeezed.');
}

if (!/#gcm-app \.gcm-library \.gcm-section-head>\.gcm-button\{flex:0 0 auto;white-space:nowrap\}/.test(view)) {
  throw new Error('The profile-library Refresh button must not shrink or wrap at intermediate widths.');
}

console.log('LuCI host-navigation layering contract passed');
