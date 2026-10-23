import {imageCandidates,fieldVisible,collectionSummary} from './studio-presentation.js';
import {PLACE_FIELDS,placeLabel,readPlaceValue} from './place-fields.js';
import { createPhotoEditor } from './photo-editor.js';
import { openingStats } from './photo-editor-engine.js';
import { contentMediaPath, MEDIA_BUCKET } from '../supabase/functions/_shared/content-media-path.mjs';
import { normalizeDraft, storyText, wordCount, moveBlock, templateBlocks, toggleGuidePlace, draftsForCountry, draftForStorage, instagramFromDraft } from './admin-content-model.js';

const $ = id => document.getElementById(id);
const makeId = () => crypto.randomUUID();
const params = new URLSearchParams(location.search);
const token = params.get('token') || sessionStorage.getItem('troddr_admin_token') || '';
history.replaceState(null, '', location.pathname + location.hash);
  const db = supabase.createClient('https://rprpwudhplodaqmmwqkf.supabase.co', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk');
let selectedCountry = sessionStorage.getItem('troddr_content_country') || 'Jamaica', currentView = 'overview', countryVersion = 0, countryPlaces = [], countryGuides = [];
const heldDrafts=new Map();
let drafts = [], current = null, filter = 'all', dirty = false, ready = false, busy = false;
let autosaveTimer, searchTimer, searchVersion = 0, uploadTarget = 'inline', revision = 0, saving = false;
let savePromise = Promise.resolve(true), focusMode = false;
const notice = (message, error = false) => { $('notice').textContent = !ready && !error ? `${message} Saving is currently unavailable.` : message; $('notice').classList.toggle('error', error); };
function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
async function rpc(name, values = {}) {
  const { data, error } = await db.rpc(name, { p_admin_token: token, ...values });
  if (error) throw error;
  if (data === null) throw new Error('Admin access could not be verified. Sign in again.');
  return data;
}
function grow(input) {
  input.style.height = 'auto'; input.style.height = `${input.scrollHeight}px`;
}
function updateWordCount() {
  if (!current) return;
  const count = wordCount({ ...current, title: $('title').value, intro: $('intro').value });
  $('word-count').textContent = `${count.toLocaleString()} ${count === 1 ? 'word' : 'words'}`;
  renderOpeningMeters(count);
  const socialWords=current.contentPurpose==='instagram'?openingStats($('social-caption').value).words:0;
  window.dispatchEvent(new CustomEvent('troddr:wordcount',{detail:{id:current.id,count:count+socialWords+(current.contentPurpose?.startsWith('place_')?openingStats([current.placeDetails.description,current.placeDetails.curator_note].filter(Boolean).join(' ')).words:0)}}));
}
function changed() {
  dirty = true; revision++; $('saved-state').textContent = ready ? 'Unsaved changes' : 'Not saved · connection needed';
  updateWordCount(); clearTimeout(autosaveTimer);
  if (ready && current && $('title').value.trim()) autosaveTimer = setTimeout(() => saveDraft(false), 1800);
}
function readForm() {
  readSocial();
  if(current?.contentPurpose?.startsWith('place_'))capturePlaceFields();
  for (const key of ['title', 'location', 'category', 'intro']) current[key] = $(key).value;
  current.stops = $('stops').value.split('\n').map(value => value.trim()).filter(Boolean);
  current.body = storyText(current);
  return current;
}
function renderLibrary() {
  $('count').textContent = scopedDrafts().length;
  const list = $('library'); list.replaceChildren();
  const query = $('search').value.trim().toLowerCase();
  const candidates = filter === 'unassigned' ? allDrafts().filter(d => !d.country) : scopedDrafts();
  const visible = candidates.filter(d => (filter === 'all' || filter === 'unassigned' || d.kind === filter) && `${d.title || ''} ${d.location || ''}`.toLowerCase().includes(query));
  visible.forEach(draft => {
    const button = element('button', undefined, 'draft'); button.type = 'button';
    const cover = draft.photos.find(photo => photo.id === draft.coverId);
    if (cover?.src) { const img = element('img', undefined, 'draft-thumb'); img.src = cover.src; img.alt = ''; img.loading = 'lazy'; button.append(img); }
    else button.append(element('div', draft.kind === 'guide' ? '↗' : '✎', 'draft-placeholder'));
    const copy = element('div', undefined, 'draft-copy');
    copy.append(element('small', `${contentLabel(draft)} · ${draft.country || 'COUNTRY NOT SET'} · ${draft.sessionOnly?'UNSAVED IN THIS TAB':'DRAFT'}`, 'type-label'), element('strong', draft.title || 'Untitled story'), element('small', `Edited ${new Date(draft.updated_at || draft.sessionEditedAt || Date.now()).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}${draft.location ? ' · ' + draft.location : ''}`));
    button.append(copy); button.onclick = () => { if (!busy) openDraft(draft); }; list.append(button);
  });
  if (!visible.length) {
    const empty = element('div', undefined, 'empty-library');
    empty.append(element('strong', query || filter !== 'all' ? 'No drafts here yet.' : 'Your next story starts with a small idea.'), element('p', query ? 'Try another title or location.' : 'Choose a starting point above. Your saved stories will be waiting here.'));
    list.append(empty);
  }
}
async function canLeave() {
  clearTimeout(autosaveTimer);
  if (saving) await savePromise;
  return !dirty || confirm('Leave this story and discard your unsaved changes?');
}
async function openDraft(source) {
  if (!await canLeave()) return;
  current = normalizeDraft(source); dirty = Boolean(source.sessionOnly); revision = 0;
  $('home').hidden = true; $('workspace').hidden = false;
  $('kind').textContent = contentLabel(current);
  for (const key of ['title', 'location', 'category', 'intro']) $(key).value = current[key] || (key === 'category' ? 'Explore' : '');
  $('stops').value = current.stops.join('\n'); $('guide-fields').hidden = !current.stops.length;
  $('delete').hidden = !current.updated_at;
  $('saved-state').textContent = !ready ? 'Saving unavailable' : current.updated_at ? 'All changes saved' : 'Unsaved draft';
  $('studio-nav').hidden = true;
  $('guide-tabs').hidden = false;
  $('story-tab').firstChild.textContent = current.kind==='guide'?'03 ':'02 ';
  hydrateSetup();
  setGuideTab(current.updated_at && current.country ? 'story' : 'details');
  renderCover(); renderBlocks(); updateWordCount();
  requestAnimationFrame(() => { document.querySelectorAll('.grow').forEach(grow); });
  window.scrollTo(0, 0);
  if(current.photos.some(photo=>photo.path)){const opening=current;await hydratePhotoUrls([opening]);if(current===opening){renderCover();renderBlocks();renderPhotoIntake();}}
}
async function create(kind, template = 'blank') {
  if (busy) return;
  await openDraft({ id: makeId(), kind, title: '', location: '', category: 'Explore', intro: '', photos: [], stops: [], coverId: null, blocks: templateBlocks(template, makeId) });
}
function renderCover() {
  const photo = current.photos.find(photo => photo.id === current.coverId && photo.src);
  $('cover').classList.toggle('has-cover', Boolean(photo));
  $('cover-image').hidden = !photo; $('remove-cover').hidden = !photo;
  $('cover-caption-label').hidden = !photo; $('cover-caption').value = photo?.caption || '';
  if (photo) { $('cover-image').src = photo.src; $('cover-image').alt = photo.caption || current.title || 'Story cover'; }
  else $('cover-image').removeAttribute('src');
  $('add-cover').replaceChildren(document.createTextNode(photo ? 'Change cover' : '＋ Add a cover photo'));
  if (!photo) $('add-cover').append(element('small', 'Set the scene before the first word.'));
}
function tool(label, action, disabled = false) {
  const button = element('button', label); button.type = 'button'; button.disabled = disabled;
  button.setAttribute('aria-label', label); button.onclick = action; return button;
}
function renderBlocks(focusId) {
  const container = $('blocks'); container.replaceChildren(); let placeNumber = 0;
  current.blocks.forEach((block, index) => {
    const row = element('div', undefined, `block block-${block.type}`); row.dataset.blockId = block.id;
    const controls = element('div', undefined, 'block-tools');
    controls.append(tool('Move up', () => { moveBlock(current.blocks, block.id, -1); changed(); renderBlocks(block.id); }, index === 0), tool('Move down', () => { moveBlock(current.blocks, block.id, 1); changed(); renderBlocks(block.id); }, index === current.blocks.length - 1), tool('Remove', () => {
      if ((block.text?.trim() || block.type === 'image' || block.type === 'place') && !confirm('Remove this block from the story?')) return;
      current.blocks.splice(index, 1);
      if (!current.blocks.length) current.blocks.push(...templateBlocks('blank', makeId));
      changed(); renderBlocks();
    }));
    if (block.type === 'image') controls.append(tool('Edit photo',()=>openDraftPhoto(current.photos.find(photo=>photo.id===block.photoId))),tool('Use as cover', () => { current.coverId = block.photoId; changed(); renderCover(); }));
    row.append(controls);
    if (block.type === 'image') {
      const photo = current.photos.find(photo => photo.id === block.photoId);
      if (!photo) return;
      if(!photo.src){row.append(element('p','Photo preview unavailable. Reopen the draft to retry.','hint'));container.append(row);return;}
      row.classList.add('inline-photo');
      const figure = element('figure'); const img = element('img'); img.src = photo.src; img.alt = photo.caption || 'Story photo';
      const caption = element('input', undefined, 'caption'); caption.value = photo.caption || ''; caption.maxLength = 300; caption.placeholder = 'Add a caption…'; caption.setAttribute('aria-label', 'Photo caption');
      caption.oninput = () => { photo.caption = caption.value; img.alt = caption.value || 'Story photo'; changed(); };
      figure.append(img, caption); row.append(figure);
    } else {
      const input = element('textarea', undefined, 'block-text grow'); input.rows = 1;
      input.value = block.text || ''; input.maxLength = 60000; input.spellcheck = true;
      input.placeholder = block.placeholder || ({ heading: 'A new chapter…', quote: 'Something worth remembering…', paragraph: 'Keep the story going…', place: 'Why should someone stop here? Your recommendation…' }[block.type]);
      input.setAttribute('aria-label', block.type === 'place' ? `Recommendation for ${block.name}` : `${block.type} block ${index + 1}`);
      input.oninput = () => { block.text = input.value; grow(input); changed(); };
      if (block.type === 'place') {
        const card = element('div', undefined, 'place-card'); const top = element('div', undefined, 'place-card-top'); const names = element('div');
        names.append(element('strong', block.name), element('small', [block.town, block.category].filter(Boolean).join(' · ')));
        top.append(element('span', String(++placeNumber).padStart(2, '0'), 'place-number'), names); card.append(top, input); row.append(card);
      } else row.append(input);
    }
    container.append(row);
  });
  requestAnimationFrame(() => {
    container.querySelectorAll('.grow').forEach(grow);
    if (focusId) { const target = [...container.children].find(row => row.dataset.blockId === focusId); target?.querySelector('textarea,input')?.focus(); }
  });
}
function addBlock(type) {
  if (!current || busy) return;
  if (type === 'image') { uploadTarget = 'inline'; $('photos').click(); return; }
  if (type === 'place' && current.kind === 'guide') { setGuideTab('places'); return; }
  if (type === 'place') { $('place-picker').showModal(); $('place-search').focus(); return; }
  const block = { id: makeId(), type, text: '' }; current.blocks.push(block); changed(); renderBlocks(block.id);
}
const disabledBeforeBusy = new WeakMap();
function setBusy(value) {
  busy = value;
  document.querySelectorAll('#setup-form button,#setup-form input,#setup-form select,#setup-form textarea,#editor button,#editor input,#editor textarea,#story-settings input,#story-settings select,#delete,#add-cover,#remove-cover').forEach(node => { if (value) { disabledBeforeBusy.set(node, node.disabled); node.disabled = true; } else if (disabledBeforeBusy.has(node)) node.disabled = disabledBeforeBusy.get(node); });
  $('save').disabled = value || !ready; $('back').disabled = value; $('country-selector').disabled=value;
}
async function resizePhoto(file) {
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) throw new Error('Choose JPG, PNG or WebP photos.');
  if (file.size > 20000000) throw new Error('Each original photo must be under 20 MB.');
  const bitmap = await createImageBitmap(file);
  try {
    const scale = Math.min(1, 1600 / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement('canvas'); canvas.width = Math.max(1, Math.round(bitmap.width * scale)); canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    const context = canvas.getContext('2d'); context.fillStyle = '#fff'; context.fillRect(0, 0, canvas.width, canvas.height); context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return { id: makeId(), src: canvas.toDataURL('image/jpeg', .8), caption: '', originalName:file.name };
  } finally { bitmap.close(); }
}
function prunePhotos() {
  const used = new Set([current.coverId, ...current.blocks.filter(block => block.type === 'image').map(block => block.photoId)]);
  for(const photo of current.photos)if(used.has(photo.id)&&photo.sourcePhotoId)used.add(photo.sourcePhotoId);
  current.photos = current.photos.filter(photo => used.has(photo.id));
}
async function addPhotos(files, target) {
  if (!current || busy || !files.length) return;
  clearTimeout(autosaveTimer); if (saving) await savePromise;
  setBusy(true);
  try {
    prunePhotos();
    if (target === 'cover' && files.length > 1) throw new Error('Choose one photo for the cover.');
    const added = []; for (const file of files) added.push(await resizePhoto(file));
    // Replacing a cover does not consume a slot unless it is also in the story.
    const oldCover = current.coverId;
    const retained = current.photos.filter(photo => target !== 'cover' || photo.id !== oldCover || current.blocks.some(block => block.photoId === photo.id));
    if (retained.length + added.length > 10) throw new Error('Keep each story to 10 photos, including its cover.');
    if (JSON.stringify([...retained.filter(photo=>!photo.path), ...added]).length > 7500000) throw new Error('These photos are too large together. Try fewer photos.');
    current.photos = [...retained, ...added];
    if (target === 'cover') current.coverId = added[0].id;
    else for (const photo of added) { if(target==='intake'&&!current.coverId)current.coverId=photo.id;else current.blocks.push({ id: makeId(), type: 'image', photoId: photo.id }); }
    current.photoPlan='provided';
    changed(); renderCover(); renderBlocks(); renderPhotoIntake(); notice('Photos added. They will upload to this draft’s folder when you save.');
  } catch (error) { notice(error.message, true); }
  finally { $('photos').value = ''; setBusy(false); }
}
async function saveDraft(manual = true) {
  clearTimeout(autosaveTimer);
  if (!current || !ready || busy) return false;
  if (saving) { await savePromise; return dirty ? saveDraft(manual) : true; }
  if(current.contentPurpose?.startsWith('place_')&&!capturePlaceFields())return false;
  readForm();
  if (current.contentPurpose!=='instagram' && !current.country) { notice('Choose a country in Details before saving.', true); setGuideTab('details'); return false; }
  if (!current.title.trim()) { if (manual) { notice('Give your draft a title before saving.', true); $('title').focus(); } return false; }
  if (current.body.length > 60000) { notice('This story is too long to save. Keep the text under 60,000 characters.', true); return false; }
  prunePhotos();
  const snapshot = structuredClone(current), savedRevision = revision;
  saving = true; $('save').disabled = true; $('saved-state').textContent = 'Saving…';
  savePromise = (async () => {
    try {
      await uploadDraftPhotos(snapshot);
      const saved = normalizeDraft(await rpc('admin_save_content_draft', { p_draft: draftForStorage(snapshot) }));
      for(const uploaded of snapshot.photos){const live=current.photos.find(photo=>photo.id===uploaded.id);if(live){live.path=uploaded.path;live.bucket=uploaded.bucket;live.storageId=uploaded.storageId;}}
      saved.photos.forEach(photo=>{photo.src=snapshot.photos.find(item=>item.id===photo.id)?.src;});
      renderPhotoIntake();
      // Only the saved version marker is copied back, so typing can continue during autosave.
      current.updated_at = saved.updated_at;
      heldDrafts.delete(saved.id);
      drafts = drafts.filter(draft => draft.id !== saved.id); drafts.unshift(saved);
      dirty = revision !== savedRevision;
      $('saved-state').textContent = dirty ? 'Unsaved changes' : 'All changes saved'; $('delete').hidden = false;
      if (manual) notice('Draft saved. Your story is private.');
      renderLibrary(); renderOverviewDrafts(); return true;
    } catch (error) {
      $('saved-state').textContent = 'Couldn’t save · try again'; notice(`Your edits are still here, but could not be saved. ${error.message}`, true); return false;
    } finally {
      saving = false; $('save').disabled = !ready;
    }
  })();
  return savePromise;
}
let placeRequest;
async function searchPlaces() {
  const query = $('place-search').value.trim(), version = ++searchVersion;
  placeRequest?.abort(); placeRequest = new AbortController();
  $('place-results').replaceChildren(element('p', query.length < 2 ? 'Type at least two letters to find a place.' : 'Finding places…', 'hint'));
  if (query.length < 2) return;
  try {
    const { data, error } = await db.from('places').select('slug,name,town,category').eq('country', current?.country || selectedCountry).ilike('name', `%${query.replace(/[\\%_]/g, '\\$&')}%`).order('name').limit(12).abortSignal(placeRequest.signal);
    if (version !== searchVersion) return;
    if (error) throw error;
    const results = $('place-results'); results.replaceChildren();
    for (const place of data || []) {
      const button = element('button', undefined, 'place-result'); button.type = 'button';
      button.append(element('strong', place.name), element('small', [place.town, place.category].filter(Boolean).join(' · ')));
      button.onclick = () => {
        const block = { id: makeId(), type: 'place', ...place, text: '' };
        current.blocks.push(block); changed(); renderBlocks(block.id); $('place-picker').close();
      }; results.append(button);
    }
    if (!data?.length) results.append(element('p', 'No matching places. Try a shorter name.', 'hint'));
  } catch (error) { if (version === searchVersion) $('place-results').replaceChildren(element('p', 'Places could not be loaded. Try again in a moment.', 'hint')); }
}
function preview() {
  readSocial(); readForm(); const article = $('preview-article'); article.replaceChildren();
  const addPhoto = photo => {
    if (!photo?.src) return;
    const figure = element('figure'), img = element('img'); img.src = photo.src; img.alt = photo.caption || current.title;
    figure.append(img); if (photo.caption) figure.append(element('figcaption', photo.caption)); article.append(figure);
  };
  article.append(element('span', [contentLabel(current).toUpperCase(), current.kind === 'guide' ? current.guideType : '', current.country, current.location].filter(Boolean).join(' · '), 'eyebrow'), element('h1', current.title || 'Untitled story'), element('p', current.intro));
  addPhoto(current.photos.find(photo => photo.id === current.coverId));
  for (const src of current.placeDetails?.existingImages || []) if (/^https?:\/\//i.test(src)) addPhoto({src,caption:''});
  let number = 0;
  for (const block of [...current.blocks, ...(current.guidePlaces || [])]) {
    if (block.type === 'image') addPhoto(current.photos.find(photo => photo.id === block.photoId));
    else if (block.type === 'place') {
      const title = element('h2'), link = element('a', `${++number}. ${block.name}`);
      link.href = `/listings/${encodeURIComponent(block.slug)}`; link.target = '_blank'; link.rel = 'noopener'; title.append(link); article.append(title, element('p', block.text));
    } else if (block.text?.trim()) article.append(element({ heading: 'h2', quote: 'blockquote' }[block.type] || 'p', block.text));
  }
  if (current.stops.length) { article.append(element('h2', 'Guide notes')); const list = element('ol'); current.stops.forEach(stop => list.append(element('li', stop))); article.append(list); }
  if(current.channels.includes('instagram')){article.append(element('h2','Instagram · '+current.social.format),element('p',current.social.caption),element('p',current.social.outline));}
  $('preview').showModal();
}
function toggleSettings(value) {
  $('story-settings').hidden = !value; $('settings-toggle').setAttribute('aria-expanded', String(value));
}
function toggleFocus(value) {
  focusMode = value; document.body.classList.toggle('focus-mode', value); $('focus').setAttribute('aria-pressed', String(value)); $('focus').textContent = value ? 'Exit focus' : 'Focus';
  if (value) toggleSettings(false);
  requestAnimationFrame(() => document.querySelectorAll('.grow').forEach(grow));
}
document.querySelectorAll('[data-add]').forEach(button => { button.onclick = () => addBlock(button.dataset.add); });
$('back').onclick = async () => {
  if (!await canLeave()) return;
  current = null; dirty = false; $('workspace').hidden = true; $('home').hidden = false; toggleFocus(false); toggleSettings(false); renderLibrary(); $('studio-nav').hidden = false; showView(currentView); window.scrollTo(0, 0);
};
$('focus').onclick = () => toggleFocus(!focusMode);
$('settings-toggle').onclick = () => toggleSettings($('story-settings').hidden);
$('close-settings').onclick = () => toggleSettings(false);
$('save').onclick = () => saveDraft(true);
$('editor').onsubmit = event => event.preventDefault();
for (const id of ['title', 'intro', 'location', 'category', 'stops']) $(id).addEventListener('input', () => { if ($(id).classList.contains('grow')) grow($(id)); changed(); });
$('photos').onchange = event => addPhotos([...event.target.files], uploadTarget);
$('add-cover').onclick = () => { uploadTarget = 'cover'; $('photos').multiple = false; $('photos').click(); };
// Inline uploads accept multiple photos, while a cover is one photo.
$('photos').addEventListener('click', () => { $('photos').multiple = uploadTarget !== 'cover'; });
$('cover-caption').oninput = () => { const photo = current?.photos.find(photo => photo.id === current.coverId); if (photo) { photo.caption = $('cover-caption').value; changed(); } };
$('remove-cover').onclick = () => { current.coverId = null; changed(); renderCover(); };
$('editor').addEventListener('dragover', event => { if ([...event.dataTransfer.types].includes('Files')) { event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; } });
$('editor').addEventListener('drop', event => { if (event.dataTransfer.files.length) { event.preventDefault(); addPhotos([...event.dataTransfer.files], 'inline'); } });
$('editor').addEventListener('paste', event => { const files = [...(event.clipboardData?.files || [])]; if (files.length) { event.preventDefault(); addPhotos(files, 'inline'); } });
$('delete').onclick = async () => {
  if (!current || busy) return;
  clearTimeout(autosaveTimer); if (saving) await savePromise;
  if (!confirm('Delete this draft and its photos permanently?')) return;
  setBusy(true);
  try {
    await rpc('admin_delete_content_draft', { p_id: current.id }); drafts = drafts.filter(draft => draft.id !== current.id); heldDrafts.delete(current.id);
    current = null; dirty = false; $('workspace').hidden = true; $('home').hidden = false; $('studio-nav').hidden=false; toggleFocus(false); toggleSettings(false); renderLibrary(); renderOverviewDrafts(); showView(currentView); notice('Draft deleted.');
  } catch (error) { notice(`Could not delete draft. ${error.message}`, true); }
  finally { setBusy(false); }
};
$('search').oninput = renderLibrary;
document.querySelectorAll('[data-filter]').forEach(button => { button.onclick = () => { filter = button.dataset.filter; document.querySelectorAll('[data-filter]').forEach(b => b.setAttribute('aria-pressed', String(b === button))); renderLibrary(); }; });
$('preview-button').onclick = preview; $('close-preview').onclick = () => $('preview').close();
$('close-places').onclick = () => $('place-picker').close();
$('place-search').oninput = () => { ++searchVersion; clearTimeout(searchTimer); searchTimer = setTimeout(searchPlaces, 300); };
window.addEventListener('beforeunload', event => { if (dirty || saving || heldDrafts.size) { event.preventDefault(); event.returnValue = ''; } });
document.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's' && current) { event.preventDefault(); saveDraft(true); }
  if (event.key === 'Escape' && focusMode) toggleFocus(false);
});
window.addEventListener('resize', () => document.querySelectorAll('.grow').forEach(grow));
async function load() {
  $('save').disabled = true;
  try {
    if (!token) throw new Error('Open Content Studio from the signed-in admin to connect your draft library.');
    drafts = (await rpc('admin_list_content_drafts')).map(normalizeDraft); ready = true;
    await hydratePhotoUrls(drafts);
    notice('Your private workspace · Changes save automatically after you add a title.');
  } catch (error) {
    notice(`You can try the editor. Saving is unavailable until the draft library is connected. ${error.message}`, true);
  } finally { $('save').disabled = !ready; renderLibrary(); renderOverviewDrafts(); if(currentView==='instagram')renderInstagramLibrary(); }
}

