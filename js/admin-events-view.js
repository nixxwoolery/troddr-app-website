(function () {
  'use strict';

  const state = { db:null, getToken:null, navigate:null, url:'', anon:'', events:[], currentId:null, current:null, tabs:[], tabsUseDefaults:false, tabsLoaded:false, eventView:'overview', filter:'all', query:'', loaded:false, lastFocus:null };
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const fmt = (n) => n == null ? '–' : Number(n).toLocaleString();
  const nice = (s) => String(s ?? '').replace(/_/g, ' ');
  const when = (iso) => iso ? new Date(iso).toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'}) : '';
  const whenTime = (iso) => iso ? new Date(iso).toLocaleString(undefined,{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}) : '';
  const empty = (text) => `<div class="events-empty">${esc(text)}</div>`;
  const eventPhase = (event) => {
    if (event.is_live) return 'live';
    const today = new Date().toISOString().slice(0,10);
    return (event.end_date || event.start_date) < today ? 'past' : 'upcoming';
  };

  function setListState(view, message) {
    $('events-loading').classList.toggle('hidden', view !== 'loading');
    $('events-error').classList.toggle('hidden', view !== 'error');
    $('events-content').classList.toggle('hidden', view !== 'content');
    if (message) $('events-error-message').textContent = message;
  }

  function filteredEvents() {
    const q = state.query.toLowerCase();
    return state.events.filter((event) => (state.filter === 'all' || eventPhase(event) === state.filter)
      && (!q || [event.title,event.town,event.parish,event.venue_name].some((v) => String(v || '').toLowerCase().includes(q))));
  }

  function renderList() {
    const rows = filteredEvents();
    if (!rows.length) { $('events-list').innerHTML = empty('No events match these filters.'); return; }
    let priorPhase = '';
    $('events-list').innerHTML = rows.map((event) => {
      const phase = eventPhase(event);
      const divider = phase !== priorPhase ? `<div class="events-divider">${phase} events</div>` : '';
      priorPhase = phase;
      return `${divider}<button class="events-item ${event.id === state.currentId ? 'active' : ''}" data-event-id="${esc(event.id)}" aria-current="${event.id === state.currentId ? 'true' : 'false'}"><span class="events-item-title">${event.is_live ? '<i class="events-live-dot" aria-label="Live"></i>' : ''}${esc(event.title)}</span><span class="events-item-meta">${when(event.start_date)}${event.end_date && event.end_date !== event.start_date ? ' – '+when(event.end_date) : ''}${event.town ? ' · '+esc(event.town) : ''}</span><span class="events-item-stats">${fmt(event.views_30d)} views 30d · ${fmt(event.interested)} interested · ${fmt(event.feedback)} feedback</span></button>`;
    }).join('');
  }

  function chart(daily) {
    if (!daily.length) { $('event-chart').innerHTML = empty('No activity recorded for this event.'); return; }
    const W=1000,H=220,L=48,R=48,T=18,B=28,iw=W-L-R,ih=H-T-B;
    const maxV=Math.max(1,...daily.map((d)=>Number(d.views)||0)), maxC=Math.max(1,...daily.map((d)=>Number(d.clicks)||0));
    const step=iw/daily.length,bw=Math.max(4,step*.62),pts=[]; let grid='',bars='',labels='';
    for(let g=0;g<=4;g++){const y=T+ih-ih*g/4;grid+=`<line x1="${L}" y1="${y}" x2="${W-R}" y2="${y}" stroke="#f0f0f0"/><text x="${L-8}" y="${y+4}" text-anchor="end" font-size="10" fill="#777">${Math.round(maxV*g/4).toLocaleString()}</text><text x="${W-R+8}" y="${y+4}" text-anchor="start" font-size="10" fill="#777">${Math.round(maxC*g/4).toLocaleString()}</text>`;}
    daily.forEach((d,i)=>{const v=Number(d.views)||0,c=Number(d.clicks)||0,cx=L+step*i+step/2,bh=ih*v/maxV;bars+=`<rect x="${cx-bw/2}" y="${T+ih-bh}" width="${bw}" height="${Math.max(bh,1)}" rx="2" fill="#bcd9f0"><title>${esc(d.d)}: ${fmt(v)} views, ${fmt(c)} vendor clicks</title></rect>`;pts.push(`${cx},${T+ih-ih*c/maxC}`);if(i%5===0||i===daily.length-1)labels+=`<text x="${cx}" y="${H-6}" text-anchor="middle" font-size="10" fill="#999">${esc(String(d.d).slice(5))}</text>`;});
    $('event-chart').innerHTML=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Event views and vendor clicks" style="display:block;width:100%;height:auto"><text x="${L}" y="10" font-size="10" fill="#777">VIEWS</text><text x="${W-R}" y="10" text-anchor="end" font-size="10" fill="#777">VENDOR CLICKS</text>${grid}${bars}<polyline points="${pts.join(' ')}" fill="none" stroke="#0878c9" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>${labels}</svg>`;
  }

  const who = (id,name) => id ? `<button class="events-who" data-user-id="${esc(id)}">${esc(name || 'Unknown user')}</button>` : esc(name || 'Unknown user');
  function ranks(id, rows, name, value) { $(id).innerHTML = rows.length ? rows.map((row)=>`<div class="events-rank"><span class="name">${name(row)}</span><span class="value">${value(row)}</span></div>`).join('') : empty('Nothing to show yet.'); }

  function renderDetail(data) {
    state.current=data; const event=data.event||{},k=data.kpis||{};
    $('event-title').innerHTML=`${esc(event.title)} ${event.is_live?'<span class="events-pill live">● live</span>':''}${event.status?`<span class="events-pill ${esc(event.status)}">${esc(event.status)}</span>`:''}${event.is_featured?'<span class="events-pill featured">featured</span>':''}`;
    $('event-subtitle').textContent=[`${when(event.start_date)}${event.end_date&&event.end_date!==event.start_date?' – '+when(event.end_date):''}`,event.venue_name,event.town,event.parish].filter(Boolean).join(' · ');
    $('event-kpis').innerHTML=[['Views',k.views],['Saves',k.saves],['Interested',k.interested],['Going',k.going],['Vendor clicks',k.vendor_clicks],['Ticket clicks',k.ticket_clicks]].map(([label,value])=>`<div class="events-kpi"><strong>${fmt(value)}</strong><span>${label}</span></div>`).join('');
    $('event-overview-summary').innerHTML=[['Status',nice(event.status||'draft')],['Dates',`${when(event.start_date)}${event.end_date&&event.end_date!==event.start_date?' – '+when(event.end_date):''}`],['Venue',event.venue_name||'Not set'],['Location',[event.town,event.parish].filter(Boolean).join(', ')||'Not set']].map(([label,value])=>`<div class="event-overview-row"><span>${esc(label)}</span><strong>${esc(value)}</strong></div>`).join('');
    $('event-push-audience').textContent=fmt(k.push_audience); chart(data.daily||[]);
    $('event-updates').innerHTML=(data.updates||[]).length?(data.updates||[]).map((u)=>`<div class="events-entry"><strong>${esc(u.title)}</strong><br><small>${whenTime(u.created_at)}</small><p>${esc(u.message)}</p></div>`).join(''):empty('No updates posted yet.');
    $('event-feedback').innerHTML=(data.feedback||[]).length?(data.feedback||[]).map((f)=>`<div class="events-entry"><strong>${who(f.user_id,f.username)}</strong> ${f.vote?`<span class="events-pill ${esc(f.vote)}">${f.vote==='up'?'👍 up':'👎 down'}</span>`:''}<br><small>${when(f.created_at)}</small><p>${Object.entries(f.ratings||{}).map(([key,v])=>`${esc(nice(key))}: ${fmt(v)}`).join(' · ')}${(f.quick_tags||[]).length?' · '+f.quick_tags.map(nice).map(esc).join(', '):''}</p></div>`).join(''):empty('No feedback yet.');
    ranks('event-vendors',data.top_vendors||[],(v)=>esc(v.name),(v)=>fmt(v.clicks));
    ranks('event-deliveries',data.deliveries||[],(d)=>`${esc(nice(d.type))}<small>last ${whenTime(d.last_sent)}</small>`,(d)=>fmt(d.n));
    ranks('event-parking',data.parking||[],(l)=>`${esc(l.name)}<small>${[l.tier,l.capacity&&'cap '+fmt(l.capacity),fmt(l.reports_24h)+' reports 24h'].filter(Boolean).map(esc).join(' · ')}</small>`,(l)=>l.status_override?`<span class="events-pill">${esc(nice(l.status_override))}</span>`:'');
    const audience=[...(data.savers||[]).map((u)=>({...u,status:'saved'})),...(data.interest_users||[])];
    $('event-audience-count').textContent=audience.length?`(${fmt(audience.length)})`:'';
    ranks('event-audience',audience,(u)=>`${who(u.user_id,u.name)}<small>${u.at?whenTime(u.at):''}</small>`,(u)=>`<span class="events-pill ${esc(u.status)}">${esc(u.status)}</span>`);
    const saved=data.saved_items||[], total=saved.reduce((sum,row)=>sum+(Number(row.saves)||0),0);
    $('event-saved-count').textContent=saved.length?`(${fmt(total)} saves)`:'';
    ranks('event-saved-items',saved,(row)=>`${esc(row.item)}<small>${esc(row.vendor)}</small>`,(row)=>fmt(row.saves));
  }

  const EVENT_TABS=[['home','Home'],['schedule','Schedule'],['map','Map'],['vendors','Vendors'],['my_plan','My Plan'],['tickets','Tickets'],['info','Info'],['sponsors','Sponsors'],['events','Events'],['concierge','Concierge']];
  function switchEventView(view) {
    state.eventView=['overview','insights','tabs','updates','audience','operations'].includes(view)?view:'overview';
    document.querySelectorAll('.event-console-tab').forEach(button=>{const active=button.dataset.eventView===state.eventView;button.classList.toggle('active',active);button.setAttribute('aria-selected',String(active));});
    document.querySelectorAll('[data-event-panel]').forEach(panel=>panel.classList.toggle('active',panel.dataset.eventPanel===state.eventView));
    if(state.eventView==='tabs'&&!state.tabsLoaded)loadEventTabs();
  }
  function renderEventTabs() {
    const configured=new Map((state.tabs||[]).map(tab=>[tab.key,tab.label]));
    $('event-tabs-status').innerHTML=state.tabsUseDefaults?'<div class="event-tabs-default-note"><strong>App defaults are active</strong><span>Choose the tabs below and save to create a custom configuration for this event.</span></div>':'<div class="event-tabs-custom-note">Custom tab configuration</div>';
    $('event-tabs-grid').innerHTML=EVENT_TABS.map(([key,label])=>{const checked=configured.has(key)||key==='home';return `<label class="event-tab-toggle ${key==='home'?'required':''}"><span><strong>${esc(configured.get(key)||label)}</strong><small>${key==='home'?'Required primary tab':checked?'Visible in the event':'Hidden from the event'}</small></span><input type="checkbox" data-event-tab-key="${key}" data-event-tab-label="${esc(configured.get(key)||label)}" ${checked?'checked':''} ${key==='home'?'disabled':''}/><i aria-hidden="true"></i></label>`;}).join('');
    $('event-tabs-defaults').disabled=state.tabsUseDefaults;
  }
  async function loadEventTabs() {
    $('event-tabs-grid').innerHTML='<div class="spinner"></div>';$('event-tabs-status').innerHTML='';$('event-tabs-result').textContent='';
    const {data,error}=await state.db.rpc('admin_get_event_tabs',{p_admin_token:state.getToken(),p_event_id:state.currentId});
    if(error||!data){const missing=error&&/schema cache|could not find the function/i.test(error.message||'');$('event-tabs-grid').innerHTML=empty(missing?'Event tab controls need the latest database migration.':'Tab settings could not be loaded'+(error?': '+error.message:'.'));return;}
    state.tabs=data.tabs||[];state.tabsUseDefaults=Boolean(data.uses_defaults);state.tabsLoaded=true;renderEventTabs();
  }
  async function saveEventTabs(useDefaults=false) {
    const result=$('event-tabs-result');result.className='events-result';result.textContent='';
    const tabs=useDefaults?[]:EVENT_TABS.filter(([key])=>key==='home'||document.querySelector(`[data-event-tab-key="${key}"]`)?.checked).map(([key,label])=>({key,label:document.querySelector(`[data-event-tab-key="${key}"]`)?.dataset.eventTabLabel||label}));
    $('event-tabs-save').disabled=true;$('event-tabs-defaults').disabled=true;
    const {data,error}=await state.db.rpc('admin_update_event_tabs',{p_admin_token:state.getToken(),p_event_id:state.currentId,p_tabs:tabs,p_use_defaults:useDefaults});
    $('event-tabs-save').disabled=false;
    if(error||!data){result.className='events-result err';result.textContent=error?.message||'Tab settings could not be saved.';renderEventTabs();return;}
    state.tabs=data.tabs||[];state.tabsUseDefaults=Boolean(data.uses_defaults);renderEventTabs();result.className='events-result ok';result.textContent=useDefaults?'App defaults restored ✓':'Tab visibility saved ✓';
  }

  async function openEvent(id, updateRoute=true) {
    if(!id)return; state.currentId=id; renderList();
    if(updateRoute) state.navigate(id);
    $('event-detail').classList.add('hidden'); $('event-detail-error').classList.add('hidden'); $('event-detail-loading').classList.remove('hidden');
    const {data,error}=await state.db.rpc('admin_get_event_console',{p_admin_token:state.getToken(),p_event_id:id});
    $('event-detail-loading').classList.add('hidden');
    if(error||!data){$('event-detail-error-message').textContent=error?.message||'The event returned no data.';$('event-detail-error').classList.remove('hidden');return;}
    state.tabsLoaded=false;state.eventView='overview';renderDetail(data); $('event-detail').classList.remove('hidden');switchEventView('overview');
  }

  async function load(routeId, force=false) {
    if(state.loaded&&!force){const target=routeId||state.currentId||state.events[0]?.id;if(target&&target!==state.currentId)await openEvent(target,false);return;}
    setListState('loading');
    const {data,error}=await state.db.rpc('admin_list_events',{p_admin_token:state.getToken()});
    if(error||!data){setListState('error',error?.message||'The event list returned no data.');return;}
    state.events=data;state.loaded=true;setListState('content');renderList();
    const target=routeId&&data.some((e)=>e.id===routeId)?routeId:data[0]?.id;
    if(target)await openEvent(target,target!==routeId);else {$('event-detail-loading').classList.add('hidden');$('event-detail').classList.add('hidden');$('event-detail-error-message').textContent='No events are available.';$('event-detail-error').classList.remove('hidden');}
  }

  async function openProfile(id, trigger) {
    state.lastFocus=trigger;$('events-profile-modal').classList.remove('hidden');$('events-profile-body').innerHTML='<div class="spinner"></div>';$('events-profile-close').focus();
    const {data,error}=await state.db.rpc('admin_get_user_profile',{p_admin_token:state.getToken(),p_user_id:id});
    if(error||!data){$('events-profile-body').innerHTML=empty('Could not load this profile.');return;}
    const c=data.counts||{};$('events-profile-body').innerHTML=`<h3 id="events-profile-title">${esc(data.username||'No username set')}</h3><p>${esc(data.email||'')}</p><div class="events-profile-meta">Joined ${when(data.created_at)}${data.last_active_at?' · last active '+when(data.last_active_at):''} · push ${data.push_opt_in?'on':'off'}</div>${[['Places visited',c.visited],['Place feedback',c.place_feedback],['Event feedback',c.event_feedback],['Item ratings',c.item_ratings],['Saved events',c.saved_events],['Loyalty cards',c.loyalty_cards],['Check-ins',c.checkins]].map(([k,v])=>`<div class="events-profile-row"><strong>${k}</strong><span>${fmt(v)}</span></div>`).join('')}`;
  }
  function closeProfile(){ $('events-profile-modal').classList.add('hidden'); state.lastFocus?.focus(); }

  function renderCreateTabs() {
    $('event-create-tabs').innerHTML=EVENT_TABS.map(([key,label])=>`<button type="button" class="event-create-tab ${['home','schedule','info'].includes(key)?'active':''} ${key==='home'?'required':''}" data-create-tab="${key}" data-label="${label}" aria-pressed="${['home','schedule','info'].includes(key)}">${label}</button>`).join('');
  }
  function openCreateEvent() {
    $('event-create-form').reset();$('event-create-result').textContent='';renderCreateTabs();
    const today=new Date().toISOString().slice(0,10), start=$('event-create-form').elements.start_date,end=$('event-create-form').elements.end_date;start.value=today;end.value=today;
    $('event-create-modal').classList.remove('hidden');$('event-create-form').elements.title.focus();
  }
  function closeCreateEvent(){ $('event-create-modal').classList.add('hidden');$('events-add').focus(); }
  async function createEvent(e) {
    e.preventDefault();const form=e.currentTarget,result=$('event-create-result'),button=form.querySelector('[type="submit"]'),values=Object.fromEntries(new FormData(form));
    result.className='events-result';result.textContent='';
    if(values.end_date<values.start_date){result.className='events-result err';result.textContent='End date cannot be before start date.';return;}
    const tabs=EVENT_TABS.filter(([key])=>key==='home'||document.querySelector(`[data-create-tab="${key}"]`)?.classList.contains('active')).map(([key,label])=>({key,label}));
    button.disabled=true;
    const {data,error}=await state.db.rpc('admin_create_event',{p_admin_token:state.getToken(),p_title:values.title,p_start_date:values.start_date,p_end_date:values.end_date,p_start_time:values.start_time||null,p_end_time:values.end_time||null,p_event_type:values.event_type,p_status:values.status,p_venue_name:values.venue_name||null,p_town:values.town||null,p_parish:values.parish||null,p_description:values.description||null,p_ticket_url:values.ticket_url||null,p_tabs:tabs});
    button.disabled=false;
    if(error||!data){result.className='events-result err';result.textContent=error?.message||'The event could not be created.';return;}
    result.className='events-result ok';result.textContent='Event created ✓';closeCreateEvent();state.loaded=false;await load(data.id,true);
  }

  async function postUpdate() {
    const title=$('event-update-title').value.trim(),message=$('event-update-message').value.trim(),sendPush=$('event-update-push').checked,note=$('event-update-result');
    note.className='events-result';note.textContent='';
    if(!title||!message||!state.currentId){note.className='events-result err';note.textContent='Title and message are required.';return;}
    if(sendPush&&!confirm(`Send a push notification to ~${state.current?.kpis?.push_audience??0} people?`))return;
    $('event-update-post').disabled=true;
    const {data,error}=await state.db.rpc('admin_post_event_update',{p_admin_token:state.getToken(),p_event_id:state.currentId,p_title:title,p_message:message});
    if(error||!data){$('event-update-post').disabled=false;note.className='events-result err';note.textContent='Post failed'+(error?': '+error.message:'');return;}
    let push='';
    if(sendPush){try{const response=await fetch(`${state.url}/functions/v1/notify-event-update`,{method:'POST',headers:{'Content-Type':'application/json','Authorization':`Bearer ${state.anon}`,'apikey':state.anon},body:JSON.stringify({admin_token:state.getToken(),event_id:state.currentId,title,message})});const out=await response.json();push=response.ok?` · push sent to ${out.sent??0}`:` · push failed (${out.error||response.status})`;}catch(e){push=' · push failed (network)';}}
    $('event-update-post').disabled=false;$('event-update-title').value='';$('event-update-message').value='';$('event-update-push').checked=false;note.className='events-result ok';note.textContent='Update posted ✓'+push;await openEvent(state.currentId,false);
  }

  function init(options) {
    Object.assign(state,options);
    $('events-search').addEventListener('input',(e)=>{state.query=e.target.value.trim();renderList();});
    document.querySelectorAll('.events-filter').forEach((button)=>button.addEventListener('click',()=>{state.filter=button.dataset.filter;document.querySelectorAll('.events-filter').forEach((b)=>{const active=b===button;b.classList.toggle('active',active);b.setAttribute('aria-pressed',String(active));});renderList();}));
    $('events-list').addEventListener('click',(e)=>{const button=e.target.closest('[data-event-id]');if(button)openEvent(button.dataset.eventId);});
    $('events-content').addEventListener('click',(e)=>{const button=e.target.closest('[data-user-id]');if(button)openProfile(button.dataset.userId,button);});
    $('events-retry').addEventListener('click',()=>load(null,true));$('event-detail-retry').addEventListener('click',()=>openEvent(state.currentId,false));
    $('event-update-post').addEventListener('click',postUpdate);$('events-profile-close').addEventListener('click',closeProfile);$('events-profile-modal').addEventListener('click',(e)=>{if(e.target===$('events-profile-modal'))closeProfile();});
    $('event-tabs-save').addEventListener('click',()=>saveEventTabs(false));$('event-tabs-defaults').addEventListener('click',()=>{if(confirm('Restore the app default tabs for this event?'))saveEventTabs(true);});$('event-tabs-grid').addEventListener('change',(e)=>{const input=e.target.closest('[data-event-tab-key]');if(input){const note=input.closest('.event-tab-toggle').querySelector('small');note.textContent=input.checked?'Visible in the event':'Hidden from the event';}});
    document.querySelectorAll('.event-console-tab').forEach(button=>button.addEventListener('click',()=>switchEventView(button.dataset.eventView)));
    $('events-add').addEventListener('click',openCreateEvent);$('event-create-close').addEventListener('click',closeCreateEvent);$('event-create-cancel').addEventListener('click',closeCreateEvent);$('event-create-modal').addEventListener('click',e=>{if(e.target===$('event-create-modal'))closeCreateEvent();});$('event-create-form').addEventListener('submit',createEvent);$('event-create-tabs').addEventListener('click',e=>{const button=e.target.closest('[data-create-tab]');if(!button||button.classList.contains('required'))return;const active=!button.classList.contains('active');button.classList.toggle('active',active);button.setAttribute('aria-pressed',String(active));});
    document.addEventListener('keydown',(e)=>{if(e.key!=='Escape')return;if(!$('event-create-modal').classList.contains('hidden'))closeCreateEvent();else if(!$('events-profile-modal').classList.contains('hidden'))closeProfile();});
  }

  window.AdminEventsView={init,load,refresh:(routeId)=>load(routeId,true),reset:()=>{state.loaded=false;state.events=[];state.currentId=null;state.current=null;state.tabs=[];state.tabsUseDefaults=false;state.tabsLoaded=false;state.eventView='overview';}};
}());
