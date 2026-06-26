(function () {
  'use strict';

  var DEST = '/cgi-bin/luci/admin/system/glinet-crossmodel';
  var MENU_ID = 'gcm-glui-menu-item';
  var HEADER_ID = 'gcm-glui-header-shortcut';

  function text(value) {
    return String(value || '').replace(/\s+/g, ' ').trim();
  }

  function visible(el) {
    if (!el) return false;
    var rect = el.getBoundingClientRect();
    var style = window.getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 &&
      style.display !== 'none' && style.visibility !== 'hidden';
  }

  function exactLeaf(label) {
    var all = document.querySelectorAll('body *');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.children.length === 0 && text(el.textContent) === label && visible(el)) {
        return el;
      }
    }
    return null;
  }

  function menuItem(label, headerOnly) {
    var leaf = exactLeaf(label);
    if (!leaf) return null;

    var el = leaf;
    while (el && el !== document.body) {
      var rect = el.getBoundingClientRect();
      var value = text(el.innerText);
      if (
        value === label &&
        rect.width >= 45 && rect.width <= 280 &&
        rect.height >= 20 && rect.height <= 72 &&
        (!headerOnly || (rect.top >= 0 && rect.top <= 58))
      ) {
        return el;
      }
      el = el.parentElement;
    }

    return leaf.parentElement;
  }

  function openTool(event) {
    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }
    window.location.assign(DEST);
  }

  function updateText(root, from, to) {
    var all = root.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      if (all[i].children.length === 0 && text(all[i].textContent) === from) {
        all[i].textContent = to;
        return;
      }
    }
    root.textContent = to;
  }

  function clearDuplicate(id) {
    var existing = document.getElementById(id);
    if (existing && !document.body.contains(existing)) existing.remove();
  }

  function addSystemEntry() {
    clearDuplicate(MENU_ID);
    if (document.getElementById(MENU_ID)) return true;

    var source =
      menuItem('Advanced Settings', false) ||
      menuItem('Log', false) ||
      menuItem('Overview', false);

    if (!source || !source.parentNode) return false;

    var entry = source.cloneNode(true);
    entry.id = MENU_ID;
    entry.style.cursor = 'pointer';
    entry.title = 'GL.iNet Cross-Model Backup';

    var ids = entry.querySelectorAll('[id]');
    for (var i = 0; i < ids.length; i++) ids[i].removeAttribute('id');

    updateText(entry, text(source.innerText), '↔ Cross-Model Backup');
    if (entry.tagName === 'A') entry.setAttribute('href', DEST);

    entry.addEventListener('click', openTool, true);
    source.parentNode.insertBefore(entry, source.nextSibling);
    return true;
  }

  function addHeaderShortcut() {
    clearDuplicate(HEADER_ID);
    if (document.getElementById(HEADER_ID)) return true;

    var source = menuItem('EN', true);
    if (source && source.parentNode) {
      var icon = source.cloneNode(true);
      icon.id = HEADER_ID;
      icon.style.cursor = 'pointer';
      icon.title = 'GL.iNet Cross-Model Backup';
      icon.setAttribute('aria-label', 'GL.iNet Cross-Model Backup');

      var ids = icon.querySelectorAll('[id]');
      for (var i = 0; i < ids.length; i++) ids[i].removeAttribute('id');

      updateText(icon, 'EN', '↔');
      if (icon.tagName === 'A') icon.setAttribute('href', DEST);

      icon.addEventListener('click', openTool, true);
      source.parentNode.insertBefore(icon, source);
      return true;
    }

    var fallback = document.createElement('a');
    fallback.id = HEADER_ID;
    fallback.href = DEST;
    fallback.title = 'GL.iNet Cross-Model Backup';
    fallback.setAttribute('aria-label', 'GL.iNet Cross-Model Backup');
    fallback.textContent = '↔';
    fallback.style.cssText =
      'position:fixed;top:8px;right:285px;z-index:2147483647;' +
      'height:30px;line-height:30px;padding:0 8px;' +
      'font-size:21px;font-weight:bold;text-decoration:none;' +
      'color:#777;background:transparent;cursor:pointer;';
    fallback.addEventListener('click', openTool, true);
    document.body.appendChild(fallback);
    return true;
  }

  function inject() {
    addSystemEntry();
    addHeaderShortcut();
  }

  var observer = new MutationObserver(inject);
  observer.observe(document.documentElement, { childList: true, subtree: true });

  inject();
  window.setInterval(inject, 1500);
}());
