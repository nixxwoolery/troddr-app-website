export const PHOTO_PRESETS={
  original:{label:'Original proportions',width:1600,height:0},
  app:{label:'App · landscape',width:1600,height:1000},
  square:{label:'Square · 1:1',width:1080,height:1080},
  portrait:{label:'Portrait · 4:5',width:1080,height:1350},
  tall:{label:'Tall portrait · 3:4',width:1080,height:1440},
  story:{label:'Story / reel cover · 9:16',width:1080,height:1920}
};
export function defaultPhotoRecipe(){return {preset:'original',zoom:1,panX:0,panY:0,rotation:0,flip:false,exposure:0,contrast:0,highlights:0,shadows:0,warmth:0,saturation:0,dehaze:0,sharpen:0,texts:[]};}
export function outputSize(recipe,width,height){const preset=PHOTO_PRESETS[recipe.preset]||PHOTO_PRESETS.original;const rotated=Math.abs(recipe.rotation%180)===90;const w=rotated?height:width,h=rotated?width:height;if(!preset.height){const scale=Math.min(1,1600/w,2400/h);return {width:Math.max(1,Math.round(w*scale)),height:Math.max(1,Math.round(h*scale))};}return {width:preset.width,height:preset.height};}
export function cropRect(width,height,ratio,zoom=1,panX=0,panY=0){
  zoom=Math.max(1,Math.min(4,Number(zoom)||1));let w=width,h=height;
  if(w/h>ratio)w=h*ratio;else h=w/ratio;
  w/=zoom;h/=zoom;
  return {x:(width-w)*(1+Math.max(-1,Math.min(1,panX)))/2,y:(height-h)*(1+Math.max(-1,Math.min(1,panY)))/2,width:w,height:h};
}
// Dark-channel atmospheric correction. Positive values remove haze; negative values add it.
// Estimate airlight from the brightest pixels; neutral edits remain byte-identical.
export function adjustPixels(data,recipe){
  const haze=Math.max(-100,Math.min(100,Number(recipe.dehaze)||0))/100;
  let air=[1,1,1];
  if(haze>0){
    const bins=Array.from({length:256},()=>({n:0,r:0,g:0,b:0}));
    for(let i=0;i<data.length;i+=4){if(!data[i+3])continue;const bin=bins[Math.round(.2126*data[i]+.7152*data[i+1]+.0722*data[i+2])];bin.n++;bin.r+=data[i];bin.g+=data[i+1];bin.b+=data[i+2];}
    let n=0,r=0,g=0,b=0;const target=Math.max(1,data.length/4*.01);
    for(let j=255;j>=0&&n<target;j--){const bin=bins[j];n+=bin.n;r+=bin.r;g+=bin.g;b+=bin.b;}
    if(n)air=[r,g,b].map(v=>Math.max(.25,v/n/255));
  }
  const exposure=2**recipe.exposure,contrast=1+recipe.contrast/100,saturation=1+recipe.saturation/100,warm=recipe.warmth/100;
  for(let i=0;i<data.length;i+=4){
    let r=data[i]/255,g=data[i+1]/255,b=data[i+2]/255;
    if(haze>0){const dark=Math.min(r/air[0],g/air[1],b/air[2]);const transmission=Math.max(.25,1-.85*haze*Math.min(1,dark));r=(r-air[0])/transmission+air[0];g=(g-air[1])/transmission+air[1];b=(b-air[2])/transmission+air[2];}
    else if(haze<0){const veil=-haze*.5;r=r*(1-veil)+veil;g=g*(1-veil)+veil;b=b*(1-veil)+veil;}
    const l=.2126*r+.7152*g+.0722*b;
    const lift=recipe.shadows/100*(1-l)**2*.45+recipe.highlights/100*l*l*.45;
    r=((r*exposure+lift-.5)*contrast+.5)*(1+warm*.25);g=((g*exposure+lift-.5)*contrast+.5);b=((b*exposure+lift-.5)*contrast+.5)*(1-warm*.25);
    const grey=.2126*r+.7152*g+.0722*b;
    data[i]=Math.round(Math.max(0,Math.min(1,grey+(r-grey)*saturation))*255);
    data[i+1]=Math.round(Math.max(0,Math.min(1,grey+(g-grey)*saturation))*255);
    data[i+2]=Math.round(Math.max(0,Math.min(1,grey+(b-grey)*saturation))*255);
  }
  return data;
}
export function sharpenPixels(data,width,height,amount){
  if(amount<=0)return data;const source=new Uint8ClampedArray(data),strength=amount/100;
  for(let y=1;y<height-1;y++)for(let x=1;x<width-1;x++){const i=(y*width+x)*4;for(let c=0;c<3;c++){const average=(source[i-4+c]+source[i+4+c]+source[i-width*4+c]+source[i+width*4+c])/4;data[i+c]=Math.max(0,Math.min(255,source[i+c]+(source[i+c]-average)*strength));}}
  return data;
}
export function openingStats(text,limit=125){
  const value=String(text||'').trim();const points=Array.from(value);limit=Math.max(40,Math.min(500,Number(limit)||125));
  const visible=points.slice(0,limit).join(''),rest=points.slice(limit).join('');
  const sentence=Array.from(value.match(/^.*?[.!?](?=\s|$)/s)?.[0]||'').length;
  return {words:value?value.split(/\s+/u).length:0,characters:points.length,visible,rest,limit,firstSentenceFits:sentence?sentence<=limit:null};
}
