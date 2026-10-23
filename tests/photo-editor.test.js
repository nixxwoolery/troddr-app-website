import test from 'node:test';
import assert from 'node:assert/strict';
import {defaultPhotoRecipe,outputSize,cropRect,adjustPixels,sharpenPixels,openingStats} from '../js/photo-editor-engine.js';
import {normalizeDraft,draftForStorage} from '../js/admin-content-model.js';
test('export presets produce intended app and social dimensions and respect rotation for original proportions',()=>{
 const recipe=defaultPhotoRecipe();assert.deepEqual(outputSize(recipe,2400,1600),{width:1600,height:1067});
 assert.deepEqual(outputSize({...recipe,preset:'portrait'},2400,1600),{width:1080,height:1350});
 assert.deepEqual(outputSize({...recipe,preset:'story'},2400,1600),{width:1080,height:1920});
 assert.deepEqual(outputSize({...recipe,rotation:90},2400,1600),{width:1600,height:2400});
});
test('crop stays within source pixels for every pan boundary, zoom and aspect ratio',()=>{
 for(const ratio of [1,.8,9/16,1.6])for(const zoom of [1,2,4])for(const x of [-1,0,1])for(const y of [-1,0,1]){
  const crop=cropRect(1800,1200,ratio,zoom,x,y);assert.ok(crop.x>=0&&crop.y>=0);assert.ok(crop.x+crop.width<=1800.00001&&crop.y+crop.height<=1200.00001);assert.ok(Math.abs(crop.width/crop.height-ratio)<.00001);
 }
});
test('neutral adjustments preserve RGB and alpha, while exposure and saturation actually alter pixels',()=>{
 const original=new Uint8ClampedArray([25,100,200,127,150,60,30,255]);
 assert.deepEqual(adjustPixels(new Uint8ClampedArray(original),defaultPhotoRecipe()),original);
 const bright=adjustPixels(new Uint8ClampedArray(original),{...defaultPhotoRecipe(),exposure:1});assert.ok(bright[0]>original[0]);assert.equal(bright[3],127);
 const mono=adjustPixels(new Uint8ClampedArray(original),{...defaultPhotoRecipe(),saturation:-100});assert.equal(mono[0],mono[1]);assert.equal(mono[1],mono[2]);
});
test('sharpening preserves alpha and does not modify borders',()=>{
 const image=new Uint8ClampedArray(3*3*4).fill(100);image[16]=160;image[19]=77;
 const result=sharpenPixels(new Uint8ClampedArray(image),3,3,50);assert.ok(result[16]>160);assert.equal(result[19],77);assert.equal(result[0],100);
});
test('opening meters count Unicode characters and show the actual content at each adjustable break',()=>{
 const text='Hello 🌴. A longer thought follows here.';const stats=openingStats(text,40);
 assert.equal(stats.characters,Array.from(text).length);assert.equal(stats.words,7);assert.equal(stats.firstSentenceFits,true);
 const long=openingStats('A'.repeat(160)+'. Then a second sentence.',125);assert.equal(long.visible.length,125);assert.ok(long.rest.length>0);assert.equal(long.firstSentenceFits,false);
 assert.equal(openingStats('').words,0);
});
test('photo edit recipes and original references survive storage without signed URLs',()=>{
 const draft=normalizeDraft({photos:[{id:'copy',sourcePhotoId:'original',src:'signed-url',path:'jamaica/instagram/a/photos/b.jpg',editRecipe:{...defaultPhotoRecipe(),texts:[{text:'Kingston',x:.5,y:.7}]}}]});
 const payload=draftForStorage(draft);assert.equal(payload.photos[0].src,undefined);assert.equal(payload.photos[0].sourcePhotoId,'original');assert.equal(payload.photos[0].editRecipe.texts[0].text,'Kingston');
});

test('dehaze removes a bright atmospheric veil, negative values add haze, and alpha survives',()=>{
 const image=new Uint8ClampedArray([180,185,190,128,240,240,240,255]);
 const clear=adjustPixels(new Uint8ClampedArray(image),{...defaultPhotoRecipe(),dehaze:60});
 const hazy=adjustPixels(new Uint8ClampedArray(image),{...defaultPhotoRecipe(),dehaze:-60});
 assert.ok(clear[0]<image[0]);assert.ok(hazy[0]>image[0]);assert.equal(clear[3],128);assert.equal(hazy[3],128);
 assert.ok(clear[4]-clear[0]>image[4]-image[0]);
});
