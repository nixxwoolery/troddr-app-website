export function imageCandidates(value){
 if(Array.isArray(value))return [...new Set(value.flatMap(imageCandidates))];
 if(typeof value!=='string'||!value.trim())return [];
 const text=value.trim();if(text.startsWith('[')){try{return imageCandidates(JSON.parse(text));}catch{}}
 const url=text.replace(/^["']+|["']+$/g,'');return /^https?:\/\//i.test(url)?[url]:[];
}
export function fieldCategory(group){return ({'Food & drink':'eat','Stay details':'stay','Stay & booking operations':'stay','Day passes':'stay','Experiences':'play'})[group]||null;}
export function fieldVisible(field,category){const scope=fieldCategory(field.group);return !scope||scope===String(category||'eat').toLowerCase();}
export function collectionSummary(places){const total=places.length;const counts={eat:0,stay:0,play:0};let photos=0,notes=0;for(const p of places){const category=String(p.category||'').toLowerCase();if(category in counts)counts[category]++;if(imageCandidates(p.image).length)photos++;if(p.curator_note?.trim())notes++;}return {total,counts,photos,notes,missingPhotos:total-photos};}
