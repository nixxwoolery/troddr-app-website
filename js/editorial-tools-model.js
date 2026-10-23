export function remainingSeconds(timer,now=Date.now()){return timer.running?Math.max(0,Math.ceil((timer.deadline-now)/1000)):Math.max(0,timer.remaining);}
export function startTimer(timer,now=Date.now()){return {...timer,running:true,deadline:now+timer.remaining*1000};}
export function pauseTimer(timer,now=Date.now()){return {...timer,running:false,remaining:remainingSeconds(timer,now),deadline:null};}
export function clockDigits(seconds){const value=Math.max(0,Math.floor(seconds));return `${String(Math.floor(value/60)).padStart(2,'0')}${String(value%60).padStart(2,'0')}`;}
export function localDay(now=new Date()){return `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`;}
