export const defaults = ['connection','traffic','node','ip'];
export const catalog = {connection:'连接状态',traffic:'实时流量',node:'当前节点',ip:'出口 IP',subscription:'订阅用量',speed:'快捷测速'};
export function normalizeLayout(value) {
  if (!Array.isArray(value)) return [...defaults];
  return [...new Set(value.filter(id => Object.hasOwn(catalog,id)))];
}
export function loadLayout(storage) {
  try { const raw = storage.getItem('hotaru.layout.v1'); return raw === null ? [...defaults] : normalizeLayout(JSON.parse(raw)); } catch { return [...defaults]; }
}
export function reorder(list,from,to) {
  if (!list.includes(from)||!list.includes(to)||from===to) return [...list];
  const next=list.filter(id=>id!==from); next.splice(list.indexOf(to),0,from); return next;
}
export function validateChain(nodes) {
  if (!Array.isArray(nodes)||nodes.length<2) return '代理链至少需要两个节点';
  if(nodes.some(n=>typeof n!=='string'||!n.trim())) return '节点不能为空';
  if(new Set(nodes).size!==nodes.length) return '不能重复引用同一节点';
  return null;
}
