import {test} from 'node:test';
import assert from 'node:assert/strict';
import {defaults,normalizeLayout,loadLayout,reorder,validateChain} from '../src/model.js';
test('损坏或不可用存储恢复默认布局',()=>{for(const storage of [{getItem:()=>'{broken'},{getItem:()=>{throw Error('denied');}},{getItem:()=>null}])assert.deepEqual(loadLayout(storage),defaults);});
test('保留空布局，过滤未知组件和重复项',()=>{assert.deepEqual(normalizeLayout([]),[]);assert.deepEqual(normalizeLayout(['ip','bad','ip','node']),['ip','node']);assert.deepEqual(normalizeLayout({}),defaults);});
test('双向排序不修改原数组且无效拖动无副作用',()=>{const a=['ip','node','traffic'];assert.deepEqual(reorder(a,'ip','traffic'),['node','traffic','ip']);assert.deepEqual(reorder(a,'traffic','ip'),['traffic','ip','node']);assert.deepEqual(reorder(a,'missing','ip'),a);assert.deepEqual(a,['ip','node','traffic']);});
test('代理链拒绝重复、空节点和不足两跳',()=>{assert.ok(validateChain(['a']));assert.ok(validateChain(['a','a']));assert.ok(validateChain(['a','']));assert.equal(validateChain(['a','b','c']),null);});
