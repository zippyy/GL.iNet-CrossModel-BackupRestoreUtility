(function () {
  'use strict';

  var DESTINATION = '/cgi-bin/luci/admin/system/glinet-crossmodel';
  var MENU_ID = 'gcm-glui-menu-item';
  var SHORTCUT_ID = 'gcm-glui-header-shortcut';

  function normalizedText(value) {
    return String(value || '').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
  }

  function visible(element) {
    if (!element) return false;
    var rectangle = element.getBoundingClientRect();
    var style = window.getComputedStyle(element);
    return rectangle.width > 0 && rectangle.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
  }

  function leaf(label) {
    var elements = document.querySelectorAll('body *');
    for (var index = 0; index < elements.length; index += 1) {
      if (elements[index].children.length === 0 && normalizedText(elements[index].textContent) === label && visible(elements[index])) return elements[index];
    }
    return null;
  }

  function clickable(label, headerOnly) {
    var element = leaf(label);
    if (!element) return null;
    while (element && element !== document.body) {
      var rectangle = element.getBoundingClientRect();
      if (rectangle.width >= 40 && rectangle.width <= 320 && rectangle.height >= 20 && rectangle.height <= 76 && (!headerOnly || rectangle.top <= 62)) return element;
      element = element.parentElement;
    }
    return null;
  }

  function retarget(element, title) {
    var identifiers = element.querySelectorAll('[id]');
    for (var index = 0; index < identifiers.length; index += 1) identifiers[index].removeAttribute('id');
    element.style.cursor = 'pointer';
    element.title = title;
    element.setAttribute('aria-label', title);
    if (element.tagName === 'A') element.setAttribute('href', DESTINATION);
    element.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();
      window.location.assign(DESTINATION);
    }, true);
  }

  function replaceLeafText(root, text) {
    var elements = root.querySelectorAll('*');
    for (var index = 0; index < elements.length; index += 1) {
      if (elements[index].children.length === 0 && normalizedText(elements[index].textContent)) {
        elements[index].textContent = text;
        return;
      }
    }
    root.textContent = text;
  }

  function addMenuItem() {
    if (document.getElementById(MENU_ID)) return;
    var source = clickable('Advanced Settings', false) || clickable('Log', false) || clickable('Overview', false);
    if (!source || !source.parentNode) return;
    var entry = source.cloneNode(true);
    entry.id = MENU_ID;
    retarget(entry, 'Cross-Model Backup & Recovery');
    replaceLeafText(entry, '↔ Backup & Recovery');
    source.parentNode.insertBefore(entry, source.nextSibling);
  }

  function addShortcut() {
    if (document.getElementById(SHORTCUT_ID)) return;
    var source = clickable('EN', true);
    if (!source || !source.parentNode) return;
    var shortcut = source.cloneNode(true);
    shortcut.id = SHORTCUT_ID;
    retarget(shortcut, 'Cross-Model Backup & Recovery');
    replaceLeafText(shortcut, '↔');
    source.parentNode.insertBefore(shortcut, source);
  }

  function inject() {
    addMenuItem();
    addShortcut();
  }

  new MutationObserver(inject).observe(document.documentElement, { childList: true, subtree: true });
  inject();
  window.setInterval(inject, 2000);
}());
