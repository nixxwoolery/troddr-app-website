// Keep persisted story structure independent of the editor DOM.
export function normalizeDraft(source) {
  const draft = structuredClone(source);
  draft.photos = (draft.photos || []).map((photo, index) => ({ ...photo, id: photo.id || `legacy-photo-${index}` }));
  draft.stops = draft.stops || [];
  draft.country = draft.contentPurpose === 'instagram' ? 'External' : draft.country || null;
  draft.channels = Array.isArray(draft.channels) ? draft.channels : [draft.contentPurpose === 'instagram' ? 'instagram' : 'app'];
  draft.social = { format:'carousel', caption:'', outline:'', ...draft.social };
  draft.photoPlan = draft.photoPlan || (draft.photos.length ? 'provided' : 'undecided');
  if (!Array.isArray(draft.blocks)) {
    draft.blocks = (draft.body || '').split(/\n\s*\n/).filter(Boolean).map((text, index) => ({ id: `legacy-text-${index}`, type: 'paragraph', text }));
    draft.photos.slice(1).forEach(photo => draft.blocks.push({ id: `legacy-block-${photo.id}`, type: 'image', photoId: photo.id }));
  }
  draft.guidePlaces = draft.guidePlaces || [];
  if (draft.kind === 'guide') {
    for (const block of draft.blocks.filter(block => block.type === 'place')) {
      const existing = draft.guidePlaces.find(place => place.slug === block.slug);
      if (!existing) draft.guidePlaces.push({ ...block });
      else if (block.text && block.text !== existing.text) existing.text = [existing.text, block.text].filter(Boolean).join('\n\n');
    }
    draft.blocks = draft.blocks.filter(block => block.type !== 'place');
  }
  if (!draft.blocks.length) draft.blocks.push({ id: 'first-paragraph', type: 'paragraph', text: '' });
  if (draft.coverId === undefined) draft.coverId = draft.photos[0]?.id || null;
  return draft;
}
export function storyText(draft) {
  return [...draft.blocks, ...(draft.guidePlaces || [])].map(block => block.type === 'place' ? [block.name, block.text].filter(Boolean).join('\n') : block.text || '').filter(Boolean).join('\n\n');
}
export function wordCount(draft) {
  return [draft.title, draft.intro, storyText(draft)].filter(Boolean).join(' ').trim().split(/\s+/).filter(Boolean).length;
}
export function moveBlock(blocks, id, direction) {
  const index = blocks.findIndex(block => block.id === id);
  const target = index + direction;
  if (index < 0 || target < 0 || target >= blocks.length) return false;
  [blocks[index], blocks[target]] = [blocks[target], blocks[index]];
  return true;
}
export function templateBlocks(name, makeId) {
  const text = (placeholder = 'Tell the story…') => ({ id: makeId(), type: 'paragraph', text: '', placeholder });
  const heading = value => ({ id: makeId(), type: 'heading', text: value });
  if (name === 'place') return [text('What’s the first thing you’d tell a friend about this place?'), heading('Why go'), text('The details that made it memorable…'), heading('Good to know'), text('When to visit, what to order, or a tip you wish you’d known…')];
  if (name === 'weekend') return [text('Who is this weekend for? Set the pace and the scene.'), heading('The plan'), text('Introduce the route. Choose included places in the Select places section.'), heading('Before you go'), text('Share the practical details: timing, transport, what to bring…')];
  if (name === 'photos') return [text('Where were you, and what made you reach for the camera?')];
  return [text('Start with a moment, a place, or something you want someone to know…')];
}

export function toggleGuidePlace(draft, place) {
  if (draft.country && place.country && draft.country !== place.country) throw new Error('A guide can only include places from its country.');
  const index = draft.guidePlaces.findIndex(item => item.slug === place.slug);
  if (index >= 0) { draft.guidePlaces.splice(index, 1); return false; }
  draft.guidePlaces.push({ id: place.slug, type: 'place', slug: place.slug, name: place.name, town: place.town || '', category: place.category || '', image: place.image || [], address: place.address || '', country: place.country || draft.country || null, text: '' });
  return true;
}

export function draftsForCountry(drafts, country) { return drafts.filter(draft => draft.country === country); }

export function draftForStorage(draft) {
  const copy=structuredClone(draft);
  copy.photos=copy.photos.map(photo=>{if(photo.path){delete photo.src;delete photo.sourcePath;delete photo.uploadError;}return photo;});
  delete copy.sessionOnly;delete copy.sessionEditedAt;
  return copy;
}
export function instagramFromDraft(draft) {
  const title=draft.title || '';
  const places=draft.guidePlaces || [];
  const caption=[title,draft.intro,...places.map(place=>[place.name,place.text].filter(Boolean).join(' — '))].filter(Boolean).join('\n\n');
  const format=draft.social?.format || 'carousel';
  const label=format==='reel'?'Shot':format==='story'?'Story frame':'Slide';
  const lines=[title ? `${label} 1 — ${title}` : ''];
  places.forEach((place,index)=>lines.push(`${label} ${index+2} — ${place.name}${place.text ? '\n'+place.text : ''}`));
  if(!places.length)(draft.photos || []).forEach((photo,index)=>lines.push(`${label} ${index+2} — ${photo.caption || photo.originalName || 'Photo '+(index+1)}`));
  return {caption,outline:lines.filter(Boolean).join('\n\n')};
}
