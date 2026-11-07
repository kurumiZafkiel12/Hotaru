import 'dart:convert';

String toolTranslationScript(Map<String, String> labels, String locale) =>
    '''
(() => {
  if (location.hostname !== 'browserleaks.com') return;
  const labels = ${jsonEncode(labels)};
  document.documentElement.lang = ${jsonEncode(locale)};
  const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'CODE', 'PRE', 'BUTTON', 'OPTION']);
  const translate = node => {
    if (!node.parentElement || node.parentElement.closest('script,style,noscript,textarea,code,pre,button,option')) return;
    const original = node.nodeValue;
    const trimmed = original.trim();
    const key = trimmed.replace(/:\\s*\$/, '');
    const translated = labels[key];
    if (translated && translated !== key) {
      node.nodeValue = original.replace(trimmed, translated + (trimmed.endsWith(':') ? ':' : ''));
    }
  };
  const visit = root => {
    if (root.nodeType === Node.TEXT_NODE) { translate(root); return; }
    if (root.nodeType !== Node.ELEMENT_NODE || skip.has(root.tagName)) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) translate(walker.currentNode);
  };
  visit(document.body);
  const observer = new MutationObserver(changes => {
    for (const change of changes) {
      if (change.type === 'characterData') translate(change.target);
      else for (const node of change.addedNodes) visit(node);
    }
  });
  observer.observe(document.body, {subtree:true, childList:true, characterData:true});
})();
''';
