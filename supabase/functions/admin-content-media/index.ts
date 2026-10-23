import { createClient } from 'npm:@supabase/supabase-js@2';
import { contentMediaPath, MEDIA_BUCKET } from '../_shared/content-media-path.mjs';
const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,x-client-info,apikey,content-type','Access-Control-Allow-Methods':'POST,OPTIONS'};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}});
Deno.serve(async(req)=>{
  if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(req.method!=='POST')return json({error:'POST required'},405);
  if(Number(req.headers.get('content-length')||0)>7500000)return json({error:'Photo too large'},413);
  try{
    const body=await req.json();
    const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    if(typeof body.admin_token!=='string')return json({error:'Admin access required'},401);
    const {data:admin,error:authError}=await db.from('admin_tokens').select('id').eq('token',body.admin_token).eq('is_active',true).maybeSingle();
    if(authError||!admin)return json({error:'Admin access required'},401);
    if(body.action==='publish-place'){
      const {data:draft,error:draftError}=await db.from('admin_content_drafts').select('document,updated_at').eq('id',body.draftId).single();
      if(draftError||!draft||draft.updated_at!==body.expectedRevision)return json({error:'Save and review the latest draft first'},409);
      const doc=draft.document;
      if(!['place_profile','place_update'].includes(doc.contentPurpose))return json({error:'Place draft required'},400);
      const placeId=doc.sourcePlace?.id||body.draftId;
      const {data:existing}=await db.from('places').select('image').eq('id',placeId).maybeSingle();
      const retained=doc.placeDetails?.existingImages||[];
      if(!Array.isArray(retained)||retained.some((url:string)=>!existing?.image?.includes(url)))return json({error:'Retained photos must belong to the source place'},400);
      const images=[...retained];
      for(const photo of doc.photos||[]){
        const {data:media}=await db.from('admin_content_media').select('path').eq('path',photo.path).eq('draft_id',body.draftId).eq('country',doc.country).in('purpose',['place_profile','place_update']).maybeSingle();
        if(!media)return json({error:'Save all place photos first'},400);
        const {data:file,error:readError}=await db.storage.from(MEDIA_BUCKET).download(media.path);
        if(readError)return json({error:'Could not read draft photo'},503);
        const publicPath=`place images/${placeId}/${body.draftId}/${photo.id}.jpg`;
        const {error:uploadError}=await db.storage.from('images').upload(publicPath,file,{contentType:'image/jpeg',upsert:true});
        if(uploadError)return json({error:'Could not attach the public photo'},503);
        images.push(db.storage.from('images').getPublicUrl(publicPath).data.publicUrl);
      }
      const {data:applied,error:applyError}=await db.rpc('admin_studio_apply_place',{p_admin_token:body.admin_token,p_draft_id:body.draftId,p_revision:body.expectedRevision,p_images:images});
      if(applyError)return json({error:applyError.message},409);
      return json(applied);
    }
    if(body.action==='urls'){
      if(!Array.isArray(body.paths)||body.paths.length>100||body.paths.some((p:unknown)=>typeof p!=='string'))return json({error:'Invalid photo list'},400);
      if(!body.paths.length)return json({urls:[]});
      const {data:registered,error}=await db.from('admin_content_media').select('path').in('path',body.paths);
      if(error)return json({error:'Media library is unavailable'},503);
      if(registered.length!==new Set(body.paths).size)return json({error:'Unknown photo'},404);
      const {data,error:signError}=await db.storage.from(MEDIA_BUCKET).createSignedUrls(registered.map(row=>row.path),3600);
      if(signError)return json({error:'Could not open photos'},503);
      return json({urls:data});
    }
    if(body.action!=='upload'&&body.action!=='copy')return json({error:'Unknown operation'},400);
    if(body.purpose==='instagram')body.country='External';
    const path=contentMediaPath(body);
    if(body.purpose!=='instagram'){
    const {data:country,error:countryError}=await db.from('places').select('country').eq('country',body.country).limit(1);
    if(countryError||!country?.length)return json({error:'Unknown country'},400);
    }
    const {data:existing,error:lookupError}=await db.from('admin_content_media').select('path').eq('path',path).maybeSingle();
    if(lookupError)return json({error:'Media library is unavailable'},503);
    if(!existing){
      if(body.action==='copy'){
        if(typeof body.sourcePath!=='string')return json({error:'Source photo required'},400);
        const {data:source,error:sourceError}=await db.from('admin_content_media').select('path,country').eq('path',body.sourcePath).maybeSingle();
        if(sourceError||!source||(body.purpose!=='instagram'&&source.country!==body.country))return json({error:'Source photo must belong to this country'},400);
        const {error:copyError}=await db.storage.from(MEDIA_BUCKET).copy(source.path,path);
        if(copyError)return json({error:'Could not copy photo into the Instagram folder. Try again.'},503);
      }else{
      if(typeof body.src!=='string'||body.src.length>7000000||!/^data:image\/jpeg;base64,[A-Za-z0-9+/]+={0,2}$/.test(body.src))return json({error:'A JPEG photo is required'},400);
      const bytes=Uint8Array.from(atob(body.src.split(',')[1]),c=>c.charCodeAt(0));
      if(bytes.length>5000000||bytes.length<4||bytes[0]!==255||bytes[1]!==216||bytes[bytes.length-2]!==255||bytes[bytes.length-1]!==217)return json({error:'Invalid JPEG photo'},400);
      const {error:uploadError}=await db.storage.from(MEDIA_BUCKET).upload(path,bytes,{contentType:'image/jpeg',upsert:true,cacheControl:'3600'});
      if(uploadError)return json({error:'Photo upload failed. Please try again.'},503);
      }
      const {error:registerError}=await db.from('admin_content_media').insert({id:body.photoId,draft_id:body.draftId,country:body.country,purpose:body.purpose,path});
      if(registerError){
        const {data:retryRow}=await db.from('admin_content_media').select('path').eq('path',path).maybeSingle();
        if(!retryRow){await db.storage.from(MEDIA_BUCKET).remove([path]);return json({error:'Could not register photo. Please try again.'},503);}
      }
    }
    const {data:read,error:readError}=await db.storage.from(MEDIA_BUCKET).createSignedUrl(path,3600);
    if(readError)return json({error:'Photo uploaded, but preview could not be opened. Try again.'},503);
    return json({path,bucket:MEDIA_BUCKET,url:read.signedUrl,photoId:body.photoId});
  }catch(error){return json({error:error instanceof Error&&/Invalid|Unsupported|Country required/.test(error.message)?error.message:'Could not process photo'},400);}
});
