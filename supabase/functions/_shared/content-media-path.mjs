export const MEDIA_BUCKET = 'content-media';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function contentMediaPath({country,purpose,draftId,photoId}) {
  if(purpose==='instagram')country='External';
  if(typeof country !== 'string' || !country.trim() || country.length > 120) throw new Error('Country required');
  if(!uuid.test(draftId) || !uuid.test(photoId)) throw new Error('Invalid draft or photo ID');
  const folders={guide:'guides',post:'posts',photo_story:'posts',place_profile:'places',place_update:'places',instagram:'instagram'};
  if(!Object.hasOwn(folders,purpose)) throw new Error('Unsupported content type');
  const slug=country.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
  if(!slug) throw new Error('Invalid country');
  return `${slug}/${folders[purpose]}/${draftId}/photos/${photoId.toLowerCase()}.jpg`;
}
