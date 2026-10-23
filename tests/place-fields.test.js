import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PLACE_FIELDS,readPlaceValue} from '../js/place-fields.js';
test('place editor covers the checked-in database schema except identity, country, photos and protected ownership',()=>{
 const schema=fs.readFileSync(new URL('../supabase/migrations/20260629160148_baseline.sql',import.meta.url),'utf8').split('CREATE TABLE IF NOT EXISTS "public"."places" (')[1].split('\n);')[0];
 const keys=[...schema.matchAll(/^\s+"(\w+)" /gm)].map(m=>m[1]);
 const managed=['id','name','country','image','partner_access_token','partner_id'];
 assert.deepEqual(PLACE_FIELDS.map(f=>f.key).sort(),keys.filter(k=>!managed.includes(k)).sort());
 const server=JSON.parse(fs.readFileSync(new URL('../supabase/functions/_shared/place-fields.json',import.meta.url),'utf8'));assert.deepEqual(server,PLACE_FIELDS.map(f=>f.key));
});
test('typed place values preserve false, numeric zero, JSON and room arrays, and reject malformed values',()=>{
 assert.equal(readPlaceValue({type:'boolean'},{checked:false}),false);
 assert.equal(readPlaceValue({type:'number'},{value:'0'}),0);
 assert.equal(readPlaceValue({type:'text'},{value:''}),null);
 assert.deepEqual(readPlaceValue({type:'array'},{value:'Suite\n\nDouble'}),['Suite','Double']);
 assert.deepEqual(readPlaceValue({type:'json'},{value:'{"monday":[]}' }),{monday:[]});
 assert.throws(()=>readPlaceValue({type:'json'},{value:'nope'}));
 assert.throws(()=>readPlaceValue({type:'number',key:'latitude'},{value:'NaN'}));
});

test('category-specific fields follow Eat, Stay and Play while editorial and contact fields stay available',async()=>{
 const {fieldVisible}=await import('../js/studio-presentation.js');
 for(const category of ['eat','stay','play']){
  const visible=PLACE_FIELDS.filter(f=>fieldVisible(f,category));
  assert.ok(visible.some(f=>f.key==='curator_note'));assert.ok(visible.some(f=>f.key==='address'));
  assert.equal(visible.some(f=>f.key==='cuisine'),category==='eat');
  assert.equal(visible.some(f=>f.key==='number_of_rooms'),category==='stay');
  assert.equal(visible.some(f=>f.key==='activities'),category==='play');
  assert.equal(visible.some(f=>f.key==='booking_mode'),category==='stay');
 }
});
test('image candidates handle legacy arrays and malformed values, and coverage uses real records',async()=>{
 const {imageCandidates,collectionSummary}=await import('../js/studio-presentation.js');
 assert.deepEqual(imageCandidates('["https://example.com/a.jpg","https://example.com/b.jpg"]'),['https://example.com/a.jpg','https://example.com/b.jpg']);
 assert.deepEqual(imageCandidates('javascript:alert(1)'),[]);
 assert.deepEqual(imageCandidates([null,'', 'https://example.com/a.jpg','https://example.com/a.jpg']),['https://example.com/a.jpg']);
 assert.deepEqual(collectionSummary([{category:'Eat',image:['https://example.com/a.jpg'],curator_note:'Hello'},{category:'stay',image:[],curator_note:''}]),{total:2,counts:{eat:1,stay:1,play:0},photos:1,notes:1,missingPhotos:1});
});