let guideCategory = 'all', guideQueryTimer, guideVersion = 0, guidePage = 0, guideResults = [], guideRequest;
function setGuideTab(tab) {
  const places = tab === 'places' && current?.kind === 'guide';
  const details = tab === 'details';
  hydrateSocial();
  $('story-layout').hidden = places || details; $('guide-selection').hidden = !places; $('content-setup').hidden = !details;
  $('story-tab').setAttribute('aria-pressed', String(!places && !details)); $('places-tab').setAttribute('aria-pressed', String(places)); $('details-tab').setAttribute('aria-pressed', String(details));
  $('places-tab').hidden = current?.kind !== 'guide';
  $('guide-writing').hidden = current?.kind !== 'guide';
  if (details) hydrateSetup();
  if (places) { renderSelectedPlaces(); searchGuidePlaces(); }
  else if (!details) { renderWritingPlaces(); requestAnimationFrame(() => document.querySelectorAll('.grow').forEach(grow)); }
  if (focusMode && (details || places)) toggleFocus(false);
}

function visualMedia(sources,className,label='Photo needed',category='guide'){
 const wrap=element('span',undefined,`${className} media-surface media-${String(category).toLowerCase()}`);const fallback=element('span',undefined,'media-placeholder');fallback.append(element('span',category==='guide'?'FIELD NOTES':String(category).toUpperCase(),'media-placeholder-kind'),element('strong',label),element('span','TRODDR COLLECTION','media-placeholder-foot'));wrap.append(fallback);
 const candidates=imageCandidates(sources);if(candidates.length){const img=element('img');img.alt='';img.loading='lazy';let index=0;img.onload=()=>{wrap.classList.add('has-photo');};img.onerror=()=>{if(++index<candidates.length)img.src=candidates[index];else{img.remove();wrap.classList.remove('has-photo');}};img.src=candidates[0];wrap.append(img);}return wrap;
}
function placeImage(place,className){return visualMedia(place.image,className,'A photo away',place.category||'place');}
function renderSelectedPlaces() {
  if (!current) return;
  const selected = current.guidePlaces || [];
  $('places-continue').disabled = selected.length === 0;
  $('selected-count').textContent = $('guide-place-count').textContent = selected.length;
  $('selection-total').textContent = `${selected.length} ${selected.length === 1 ? 'place' : 'places'} selected`;
  const list = $('selected-guide-places'); list.replaceChildren();
  if (!selected.length) {
    const empty = element('div', undefined, 'selection-empty'); empty.append(element('span', '＋', 'selection-empty-icon'), element('h3', 'Build your shortlist'), element('p', 'Select places on the left. They’ll appear here, ready to arrange into your guide.')); list.append(empty);
  }
  selected.forEach((place, index) => {
    const card = element('div', undefined, 'selected-place'); const top = element('div', undefined, 'selected-place-top');
    const copy = element('div', undefined, 'selected-place-copy'); copy.append(element('strong', place.name), element('small', [place.town, place.category].filter(Boolean).join(' · ')));
    top.append(element('span', String(index + 1).padStart(2,'0'), 'order-number'), copy);
    const actions = element('div', undefined, 'selection-actions');
    actions.append(tool(`Move ${place.name} up`, () => { moveBlock(selected, place.id, -1); changed(); renderSelectedPlaces(); }, index === 0), tool(`Move ${place.name} down`, () => { moveBlock(selected, place.id, 1); changed(); renderSelectedPlaces(); }, index === selected.length - 1), tool(`Remove ${place.name}`, () => { toggleGuidePlace(current, place); changed(); renderSelectedPlaces(); renderGuideResults(); }));
    actions.children[0].textContent = '↑'; actions.children[1].textContent = '↓'; actions.children[2].textContent = '×';
    top.append(actions);
    const note = element('textarea', undefined, 'place-note'); note.rows = 2; note.value = place.text || ''; note.maxLength = 5000; note.placeholder = 'Your recommendation — what makes this stop worth it?'; note.setAttribute('aria-label', `Guide note for ${place.name}`);
    note.oninput = () => { place.text = note.value; changed(); };
    card.append(top); list.append(card);
  });
}
function renderGuideResults() {
  const results = $('guide-place-results'); results.replaceChildren();
  guideResults.forEach(place => {
    const selected = current.guidePlaces.some(item => item.slug === place.slug);
    const row = element('label', undefined, `browse-place${selected ? ' is-selected' : ''}`);
    const checkbox = element('input'); checkbox.type = 'checkbox'; checkbox.checked = selected; checkbox.setAttribute('aria-label', `Include ${place.name}${place.address ? ' at ' + place.address : ''}`);
    checkbox.onchange = () => { toggleGuidePlace(current, place); changed(); renderSelectedPlaces(); row.classList.toggle('is-selected', checkbox.checked); };
    const copy = element('span', undefined, 'browse-place-copy'); copy.append(element('strong', place.name), element('small', [place.address || place.town, place.category].filter(Boolean).join(' · ')));
    row.append(checkbox, placeImage(place, 'browse-thumb'), copy); results.append(row);
  });
  if (!guideResults.length) results.append(element('p', 'No places match. Try another name, town, or category.', 'results-message'));
}
async function searchGuidePlaces(more = false) {
  if (!current || current.kind !== 'guide') return;
  const version = ++guideVersion; guideRequest?.abort(); guideRequest = new AbortController();
  if (!more) { guidePage = 0; guideResults = []; $('guide-place-results').replaceChildren(element('p', 'Loading places…', 'results-message')); }
  $('more-guide-places').hidden = true;
  const query = $('guide-place-search').value.trim().replace(/[\\%_(),.]/g, ' ').trim();
  try {
    let request = db.from('places').select('slug,name,town,category,image,address,country').eq('country', current.country || selectedCountry).eq('is_hidden', false).order('name').order('slug').range(guidePage * 20, guidePage * 20 + 19);
    if (guideCategory !== 'all') request = request.ilike('category', guideCategory);
    if (query) request = request.or(`name.ilike.%${query}%,town.ilike.%${query}%`);
    const { data, error } = await request.abortSignal(guideRequest.signal);
    if (version !== guideVersion || !current) return;
    if (error) throw error;
    guideResults = more ? [...guideResults, ...(data || [])] : data || [];
    renderGuideResults(); $('more-guide-places').hidden = !data || data.length < 20;
    $('more-guide-places').disabled = false;
  } catch (error) {
    if (version !== guideVersion) return;
    $('guide-place-results').replaceChildren(element('p', 'Places could not be loaded. Use Refresh to try again. Your selections are still here.', 'results-message'));
  }
}
$('details-tab').onclick = () => setGuideTab('details');
$('places-continue').onclick = () => setGuideTab('story');
$('story-tab').onclick = () => setGuideTab('story'); $('places-tab').onclick = () => setGuideTab('places');
$('guide-place-search').oninput = () => { ++guideVersion; clearTimeout(guideQueryTimer); guideQueryTimer = setTimeout(() => searchGuidePlaces(), 300); };
$('refresh-guide-places').onclick = () => searchGuidePlaces();
$('more-guide-places').onclick = () => { guidePage++; $('more-guide-places').disabled = true; searchGuidePlaces(true); };
document.querySelectorAll('[data-place-category]').forEach(button => { button.onclick = () => { guideCategory = button.dataset.placeCategory; document.querySelectorAll('[data-place-category]').forEach(item => item.setAttribute('aria-pressed', String(item === button))); searchGuidePlaces(); }; });



