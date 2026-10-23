import test from 'node:test';
import assert from 'node:assert/strict';
import {remainingSeconds,startTimer,pauseTimer,clockDigits,localDay} from '../js/editorial-tools-model.js';
test('focus clock uses a deadline, stays accurate when tab sleeps, and resumes after pause',()=>{
 const timer=startTimer({remaining:1500,running:false},1000);assert.equal(remainingSeconds(timer,61000),1440);
 const paused=pauseTimer(timer,61500);assert.equal(paused.remaining,1440);assert.equal(remainingSeconds(paused,999999),1440);
 const resumed=startTimer(paused,100000);assert.equal(remainingSeconds(resumed,101000),1439);assert.equal(remainingSeconds(resumed,99999999),0);
});
test('flip digits and daily checklist key use predictable local values',()=>{assert.equal(clockDigits(1500),'2500');assert.equal(clockDigits(59),'0059');assert.equal(clockDigits(0),'0000');assert.equal(localDay(new Date(2026,9,22,23,59)),'2026-10-22');});
