import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeDraft, storyText, wordCount, moveBlock, templateBlocks } from '../js/admin-content-model.js';

test('old drafts retain their paragraphs, cover, captions and remaining photos in reading order', () => {
  const old = { title: 'A weekend', body: 'First paragraph.\n\nSecond paragraph.', photos: [{ src: 'cover', caption: 'The coast' }, { src: 'second', caption: 'Lunch' }], stops: ['Breakfast', 'Beach'] };
  const draft = normalizeDraft(old);
  assert.equal(draft.photos.find(photo => photo.id === draft.coverId).caption, 'The coast');
  assert.deepEqual(draft.blocks.map(block => block.type), ['paragraph', 'paragraph', 'image']);
  assert.equal(draft.photos.find(photo => photo.id === draft.blocks[2].photoId).caption, 'Lunch');
  assert.equal(storyText(draft), 'First paragraph.\n\nSecond paragraph.');
  assert.deepEqual(draft.stops, old.stops);
  assert.equal(old.photos[0].id, undefined, 'normalization does not mutate the saved record');
});

test('new block drafts round-trip without duplicating photos or changing a removed cover', () => {
  const original = { coverId: null, photos: [{ id: 'photo-1', src: 'photo', caption: 'A moment' }], blocks: [{ id: 'quote', type: 'quote', text: 'Take your time.' }, { id: 'image', type: 'image', photoId: 'photo-1' }, { id: 'place', type: 'place', slug: 'devon-house', name: 'Devon House', text: 'Go for ice cream.' }] };
  const draft = normalizeDraft(JSON.parse(JSON.stringify(normalizeDraft(original))));
  assert.equal(draft.coverId, null);
  assert.deepEqual(draft.blocks, original.blocks);
  assert.equal(storyText(draft), 'Take your time.\n\nDevon House\nGo for ice cream.');
});

test('reordering keeps photo and place references intact and handles both boundaries', () => {
  const blocks = [{ id: 'a', type: 'paragraph', text: 'Hello' }, { id: 'b', type: 'image', photoId: 'photo' }, { id: 'c', type: 'place', slug: 'place' }];
  assert.equal(moveBlock(blocks, 'a', -1), false);
  assert.equal(moveBlock(blocks, 'c', 1), false);
  assert.equal(moveBlock(blocks, 'missing', -1), false);
  assert.equal(moveBlock(blocks, 'b', -1), true);
  assert.deepEqual(blocks.map(block => block.id), ['b', 'a', 'c']);
  assert.equal(blocks[0].photoId, 'photo');
});

test('starting outlines contain prompts, not invented recommendations or placeholder photos', () => {
  let id = 0;
  for (const name of ['place', 'weekend', 'photos', 'blank']) {
    const blocks = templateBlocks(name, () => String(++id));
    assert.ok(blocks.some(block => block.type === 'paragraph' && block.placeholder));
    assert.ok(blocks.filter(block => block.type === 'paragraph').every(block => block.text === ''));
    assert.ok(blocks.every(block => !block.slug && !block.photoId));
  }
});

test('word count includes title, introduction and place recommendations without counting image data', () => {
  const draft = { title: 'A slow morning', intro: 'Start here.', blocks: [{ type: 'image', photoId: 'large-image' }, { type: 'place', name: 'Devon House', text: 'Go early.' }, { type: 'paragraph', text: '  Enjoy\n the day. ' }] };
  assert.equal(wordCount(draft), 12);
  assert.equal(wordCount({ title: '', intro: '', blocks: [] }), 0);
});

test('guide place blocks migrate to a dedicated unique selection while preserving recommendations', () => {
  const draft = normalizeDraft({ kind: 'guide', blocks: [{ id:'p',type:'paragraph',text:'Introduction' }, { id:'a',type:'place',slug:'devon',name:'Devon House',text:'Go early.' }, { id:'b',type:'place',slug:'devon',name:'Devon House',text:'Try the bakery.' }] });
  assert.equal(draft.blocks.length, 1);
  assert.equal(draft.guidePlaces.length, 1);
  assert.equal(draft.guidePlaces[0].text, 'Go early.\n\nTry the bakery.');
  assert.ok(storyText(draft).includes('Devon House'));
  assert.deepEqual(normalizeDraft(draft), draft);
});

test('guide selections can be toggled without duplicate places and reordered independently of story blocks', async () => {
  const { toggleGuidePlace } = await import('../js/admin-content-model.js');
  const draft = normalizeDraft({kind:'guide',blocks:[{id:'story',type:'paragraph',text:'Story'}]});
  assert.equal(toggleGuidePlace(draft,{slug:'a',name:'First'}),true);
  assert.equal(toggleGuidePlace(draft,{slug:'b',name:'Second'}),true);
  draft.guidePlaces[1].text = 'A recommendation';
  moveBlock(draft.guidePlaces,'b',-1);
  assert.equal(draft.guidePlaces[0].slug,'b');
  assert.equal(draft.guidePlaces[0].text,'A recommendation');
  assert.equal(draft.blocks[0].text,'Story');
  assert.equal(toggleGuidePlace(draft,{slug:'a',name:'First'}),false);
  assert.equal(draft.guidePlaces.length,1);
  assert.deepEqual(normalizeDraft(JSON.parse(JSON.stringify(draft))).guidePlaces,draft.guidePlaces);
});

test('country scoping keeps drafts separate and does not silently assign legacy drafts', async () => {
  const { draftsForCountry } = await import('../js/admin-content-model.js');
  const jamaica = normalizeDraft({id:'jm',country:'Jamaica'});
  const barbados = normalizeDraft({id:'bb',country:'Barbados'});
  const legacy = normalizeDraft({id:'legacy'});
  assert.equal(legacy.country,null);
  assert.deepEqual(draftsForCountry([jamaica,barbados,legacy],'Jamaica').map(d=>d.id),['jm']);
  assert.deepEqual(draftsForCountry([jamaica,barbados,legacy],'Barbados').map(d=>d.id),['bb']);
});

test('guides reject places from another country and preserve country on selected places', async () => {
  const { toggleGuidePlace } = await import('../js/admin-content-model.js');
  const draft=normalizeDraft({kind:'guide',country:'Jamaica'});
  assert.throws(()=>toggleGuidePlace(draft,{slug:'bb',name:'Other place',country:'Barbados'}),/country/);
  assert.equal(draft.guidePlaces.length,0);
  toggleGuidePlace(draft,{slug:'jm',name:'Local place',country:'Jamaica'});
  assert.equal(draft.guidePlaces[0].country,'Jamaica');
  const roundTrip=normalizeDraft(JSON.parse(JSON.stringify({...draft,guideType:'Food trail',guideCategory:'eat',editorialNotes:'An idea'})));
  assert.equal(roundTrip.guideType,'Food trail');assert.equal(roundTrip.guideCategory,'eat');assert.equal(roundTrip.editorialNotes,'An idea');
});
