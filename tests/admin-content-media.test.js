import test from 'node:test';
import assert from 'node:assert/strict';
import { contentMediaPath, MEDIA_BUCKET } from '../supabase/functions/_shared/content-media-path.mjs';
import { normalizeDraft, draftForStorage, instagramFromDraft } from '../js/admin-content-model.js';
const draftId='12345678-1234-4234-8234-123456789012';
const photoId='87654321-4321-4321-8321-210987654321';
test('photos are routed deterministically by country, content type, draft and photo ID',()=>{
  assert.equal(MEDIA_BUCKET,'content-media');
  assert.equal(contentMediaPath({country:'Jamaica',purpose:'guide',draftId,photoId}),`jamaica/guides/${draftId}/photos/${photoId}.jpg`);
  assert.equal(contentMediaPath({country:'The Bahamas',purpose:'instagram',draftId,photoId}),`external/instagram/${draftId}/photos/${photoId}.jpg`);
  assert.match(contentMediaPath({country:'Saint Lucia',purpose:'place_update',draftId,photoId}),/^saint-lucia\/places\//);
  assert.match(contentMediaPath({country:'Barbados',purpose:'photo_story',draftId,photoId}),/^barbados\/posts\//);
});
test('folder generation rejects unsupported types and injected identifiers',()=>{
  for(const purpose of ['../images','__proto__','constructor'])assert.throws(()=>contentMediaPath({country:'Jamaica',purpose,draftId,photoId}));
  assert.throws(()=>contentMediaPath({country:'',purpose:'guide',draftId,photoId}));
  assert.throws(()=>contentMediaPath({country:'Jamaica',purpose:'guide',draftId:'../other',photoId}));
  assert.throws(()=>contentMediaPath({country:'Jamaica',purpose:'guide',draftId,photoId:'photo.jpg'}));
});
test('private storage payloads contain object paths rather than signed URLs or image data',()=>{
  const draft=normalizeDraft({country:'Jamaica',photos:[{id:'one',path:'jamaica/posts/draft/photos/photo.jpg',bucket:MEDIA_BUCKET,src:'https://private/signed-token',caption:'A moment'}]});
  const payload=draftForStorage(draft);
  assert.equal(payload.photos[0].src,undefined);assert.equal(payload.photos[0].path,draft.photos[0].path);
  assert.equal(draft.photos[0].src,'https://private/signed-token');
});
test('Instagram companions use the existing story and recommendations without inserting sensory prompts',()=>{
  const draft=normalizeDraft({kind:'guide',country:'Jamaica',title:'Kingston eats',intro:'A slow afternoon.',guidePlaces:[{id:'a',type:'place',name:'The bakery',text:'Try the warm patty.'}],channels:['app','instagram'],social:{format:'carousel'}});
  const derived=instagramFromDraft(draft);
  assert.match(derived.caption,/Kingston eats/);assert.match(derived.caption,/Try the warm patty/);assert.match(derived.outline,/Slide 2 — The bakery/);
  assert.doesNotMatch(derived.caption,/Sight|Scent|Texture/);
  assert.deepEqual(draft.channels,['app','instagram']);
});
test('Instagram-only drafts and legacy drafts retain their intended destination',()=>{
  assert.deepEqual(normalizeDraft({contentPurpose:'instagram'}).channels,['instagram']);
  assert.deepEqual(normalizeDraft({kind:'post'}).channels,['app']);
});

test('Instagram media does not require a country and legacy social drafts become external',()=>{assert.match(contentMediaPath({purpose:'instagram',draftId,photoId}),/^external\/instagram\//);assert.equal(normalizeDraft({contentPurpose:'instagram',country:'Jamaica'}).country,'External');});
