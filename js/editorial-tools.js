import {remainingSeconds,startTimer,pauseTimer,clockDigits,localDay} from './editorial-tools-model.js';
const $=id=>document.getElementById(id),key='troddr-editorial-desk-v1';
let saved={};try{saved=JSON.parse(localStorage.getItem(key)||'{}');}catch{}
let timer={mode:'focus',remaining:1500,running:false,deadline:null,...saved.timer};
let day=saved.day===localDay()?saved.day:localDay(),completed=saved.day===day?Number(saved.completed)||0:0,checks=saved.day===day?saved.checks||[]:[],goal=Number(saved.goal)||150,words=Number(saved.words)||0,lastCounts=new Map();
const store=()=>{try{localStorage.setItem(key,JSON.stringify({timer,day,completed,checks,goal,words,note:$('desk-scratchpad').value}));}catch{$('desk-storage-status').textContent='Browser storage is unavailable. Keep this tab open to retain your notes.';}};
$('desk-scratchpad').value=saved.note||'';$('desk-goal').value=goal;
let returnFocus=null;
function openTools(open){if(open)returnFocus=document.activeElement;$('desk-tools').hidden=!open;document.querySelectorAll('[data-desk-toggle]').forEach(b=>b.setAttribute('aria-expanded',String(open)));if(open)$('desk-close').focus();else if(returnFocus?.isConnected)returnFocus.focus();}
document.querySelectorAll('[data-desk-toggle]').forEach(b=>b.onclick=()=>openTools($('desk-tools').hidden));$('desk-close').onclick=()=>openTools(false);document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('desk-tools').hidden)openTools(false);});
function draw(){
 const remaining=remainingSeconds(timer),digits=clockDigits(remaining);$('desk-clock').setAttribute('aria-label',`${Math.floor(remaining/60)} minutes ${remaining%60} seconds remaining`);
 [...$('desk-clock').querySelectorAll('.flip-digit')].forEach((card,i)=>{if(card.textContent!==digits[i]){card.textContent=digits[i];if(!matchMedia('(prefers-reduced-motion: reduce)').matches)card.animate([{transform:'rotateX(-35deg)',opacity:.5},{transform:'rotateX(0)',opacity:1}],{duration:230,easing:'ease-out'});}});
 $('desk-start').textContent=timer.running?'Pause':remaining===0?'Start again':'Start session';$('desk-timer-state').textContent=timer.running?(timer.mode==='focus'?'One thing at a time. You’re on the clock.':'Step away. Let the next idea find you.'):'Settle in. Give one small thing your attention.';
 document.querySelectorAll('[data-desk-mode]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.deskMode===timer.mode)));
 $('desk-mini').hidden=!timer.running;$('desk-mini').textContent=`${timer.mode==='focus'?'Focus':'Break'} ${digits.slice(0,2)}:${digits.slice(2)} · Open desk`;
 $('desk-session-count').textContent=`${completed} ${completed===1?'focus session':'focus sessions'} today`;
 $('desk-word-progress').textContent=`${words} / ${goal} new words`;$('desk-word-bar').value=Math.min(words,goal);$('desk-word-bar').max=goal;
 $('desk-goal-message').textContent=words>=goal?'You made room for the words. Keep going, or call that a good session.':'A rough first pass counts. You can make it beautiful on the next pass.';
 $('desk-daily-progress').textContent=`${checks.length} of 3 small wins`;
 document.querySelectorAll('[data-desk-check]').forEach(input=>{input.checked=checks.includes(input.dataset.deskCheck);});
}
$('desk-start').onclick=()=>{$('desk-completion').textContent='';if(timer.running)timer=pauseTimer(timer);else{if(!timer.remaining){timer.remaining=timer.mode==='focus'?1500:300;}timer=startTimer(timer);}store();draw();};
$('desk-reset').onclick=()=>{timer={mode:timer.mode,remaining:timer.mode==='focus'?1500:300,running:false,deadline:null};words=0;store();draw();$('desk-completion').textContent='Timer and session word count reset.';};
document.querySelectorAll('[data-desk-mode]').forEach(b=>b.onclick=()=>{timer={mode:b.dataset.deskMode,remaining:b.dataset.deskMode==='focus'?1500:300,running:false,deadline:null};store();draw();});
$('desk-goal').onchange=()=>{goal=Math.max(25,Math.min(3000,Number($('desk-goal').value)||150));$('desk-goal').value=goal;store();draw();};$('desk-scratchpad').oninput=store;
document.querySelectorAll('[data-desk-check]').forEach(input=>input.onchange=()=>{checks=[...document.querySelectorAll('[data-desk-check]:checked')].map(i=>i.dataset.deskCheck);store();draw();});
$('desk-mini').onclick=()=>openTools(true);$('keep-going-focus').onclick=()=>{openTools(true);};
window.addEventListener('troddr:wordcount',event=>{const {id,count}=event.detail;const previous=lastCounts.get(id);lastCounts.set(id,count);if(timer.running&&timer.mode==='focus'&&previous!==undefined){words=Math.max(0,words+count-previous);store();draw();}});
setInterval(()=>{if(day!==localDay()){day=localDay();completed=0;checks=[];store();draw();}if(timer.running&&remainingSeconds(timer)===0){timer={...timer,running:false,remaining:0,deadline:null};if(timer.mode==='focus')completed++;$('desk-completion').textContent=timer.mode==='focus'?'Session complete. That’s another piece of Troddr moved forward. Take a break.':'Break complete. Ready for one more small thing?';store();}draw();},1000);
draw();