const purposes = { guide:'Guide', post:'Post', photo_story:'Photo story', place_profile:'Place profile', place_update:'Place update', instagram:'Instagram' };
function contentLabel(draft) { return purposes[draft.contentPurpose] || (draft.kind === 'guide' ? 'Guide' : 'Post'); }
function allDrafts(){const combined=new Map(drafts.map(draft=>[draft.id,draft]));for(const [id,draft] of heldDrafts)combined.set(id,draft);return [...combined.values()];}
function scopedDrafts() { return draftsForCountry(allDrafts(), selectedCountry); }
function showView(view) {
  currentView = view;
  if(location.hash!==`#${view}`)history.replaceState(null,'',`#${view}`);
  const panel=$(`view-${view}`);if(panel&&!matchMedia('(prefers-reduced-motion: reduce)').matches){panel.getAnimations().forEach(a=>a.cancel());panel.animate([{opacity:0,transform:'translateY(10px)'},{opacity:1,transform:'translateY(0)'}],{duration:260,easing:'cubic-bezier(.2,.7,.3,1)'});}
  document.querySelector('.country-control').hidden=view==='instagram'||view==='photos';
  document.querySelectorAll('.studio-view').forEach(node => { node.hidden = node.id !== `view-${view}`; });
  document.querySelectorAll('[data-view]').forEach(button => { if (button.dataset.view === view) button.setAttribute('aria-current','page'); else button.removeAttribute('aria-current'); });
  if (view === 'library') renderLibrary();
  if (view === 'places') loadDirectory();
  if (view === 'instagram') renderInstagramLibrary();
  window.scrollTo(0,0);
}
async function navigateView(view) {
  if (current && !await canLeave()) return;
  current = null; dirty = false; $('workspace').hidden = true; $('home').hidden = false; $('studio-nav').hidden = false; toggleFocus(false); toggleSettings(false); showView(view);
}
async function startContent(purpose, sourcePlace) {
  if (busy) return;
  if(sourcePlace){try{const fresh=token?await rpc('admin_studio_get_place',{p_slug:sourcePlace.slug}):await db.from('places').select(PLACE_FIELDS.map(f=>f.key).join(',')+',id,name,country,image').eq('slug',sourcePlace.slug).single().then(r=>{if(r.error)throw r.error;return r.data;});sourcePlace={...sourcePlace,...fresh};}catch(error){notice('Could not load the complete place. Try again before editing.',true);return;}}
  const draft = { id:makeId(), kind:purpose === 'guide' ? 'guide' : 'post', contentPurpose:purpose, country:purpose==='instagram'?'External':selectedCountry, title:'', location:'', category:'Explore', intro:'', photos:[], stops:[], coverId:null, blocks:templateBlocks('blank',makeId), guideType:'Local picks', guideCategory:'mixed', editorialNotes:'', placeDetails:{}, channels:[purpose==='instagram'?'instagram':'app'], social:{format:'carousel',caption:'',outline:''}, photoPlan:'undecided' };
  if (sourcePlace) {
    draft.sourcePlace = { slug:sourcePlace.slug, name:sourcePlace.name, id:sourcePlace.id };
    draft.placeBaseline=Object.fromEntries(PLACE_FIELDS.map(f=>[f.key,sourcePlace[f.key]??null]));
    draft.title = sourcePlace.name; draft.location = sourcePlace.town || '';
    draft.placeDetails = {...draft.placeBaseline,existingImages:sourcePlace.image||[]};
    draft.originalPlaceImages=sourcePlace.image||[];
    draft.intro = '';
    draft.blocks = [{id:makeId(),type:'paragraph',text:sourcePlace.description || ''}];
  }
  await openDraft(draft);
}
function hydrateSetup() {
  if (!current) return;
  const purpose = current.contentPurpose || (current.kind === 'guide' ? 'guide' : 'post');
  const place = purpose.startsWith('place_');
  document.querySelector('.country-control').hidden=purpose==='instagram';
  $('setup-country').hidden=true;
  $('setup-draft-country').closest('label').hidden=true;
  $('setup-kind').textContent = contentLabel(current).toUpperCase();
  $('setup-title').textContent = current.sourcePlace ? `Update ${current.sourcePlace.name}` : `${contentLabel(current)} details`;
  $('setup-subtitle').textContent = current.kind === 'guide' ? 'Define the format, then build your collection of places.' : place ? 'Gather the details and draft the content for this place.' : 'Give the idea a direction. You can refine it as you write.';
  $('setup-country').textContent = current.country || selectedCountry;
  $('setup-name').value = $('title').value || current.title || '';
  $('setup-draft-country').replaceChildren(...[...$('country-selector').options].map(option => { const node = element('option',option.textContent); node.value = option.value; return node; }));
  $('setup-draft-country').value = current.country || selectedCountry;
  $('guide-type').value = current.guideType || 'Local picks'; $('guide-category').value = current.guideCategory || 'mixed'; $('setup-angle').value = current.editorialNotes || '';
  $('guide-setup-fields').hidden = current.kind !== 'guide'; $('place-setup-fields').hidden = !place;
  renderPlaceFields();
  renderSourcePhotos();
  hydrateSocial();renderPhotoIntake();
  $('setup-continue').textContent = current.kind === 'guide' ? 'Choose places →' : 'Continue to writing →';
}
function renderWritingPlaces() {
  const list = $('writing-place-notes'); list.replaceChildren();
  if (current?.kind !== 'guide') return;
  if (!current.guidePlaces.length) {
    const button = element('button','＋ Select places for this guide','secondary'); button.type='button'; button.onclick = () => setGuideTab('places'); list.append(button); return;
  }
  current.guidePlaces.forEach((place,index) => {
    const card = element('section',undefined,'writing-place');
    const heading = element('div',undefined,'writing-place-heading'); const copy = element('div');
    copy.append(element('small',`STOP ${String(index+1).padStart(2,'0')}`),element('h3',place.name),element('p',[place.town,place.category].filter(Boolean).join(' · ')));
    heading.append(placeImage(place,'writing-place-image'),copy); card.append(heading);
    const input = element('textarea',undefined,'place-writing-input'); input.rows=5; input.maxLength=5000; input.value=place.text || ''; input.placeholder='Your recommendation…'; input.setAttribute('aria-label',`Write about ${place.name}`); input.oninput=()=>{place.text=input.value;changed();}; card.append(input);
    const cues=element('details',undefined,'sensory-cues'); cues.append(element('summary','Writing cues'));
    const chips=element('div',undefined,'cue-grid');
    for (const [label,text] of [['Sight','Light, colours, small details.'],['Sound','Music, voices, the surroundings.'],['Scent','The kitchen, the sea, the air.'],['Taste','Flavours that stay with you.'],['Feel','Texture, temperature, atmosphere.']]) { const cue=element('div');cue.append(element('strong',label),element('span',text));chips.append(cue); }
    cues.append(chips,element('p','Use the details you actually noticed. A specific observation says more than a string of adjectives.'));card.append(cues);list.append(card);
  });
}
$('setup-form').onsubmit = event => {
  event.preventDefault(); if (!current) return;
  const country = current.contentPurpose==='instagram'?'External':$('setup-draft-country').value;
  if (current.sourcePlace && country !== current.country) { notice('A place update stays in the country of its source place. Create a new draft for another country.',true); return; }
  if (country !== current.country && current.guidePlaces.length) {
    if (!confirm('Changing the guide country removes its selected places. Continue?')) return;
    current.guidePlaces=[];
  }
  current.country=country; current.title=$('setup-name').value; $('title').value=current.title;
  current.guideType=$('guide-type').value; current.guideCategory=$('guide-category').value; current.editorialNotes=$('setup-angle').value;
  if(current.contentPurpose.startsWith('place_')&&!capturePlaceFields())return;
  if (current.kind==='guide') { guideCategory=current.guideCategory === 'mixed' ? 'all' : current.guideCategory; document.querySelectorAll('[data-place-category]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.placeCategory===guideCategory))); }
  changed(); setGuideTab(current.kind==='guide' ? 'places' : 'story');
};
// Keep setup edits in the same draft so navigation and autosave never lose them.
for (const id of ['setup-name','setup-angle','guide-type','guide-category']) $(id).addEventListener('input',()=>{
  if (!current) return;
  current.title=$('setup-name').value; $('title').value=current.title; current.editorialNotes=$('setup-angle').value;
  current.guideType=$('guide-type').value; current.guideCategory=$('guide-category').value;
  changed();
});
document.querySelectorAll('[data-view]').forEach(button=>{button.onclick=()=>navigateView(button.dataset.view);});
document.querySelectorAll('[data-create]').forEach(button=>{button.onclick=()=>button.dataset.create==='place_update'?showView('places'):startContent(button.dataset.create);});
$('overview-create').onclick=$('library-create').onclick=()=>showView('create');
$('overview-guide').onclick=()=>startContent('guide'); $('overview-place').onclick=()=>showView('places'); $('directory-new').onclick=()=>startContent('place_profile');
let directoryPage=0,directoryVersion=0,directoryTimer,directoryRows=[];
function publicPlaceCard(place, mode='directory') {
  const card=element('article',undefined,'directory-card'); card.append(placeImage(place,'directory-image'));
  const body=element('div',undefined,'directory-copy');body.append(element('small',[place.category,place.town].filter(Boolean).join(' · '),'place-meta'),element('h3',place.name));
  if(place.address)body.append(element('p',place.address));
  const actions=element('div',undefined,'directory-actions');
  const update=element('button',mode==='inspiration'?'Build a guide':'Edit place ↗','text-button'); update.onclick=()=>mode==='inspiration'?startGuideFromPlace(place):startContent('place_update',place);
  const link=element('a','View ↗');link.href=`/listings/${encodeURIComponent(place.slug)}`;link.target='_blank';link.rel='noopener';actions.append(update,link);body.append(actions);card.append(body);return card;
}
async function startGuideFromPlace(place){await startContent('guide');if(current?.kind==='guide'&&current.country===place.country){toggleGuidePlace(current,place);changed();}}
async function loadDirectory(more=false){
  const version=++directoryVersion; if(!more){directoryPage=0;directoryRows=[];$('directory-list').replaceChildren(element('p','Loading places…','empty-message'));}
  $('directory-more').hidden=true;
  try {
    let query=db.from('places').select('slug,name,town,category,country,image,address,description,website,phone:phone_number').eq('country',selectedCountry).eq('is_hidden',false).order('name').order('slug').range(directoryPage*18,directoryPage*18+17);
    const search=$('directory-search').value.trim().replace(/[^\p{L}\p{N}\s'-]/gu,' ');
    if(search)query=query.or(`name.ilike.%${search}%,town.ilike.%${search}%`);
    if($('directory-category').value!=='all')query=query.ilike('category',$('directory-category').value);
    const {data,error}=await query;if(version!==directoryVersion)return;if(error)throw error;
    directoryRows=more?[...directoryRows,...data]:data;$('directory-list').replaceChildren(...directoryRows.map(place=>publicPlaceCard(place)));
    if(!directoryRows.length)$('directory-list').append(element('p','No places match this search.','empty-message'));
    $('directory-more').hidden=data.length<18;$('directory-more').disabled=false;
  }catch(error){if(version===directoryVersion)$('directory-list').replaceChildren(element('p','The directory could not be loaded. Change the search to try again.','empty-message'));}
}
$('directory-search').oninput=()=>{++directoryVersion;clearTimeout(directoryTimer);directoryTimer=setTimeout(()=>loadDirectory(),300);};
$('directory-category').onchange=()=>loadDirectory();$('directory-more').onclick=()=>{directoryPage++;$('directory-more').disabled=true;loadDirectory(true);};
async function allCountrySlugs(table,country){
  let rows=[],page=0;
  while(true){const {data,error}=await db.from(table).select('slug').eq('country',country).order('slug').range(page*1000,page*1000+999);if(error)throw error;rows.push(...data);if(data.length<1000)break;page++;}
  return new Set(rows.map(row=>row.slug));
}
function renderOverviewDrafts(){
  const list=$('recent-draft');list.replaceChildren();const scoped=scopedDrafts();$('stat-drafts').textContent=ready?scoped.length:'—';
  if(scoped[0]){const button=element('button',undefined,'resume-draft');button.append(element('small','CONTINUE EDITING'),element('strong',scoped[0].title || 'Untitled draft'),element('span',`${contentLabel(scoped[0])} →`));button.onclick=()=>openDraft(scoped[0]);list.append(button);}
  else list.append(element('p',ready?'No drafts in this country yet. Choose a format to start.':'Your drafts will appear here when your admin library is connected.','empty-message'));
}
let performanceCache;
async function loadCountryContent(){
  const version=++countryVersion,country=selectedCountry;
  document.querySelectorAll('.country-label').forEach(node=>{node.textContent=country;});
  for(const id of ['stat-guides','stat-places','stat-views'])$(id).textContent='—';renderOverviewDrafts();
  for(const id of ['collection-total','collection-photo-count','collection-note-count'])$(id).textContent='—';$('collection-caption').textContent='Loading your collection…';$('collection-mix').replaceChildren();
  loadCollectionSummary(country,version);
  $('performance-list').replaceChildren(element('p',token?'Loading performance…':'Sign in through the admin to see performance for this country.','empty-message'));
  const results=await Promise.allSettled([
    db.from('places').select('slug,name,town,category,country,image,address,description,website,phone:phone_number',{count:'exact'}).eq('country',country).eq('is_hidden',false).order('name').limit(6),
    db.from('guides').select('slug,title,image_url,type,description,category,country',{count:'exact'}).eq('country',country).order('created_at',{ascending:false}).limit(1000)
  ]);
  if(version!==countryVersion)return;
  const places=results[0].status==='fulfilled'&&!results[0].value.error?results[0].value:null;
  const guides=results[1].status==='fulfilled'&&!results[1].value.error?results[1].value:null;
  countryPlaces=places?.data||[];countryGuides=guides?.data||[];
  $('stat-places').textContent=places?.count?.toLocaleString()??'—';$('stat-guides').textContent=guides?.count?.toLocaleString()??'—';
  $('overview-inspiration').replaceChildren(...countryPlaces.slice(0,3).map(place=>publicPlaceCard(place,'inspiration')));
  $('country-inspiration').replaceChildren(...countryPlaces.map(place=>publicPlaceCard(place,'inspiration')));
  if(!countryPlaces.length){for(const id of ['overview-inspiration','country-inspiration'])$(id).append(element('p',places?'No places found for this country.':'Places are unavailable right now.','empty-message'));}
  countryGuides=await resolveGuideImages(countryGuides);if(version!==countryVersion)return;
  $('country-guides').replaceChildren(...countryGuides.map(guideCard));
  renderOverviewGallery();
  if(!countryGuides.length)$('country-guides').append(element('p',guides?'No published guides found for this country.':'Guides are unavailable right now.','empty-message'));
  if(!token)return;
  try{
    const [performance,placeSlugs,guideSlugs]=await Promise.all([performanceCache?Promise.resolve(performanceCache):rpc('admin_get_performance',{p_days:30}),allCountrySlugs('places',country),allCountrySlugs('guides',country)]);
    if(version!==countryVersion)return;performanceCache=performance;
    const rows=[...(performance.places||[]).filter(row=>placeSlugs.has(row.slug)).map(row=>({...row,kind:'Place'})),...(performance.guides||[]).filter(row=>guideSlugs.has(row.slug)).map(row=>({...row,kind:'Guide'}))].sort((a,b)=>(b.views||0)-(a.views||0));
    $('stat-views').textContent=rows.reduce((sum,row)=>sum+Number(row.views||0),0).toLocaleString();
    $('performance-list').replaceChildren(...rows.filter(row=>Number(row.views)>0).slice(0,5).map((row,index)=>{const item=element('a',undefined,'performance-row');item.href=row.kind==='Guide'?`/guides/${encodeURIComponent(row.slug)}`:`/listings/${encodeURIComponent(row.slug)}`;item.target='_blank';item.rel='noopener';const copy=element('div');copy.append(element('strong',row.name||row.title),element('small',row.kind));const value=element('div',undefined,'performance-value');value.append(element('strong',Number(row.views||0).toLocaleString()),element('small','views'));item.append(element('span',String(index+1).padStart(2,'0'),'rank'),copy,value);return item;}));
    if(!$('performance-list').children.length)$('performance-list').append(element('p','No recorded content views for this country in the last 30 days.','empty-message'));
  }catch(error){if(version===countryVersion)$('performance-list').replaceChildren(element('p','Performance is unavailable. The existing admin analytics connection is required.','empty-message'));}
}
async function loadCountries(){
  try{
    const names=new Set(['Jamaica']);let page=0;
    while(true){const {data,error}=await db.from('places').select('country').not('country','is',null).order('country').range(page*1000,page*1000+999);if(error)throw error;data.forEach(row=>{if(row.country?.trim())names.add(row.country);});if(data.length<1000)break;page++;}
    if(!names.has(selectedCountry))selectedCountry='Jamaica';
    $('country-selector').replaceChildren(...[...names].sort((a,b)=>a.localeCompare(b)).map(name=>{const option=element('option',name);option.value=name;return option;}));$('country-selector').value=selectedCountry;
  }catch(error){$('country-selector').value='Jamaica';selectedCountry='Jamaica';}
  loadCountryContent();
}
$('country-selector').onchange=async()=>{
  const next=$('country-selector').value;
  if(current&&!await canLeave()){$('country-selector').value=selectedCountry;return;}
  ++guideVersion;guideRequest?.abort();++searchVersion;placeRequest?.abort();
  current=null;dirty=false;selectedCountry=next;sessionStorage.setItem('troddr_content_country',next);
  $('workspace').hidden=true;$('home').hidden=false;$('studio-nav').hidden=false;toggleFocus(false);toggleSettings(false);
  $('directory-search').value='';guideCategory='all';$('guide-place-search').value='';
  document.querySelectorAll('[data-place-category]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.placeCategory==='all')));
  renderLibrary();showView(currentView);loadCountryContent();
};
function renderSourcePhotos(){
  const target=$('place-source-photos'); target.replaceChildren();
  const images=current?.placeDetails?.existingImages || [];
  const originals=current?.sourceImages || images;
  if(!originals.length)return;
  current.sourceImages=originals;
  target.append(element('p','Existing photos · select the images to retain','hint'));
  const gallery=element('div',undefined,'source-photos');
  originals.forEach(src=>{if(!/^https?:\/\//i.test(src))return;const label=element('label',undefined,'source-photo');const image=element('img');image.src=src;image.alt='Existing place photo';const check=element('input');check.type='checkbox';check.checked=images.includes(src);check.onchange=()=>{const kept=new Set(current.placeDetails.existingImages);check.checked?kept.add(src):kept.delete(src);current.placeDetails.existingImages=[...kept];changed();};label.append(image,check,document.createTextNode('Retain'));gallery.append(label);});target.append(gallery);
}
const studioViews = ['overview','create','instagram','photos','library','places','inspiration'];
const routeView = () => studioViews.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'overview';
window.addEventListener('hashchange', () => navigateView(routeView()));
showView(routeView());


function mediaPurpose(draft){return draft.contentPurpose || (draft.kind==='guide'?'guide':'post');}
async function mediaCall(values){
  const {data,error}=await db.functions.invoke('admin-content-media',{body:{admin_token:token,...values}});
  if(error||data?.error)throw new Error(data?.error || 'Photo storage is unavailable. Your photos are still in this tab.');
  return data;
}
async function uploadDraftPhotos(draft){
  for(const photo of draft.photos){
    const storageId=photo.storageId || (/^[0-9a-f-]{36}$/i.test(photo.id)?photo.id:makeId());
    photo.storageId=storageId;
    const pending=current?.id===draft.id?current.photos.find(item=>item.id===photo.id):null;if(pending)pending.storageId=storageId;
    const path=contentMediaPath({country:draft.country,purpose:mediaPurpose(draft),draftId:draft.id,photoId:storageId});
    if(photo.path){if(photo.path!==path)throw new Error('A photo belongs to another content folder. Add it again to this draft.');continue;}
    if(!photo.sourcePath&&!photo.src?.startsWith('data:image/jpeg;base64,'))throw new Error('This photo needs to be uploaded again.');
    $('saved-state').textContent=`Uploading photo ${draft.photos.indexOf(photo)+1} of ${draft.photos.length}…`;
    const result=await mediaCall({action:photo.sourcePath?'copy':'upload',sourcePath:photo.sourcePath,country:draft.country,purpose:mediaPurpose(draft),draftId:draft.id,photoId:storageId,src:photo.sourcePath?undefined:photo.src});
    if(result.path!==path||result.bucket!==MEDIA_BUCKET)throw new Error('Photo storage returned an unexpected folder. Saving was stopped.');
    photo.path=result.path;photo.bucket=result.bucket;photo.storageId=storageId;
    // Keep a successful upload manifest even if a later upload/save fails.
    const live=current?.id===draft.id?current.photos.find(item=>item.id===photo.id):null;
    if(live){live.path=photo.path;live.bucket=photo.bucket;live.storageId=photo.storageId;}
  }
}
async function hydratePhotoUrls(records){
  const photos=records.flatMap(draft=>draft.photos).filter(photo=>photo.path);
  const paths=[...new Set(photos.map(photo=>photo.path))];
  try{
    for(let offset=0;offset<paths.length;offset+=100){const result=await mediaCall({action:'urls',paths:paths.slice(offset,offset+100)});for(const item of result.urls||[]){if(item.signedUrl)photos.filter(photo=>photo.path===item.path).forEach(photo=>{photo.src=item.signedUrl;});}}
  }catch(error){notice('Drafts loaded, but some private photo previews could not be opened. Reopen the studio to retry.',true);}
}
function readSocial(){
  if(!current)return;
  current.social={format:$('social-format').value,caption:$('social-caption').value,outline:$('social-outline').value};
}
function hydrateSocial(){
  if(!current)return;
  const isInstagram=current.contentPurpose==='instagram';
  $('social-studio').hidden=!isInstagram;
  $('repurpose-social').hidden=isInstagram;
  $('blocks').hidden=isInstagram;$('insert-menu').hidden=isInstagram;
  $('social-studio').querySelector('.eyebrow').textContent='INSTAGRAM DRAFT';
  renderOpeningMeters();
  $('social-format').value=current.social.format;$('social-caption').value=current.social.caption;$('social-outline').value=current.social.outline;
  const count=current.photos.length+(current.placeDetails?.existingImages?.length||0);
  $('social-photo-status').textContent=count?`${count} ${count===1?'photo':'photos'} available in this draft`:'Photos still needed';
}
function renderPhotoIntake(){
  if(!current)return;
  const retained=current.placeDetails?.existingImages?.length||0;
  const count=current.photos.length+retained;
  const uploaded=current.photos.filter(photo=>photo.path).length;
  $('photo-readiness').textContent=count?`${count} ${count===1?'photo':'photos'}`:current.photoPlan==='later'?'Add photos later':'Photos needed';
  $('photo-intake-status').textContent=current.photos.length?`${uploaded} of ${current.photos.length} new photos uploaded. ${uploaded<current.photos.length?'Keep this tab open and save the draft to upload them.':'Private files are saved in this draft’s folder.'}`:retained?'Existing place photos can be retained below.':'JPG, PNG or WebP. Choose multiple photos, drag them here, or paste from your clipboard.';
  let folder='Choose a country to set the photo folder.';
  if(current.country){const path=contentMediaPath({country:current.country,purpose:mediaPurpose(current),draftId:current.id,photoId:'00000000-0000-4000-8000-000000000000'});folder=`${MEDIA_BUCKET}/${path.slice(0,path.lastIndexOf('/')+1)}`;}
  $('photo-folder').textContent=folder;
  const gallery=$('intake-gallery');gallery.replaceChildren();
  current.photos.forEach(photo=>{const card=element('div',undefined,'intake-photo');if(photo.src){const img=element('img');img.src=photo.src;img.alt=photo.caption || photo.originalName || 'Selected photo';card.append(img);}card.append(element('small',photo.path?'Uploaded · private':'Not uploaded yet'));const remove=element('button','Remove');remove.type='button';remove.onclick=()=>{current.photos=current.photos.filter(item=>item.id!==photo.id);current.blocks=current.blocks.filter(block=>block.photoId!==photo.id);if(current.coverId===photo.id)current.coverId=null;changed();renderCover();renderBlocks();renderPhotoIntake();};const edit=element('button','Edit photo');edit.type='button';edit.onclick=()=>openDraftPhoto(photo);card.append(edit,remove);gallery.append(card);});
  hydrateSocial();
}
$('intake-upload').onclick=()=>{uploadTarget='intake';$('photos').click();};
$('photos-later').onclick=()=>{current.photoPlan='later';changed();renderPhotoIntake();};
$('photo-intake').addEventListener('dragover',event=>{if([...event.dataTransfer.types].includes('Files')){event.preventDefault();$('photo-intake').classList.add('dragging');}});
$('photo-intake').addEventListener('dragleave',()=>$('photo-intake').classList.remove('dragging'));
$('photo-intake').addEventListener('drop',event=>{event.preventDefault();$('photo-intake').classList.remove('dragging');addPhotos([...event.dataTransfer.files],'intake');});
$('photo-intake').addEventListener('paste',event=>{const files=[...(event.clipboardData?.files||[])];if(files.length){event.preventDefault();addPhotos(files,'intake');}});
for(const id of ['social-format','social-caption','social-outline'])$(id).addEventListener('input',()=>{readSocial();changed();});
$('derive-social').onclick=()=>{readForm();const derived=instagramFromDraft(current);if(!current.social.caption.trim())current.social.caption=derived.caption;if(!current.social.outline.trim())current.social.outline=derived.outline;hydrateSocial();changed();notice('An Instagram starting point was built from your draft. Existing caption and outline text were kept.');};
$('make-instagram').onclick=()=>forkInstagram(readForm());
$('export-social').onclick=()=>{
  readSocial();readForm();
  const count=current.photos.length+(current.placeDetails?.existingImages?.length||0);
  if(!count){notice('Add at least one photo before downloading the Instagram brief. You can keep writing while you gather photos.',true);return;}
  const text=[current.title,...(current.contentPurpose==='instagram'?[]:[`Country: ${current.country}`]),`Instagram format: ${current.social.format}`,'','CAPTION',current.social.caption,'','FRAME / SHOT OUTLINE',current.social.outline,'','PHOTOS',...current.photos.map((photo,index)=>`${index+1}. ${photo.caption||photo.originalName||'Photo'} — ${photo.path?`${MEDIA_BUCKET}/${photo.path}`:'Not uploaded yet'}`),...(current.placeDetails?.existingImages||[]).map(src=>`Existing place photo: ${src}`)].join('\n');
  const url=URL.createObjectURL(new Blob([text],{type:'text/plain;charset=utf-8'}));const anchor=element('a');anchor.href=url;anchor.download=`troddr-instagram-${current.id}.txt`;anchor.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
};


const photoEditor=createPhotoEditor($('photo-editor'));
$('create-photo-first').onclick=()=>photoEditor.open({onAttach:choosePhotoPlace});
function openDraftPhoto(photo){
  if(!current)return photoEditor.open();
  const draft=current;
  return photoEditor.open({photos:draft.photos,photo,onApply:copy=>{
    if(current!==draft)throw new Error('Reopen the draft before adding the edited copy.');
    if(draft.photos.length>=10)throw new Error('This draft has ten photos. Download the edited image or remove an unused photo first.');
    if(JSON.stringify([...draft.photos.filter(item=>!item.path),copy]).length>7500000)throw new Error('This copy is too large for the draft. Download it instead.');
    draft.photos.push(copy);draft.blocks.push({id:makeId(),type:'image',photoId:copy.id});if(!draft.coverId)draft.coverId=copy.id;draft.photoPlan='provided';changed();renderCover();renderBlocks();renderPhotoIntake();
  }});
}
$('launch-photo-editor').onclick=$('launch-photo-editor-empty').onclick=()=>photoEditor.open({onAttach:choosePhotoPlace});
$('instagram-photo-editor').onclick=()=>showView('photos');
$('social-edit-photos').onclick=()=>openDraftPhoto();
$('instagram-new').onclick=()=>startContent('instagram');
function renderInstagramLibrary(){
  const list=$('instagram-library');list.replaceChildren();const records=allDrafts();
  for(const draft of records.filter(draft=>draft.contentPurpose==='instagram')){const button=element('button',undefined,'draft');const image=draft.photos.find(photo=>photo.id===draft.coverId)||draft.photos[0];if(image?.src){const img=element('img',undefined,'draft-thumb');img.src=image.src;img.alt='';button.append(img);}const copy=element('div',undefined,'draft-copy');copy.append(element('small',draft.sessionOnly?'UNSAVED IN THIS TAB':'INSTAGRAM DRAFT','type-label'),element('strong',draft.title||'Untitled Instagram draft'),element('small',draft.social.format));button.append(copy);button.onclick=()=>openDraft(draft);list.append(button);}
  if(!list.children.length)list.append(element('p','Your Instagram drafts will appear here. Start fresh or make a version of an app draft.','empty-message'));
  const select=$('instagram-source');select.replaceChildren(element('option','Choose an app draft…'));select.firstChild.value='';
  records.filter(draft=>draft.contentPurpose!=='instagram').forEach(draft=>{const option=element('option',`${draft.title||'Untitled draft'}${draft.country?' · '+draft.country:''}`);option.value=draft.id;select.append(option);});
}
async function forkInstagram(source){
  if(!source)return;
  const snapshot=structuredClone(source);if(current?.id===source.id&&dirty){heldDrafts.set(snapshot.id,{...snapshot,sessionOnly:true,sessionEditedAt:new Date().toISOString()});dirty=false;}
  const fork=normalizeDraft({...snapshot,id:makeId(),kind:'post',contentPurpose:'instagram',country:'External',channels:['instagram'],sourceDraftId:snapshot.id,updated_at:undefined,sessionOnly:true});
  const ids=new Map();fork.photos=fork.photos.map(photo=>{const id=makeId();ids.set(photo.id,id);const next={...photo,id};if(photo.path){next.sourcePath=photo.path;delete next.path;delete next.bucket;delete next.storageId;}return next;});
  fork.photos.forEach(photo=>{if(photo.sourcePhotoId)photo.sourcePhotoId=ids.get(photo.sourcePhotoId)||null;});fork.coverId=ids.get(fork.coverId)||null;fork.blocks.forEach(block=>{if(block.photoId)block.photoId=ids.get(block.photoId);});
  const suggested=instagramFromDraft(snapshot);fork.social={...fork.social,caption:fork.social.caption||suggested.caption,outline:fork.social.outline||suggested.outline};heldDrafts.set(fork.id,{...fork,sessionEditedAt:new Date().toISOString()});
  await openDraft(fork);setGuideTab('story');notice('A separate Instagram draft is ready. Unsaved versions stay in this tab until you save them.');
}
$('instagram-repurpose').onclick=()=>forkInstagram(allDrafts().find(draft=>draft.id===$('instagram-source').value));
function drawOpening(target,stats){target.replaceChildren();if(!stats.characters){target.append(element('span','Your opening will appear here.','opening-empty'));return;}target.append(element('span',stats.visible));const marker=element('span',' … more','opening-break');target.append(marker);if(stats.rest)target.append(element('span',stats.rest,'opening-remainder'));}
function renderOpeningMeters(total){
  if(!current)return;
  const isInstagram=current.contentPurpose==='instagram';$('opening-meter').hidden=isInstagram;
  const intro=$('intro').value||current.blocks.find(block=>block.type==='paragraph')?.text||'';
  const app=openingStats(intro,240);$('story-live-count').textContent=`${total??wordCount(current)} words in this draft`;drawOpening($('app-opening-preview'),app);
  $('app-opening-feedback').textContent=app.characters?`${app.words} opening words · ${app.characters} characters. ${app.rest?'Keep the key idea before the preview break.':'The opening fits within this preview.'}`:'Write an introduction or a first paragraph to check your opening.';
  const social=openingStats($('social-caption').value,$('caption-fold').value);$('caption-count').textContent=`${social.words} words · ${social.characters} characters`;drawOpening($('caption-opening-preview'),social);
  $('caption-opening-feedback').textContent=social.firstSentenceFits===false?'The first sentence continues past this estimated break.':social.firstSentenceFits===true?'The first sentence fits before this estimated break.':'Check that the essential idea is clear above the break.';
}
$('caption-fold').oninput=()=>renderOpeningMeters();
load();loadCountries();

function renderPlaceFields(){
 const root=$('place-complete-fields');root.replaceChildren();if(!current?.contentPurpose?.startsWith('place_'))return;
 const order=['Profile & editorial','Location & contact','Food & drink','Stay details','Experiences','Day passes','Stay & booking operations','Structured hours','Publishing & organisation'];const groups=new Map();for(const field of [...PLACE_FIELDS].sort((a,b)=>order.indexOf(a.group)-order.indexOf(b.group))){let section=groups.get(field.group);if(!section){section=element('details',undefined,'place-field-section');section.open=field.group==='Profile & editorial'||field.group==='Location & contact';section.dataset.fieldGroup=field.group;section.append(element('summary',field.group));const grid=element('div',undefined,'place-field-grid');section.append(grid);root.append(section);groups.set(field.group,section);}const label=element('label',placeLabel(field.key));const input=element(field.key==='category'?'select':field.type==='json'||field.type==='array'||['description','curator_note','recommended_dishes','day_pass_notes','internal_booking_notes'].includes(field.key)?'textarea':'input');input.id=`place-${field.key}`;input.dataset.placeField=field.key;if(field.key==='category'){for(const [value,label] of [['eat','Eat'],['stay','Stay'],['play','Play']]){const option=element('option',label);option.value=value;input.append(option);}}const defaults={category:'eat',booking_mode:'request_only',stay_booking_mode:'request_only',min_nights:1,hold_expiry_minutes:10,deposit_currency:'USD'};let value=current.placeDetails[field.key]??defaults[field.key]??'';if(field.key==='category')value=String(value).toLowerCase();if(field.type==='boolean'){input.type='checkbox';input.checked=Boolean(value);}else{if(field.type==='number'){input.type='number';input.step='any';}input.value=field.type==='json'?(value?JSON.stringify(value,null,2):''):field.type==='array'?(value||[]).join('\n'):value;}label.append(input);section.lastChild.append(label);input.addEventListener('input',()=>{try{current.placeDetails[field.key]=readPlaceValue(field,input);input.setCustomValidity('');if(field.key==='category')updatePlaceCategory();changed();}catch{input.setCustomValidity('Enter valid JSON.');input.reportValidity();}});}
 updatePlaceCategory();
 $('place-apply-status').textContent=ready?'Changes stay private until you apply them.':'Connect the admin draft library to save and apply changes.';
}
function capturePlaceFields(){if(!current)return false;try{for(const f of PLACE_FIELDS){const input=$(`place-${f.key}`);if(input&&fieldVisible(f,$('place-category')?.value))current.placeDetails[f.key]=readPlaceValue(f,input);}return true;}catch(error){notice('Check the place fields: '+error.message,true);return false;}}
let pendingPlacePhoto=null,targetTimer,targetVersion=0;
function choosePhotoPlace(photo){pendingPlacePhoto=photo;photoEditor.close();$('photo-target-country').textContent=`Choose a place in ${selectedCountry}.`;$('photo-target-search').value='';$('photo-place-target').showModal();searchPhotoTargets();}
async function searchPhotoTargets(){const version=++targetVersion;const root=$('photo-target-results');root.replaceChildren(element('p','Loading places…'));const q=$('photo-target-search').value.trim().replace(/[^\p{L}\p{N}\s'-]/gu,' ');const {data,error}=await db.from('places').select('id,slug,name,town,country').eq('country',selectedCountry).ilike('name',`%${q}%`).order('name').limit(20);if(version!==targetVersion)return;root.replaceChildren();if(error){root.append(element('p','Places could not be loaded. Try again.'));return;}for(const place of data){const button=element('button',`${place.name}${place.town?' · '+place.town:''}`,'photo-target-result');button.onclick=()=>attachPhotoToPlace(place);root.append(button);}if(!data.length)root.append(element('p','No match. Create a new place above.'));}
async function attachPhotoToPlace(place){const photo=pendingPlacePhoto;if(!photo)return;$('photo-place-target').close();await startContent(place?'place_update':'place_profile',place);if(!current?.contentPurpose?.startsWith('place_')||(place&&current.sourcePlace?.slug!==place.slug))return;current.photos.push(photo);current.blocks.push({id:makeId(),type:'image',photoId:photo.id});current.coverId=photo.id;current.photoPlan='provided';pendingPlacePhoto=null;changed();renderCover();renderBlocks();renderPhotoIntake();notice('Photo attached. Review the place details and apply when ready.');}
$('photo-target-new').onclick=()=>attachPhotoToPlace(null);$('photo-target-close').onclick=()=>$('photo-place-target').close();$('photo-target-search').oninput=()=>{clearTimeout(targetTimer);targetTimer=setTimeout(searchPhotoTargets,250);};
$('apply-place').onclick=()=>{if(!capturePlaceFields())return;readForm();if(!current.title.trim()){notice('Add the place name first.',true);return;}const root=$('place-review-content');root.replaceChildren(element('p',current.sourcePlace?'This updates the existing place in the app.':'This creates a new place in the app.'),element('h3',current.title),element('p',`${current.photos.length} new photos · ${(current.placeDetails.existingImages||[]).length} retained photos`));for(const f of PLACE_FIELDS){const value=current.placeDetails[f.key];if(fieldVisible(f,current.placeDetails.category)&&value!=null&&value!==''){root.append(element('strong',placeLabel(f.key)),element('p',typeof value==='object'?JSON.stringify(value):String(value)));}}$('place-review-confirm').disabled=!ready;$('place-review-title').textContent=current.sourcePlace?'Review place update':'Review new place';$('place-review').showModal();};
$('place-review-cancel').onclick=()=>$('place-review').close();
$('place-review-confirm').onclick=async()=>{if(!await saveDraft())return;$('place-review-confirm').disabled=true;try{const result=await mediaCall({action:'publish-place',draftId:current.id,expectedRevision:current.updated_at});current.sourcePlace=result.sourcePlace;current.placeBaseline=result.baseline;current.originalPlaceImages=result.images;current.placeDetails.existingImages=result.images;current.photos=[];current.coverId=null;current.blocks=current.blocks.filter(b=>b.type!=='image');current.contentPurpose='place_update';changed();await saveDraft(false);$('place-review').close();renderPhotoIntake();notice('Place updated in the app.');}catch(error){notice('Could not apply the place: '+error.message,true);}finally{$('place-review-confirm').disabled=!ready;}};

function updatePlaceCategory(){const category=$('place-category')?.value||'eat';for(const section of document.querySelectorAll('[data-field-group]'))section.hidden=!fieldVisible({group:section.dataset.fieldGroup},category);$('place-setup-fields').dataset.category=category;}
function guideCard(guide){const card=element('a',undefined,'published-guide');card.href=`/guides/${encodeURIComponent(guide.slug)}`;card.target='_blank';card.rel='noopener';card.append(visualMedia([guide.image_url,...(guide.placeImages||[])],'guide-visual',guide.title||'A new perspective','guide'));const copy=element('div',undefined,'guide-card-copy');copy.append(element('small',guide.type||'Guide'),element('h3',guide.title),element('span','Explore guide ↗','guide-card-link'));card.append(copy);return card;}
async function resolveGuideImages(guides){if(!guides.length)return guides;const {data,error}=await db.from('view_guide_details').select('guide_slug,image,ordering').in('guide_slug',guides.map(g=>g.slug)).order('ordering');if(error)return guides;return guides.map(guide=>({...guide,placeImages:(data||[]).filter(row=>row.guide_slug===guide.slug).flatMap(row=>imageCandidates(row.image))}));}
async function loadCollectionSummary(country,version){try{let rows=[],page=0;while(true){const {data,error}=await db.from('places').select('category,image,curator_note').eq('country',country).eq('is_hidden',false).order('id').range(page*1000,page*1000+999);if(error)throw error;rows.push(...data);if(data.length<1000)break;page++;}if(version!==countryVersion)return;const summary=collectionSummary(rows);$('collection-total').textContent=summary.total.toLocaleString();$('collection-photo-count').textContent=summary.photos.toLocaleString();$('collection-note-count').textContent=summary.notes.toLocaleString();const root=$('collection-mix');root.replaceChildren();for(const [key,label] of [['eat','Eat'],['stay','Stay'],['play','Play']]){const item=element('button',undefined,`mix-item mix-${key}`);const bar=element('span',undefined,'mix-bar');bar.style.setProperty('--fill',`${summary.total?summary.counts[key]/summary.total*100:0}%`);item.append(element('span',label),element('strong',summary.counts[key].toLocaleString()),bar);item.onclick=()=>{showView('places');$('directory-category').value=key;loadDirectory();};root.append(item);}$('collection-caption').textContent=`${summary.missingPhotos.toLocaleString()} ${summary.missingPhotos===1?'place needs':'places need'} a photo · ${summary.total.toLocaleString()} places in the collection`;}catch{if(version===countryVersion)$('collection-caption').textContent='Collection coverage is unavailable right now.';}}
function renderOverviewGallery(){const root=$('overview-guides');root.replaceChildren(...countryGuides.slice(0,3).map(guideCard));if(!countryGuides.length)root.append(element('p','Your published guides will appear here.','empty-message'));const mosaic=$('overview-mosaic');mosaic.replaceChildren();const candidates=[...countryGuides.filter(g=>imageCandidates([g.image_url,...(g.placeImages||[])]).length).map(g=>({image:[g.image_url,...(g.placeImages||[])],name:g.title,category:'guide'})),...countryPlaces.filter(p=>imageCandidates(p.image).length)].slice(0,3);for(const place of candidates){const frame=element('div',undefined,'mosaic-frame');frame.append(visualMedia(place.image,'mosaic-image',place.name,place.category),element('span',place.name,'mosaic-label'));mosaic.append(frame);}if(!candidates.length)mosaic.append(element('div','Your next discovery starts here.','mosaic-empty'));}

$('overview-all-guides').onclick=()=>showView('inspiration');
