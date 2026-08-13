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

console.log('LuCI host-navigation layering contract passed');
