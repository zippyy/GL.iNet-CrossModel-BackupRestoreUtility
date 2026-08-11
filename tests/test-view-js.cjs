'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const view = fs.readFileSync(path.join(root, 'openwrt/luci-app-glinet-crossmodel-backup/root/usr/lib/lua/luci/view/glinet_crossmodel/index.htm'), 'utf8');
const script = view.match(/<script[^>]*>([\s\S]*?)<\/script>/);

if (!script) throw new Error('LuCI view script block is missing.');
// LuCI template expressions are replaced with inert values before JavaScript
// parsing; the actual values are generated server-side at request time.
new Function(script[1].replace(/<%[\s\S]*?%>/g, 'null'));
console.log('LuCI browser JavaScript syntax passed');
