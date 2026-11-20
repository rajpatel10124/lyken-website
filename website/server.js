'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { URL } = require('node:url');
const { randomUUID } = require('node:crypto');
const ROOT = __dirname;
const MAX_BODY = 16 * 1024;
const MIME = {'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.svg':'image/svg+xml','.txt':'text/plain; charset=utf-8','.ico':'image/x-icon'};
const allowed = new Set(['index.html','about.html','services.html','work.html','insights.html','faq.html','contact.html','privacy.html','styles.css','script.js','favicon.svg','robots.txt']);
const services = new Set(['Custom Software Development','DevOps & Automation','Cloud & Infrastructure','Web & Business Solutions','AI & Automation','Maintenance & Support','Not sure yet']);
const budgets = new Set(['','Under ₹25,000','₹25,000–₹75,000','₹75,000–₹2,00,000','₹2,00,000+']);
const attempts = new Map();
function json(res,status,payload){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(JSON.stringify(payload));}
function rateLimit(ip, now=Date.now()){
  if(attempts.size>2000){for(const [key,value] of attempts){if(now-value.start>3600000)attempts.delete(key);}}
  let a=attempts.get(ip);if(!a||now-a.start>3600000){a={start:now,count:0};attempts.set(ip,a);}a.count++;return a.count>8;
}
function validate(p){
  if(!p||typeof p!=='object'||Array.isArray(p))return 'Invalid request.';
  for(const k of ['name','email','company','service','budget','message','website']) if(p[k]!==undefined&&typeof p[k]!=='string')return 'Invalid form fields.';
  const name=(p.name||'').trim(),email=(p.email||'').trim(),company=(p.company||'').trim(),message=(p.message||'').trim();
  if(name.length<2||name.length>100)return 'Please enter a name between 2 and 100 characters.';
  if(email.length>160||!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(email))return 'Please enter a valid email address.';
  if(company.length>120)return 'Company name is too long.';
  if(!services.has(p.service))return 'Please select a valid service.';
  if(!budgets.has(p.budget||''))return 'Please select a valid budget.';
  if(message.length<10||message.length>3000)return 'Please enter project details (10–3000 characters).';
  return null;
}
async function sendEmail(p, fetcher=fetch){
  const key=process.env.BREVO_API_KEY, sender=process.env.BREVO_SENDER_EMAIL;
  if(!key||!sender)throw Object.assign(new Error('Email provider is not configured.'),{code:'NOT_CONFIGURED'});
  const clean=s=>String(s||'').replace(/[\u0000-\u001f\u007f]/g,' ').trim();
  const text=`New project inquiry — Lyken Solutions and Services\n\nName: ${clean(p.name)}\nEmail: ${clean(p.email)}\nCompany: ${clean(p.company)||'Not provided'}\nService: ${clean(p.service)}\nBudget: ${clean(p.budget)||'Not specified'}\n\nProject details:\n${p.message.trim()}\n`;
  const response=await fetcher('https://api.brevo.com/v3/smtp/email',{
    method:'POST',headers:{'api-key':key,'Content-Type':'application/json','Accept':'application/json'},
    body:JSON.stringify({sender:{name:'Lyken Website',email:sender},to:[{email:'rajptl244@gmail.com',name:'Raj Patel'}],replyTo:{email:p.email.trim(),name:p.name.trim()},subject:`New Lyken inquiry: ${clean(p.service).slice(0,75)}`,textContent:text}),signal:AbortSignal.timeout(12000)
  });
  if(!response.ok){const details=(await response.text()).slice(0,300);console.error('Email provider rejected request',response.status,details);throw new Error('Email provider rejected request');}
  return response.json().catch(()=>({accepted:true}));
}
function createServer({send=sendEmail}={}){
return http.createServer(async(req,res)=>{
  res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','strict-origin-when-cross-origin');res.setHeader('X-Frame-Options','DENY');
  const pathname=new URL(req.url,'http://localhost').pathname;
  if(pathname==='/api/health'&&req.method==='GET')return json(res,200,{ok:true,emailConfigured:Boolean(process.env.BREVO_API_KEY&&process.env.BREVO_SENDER_EMAIL)});
  if(pathname==='/api/contact'){
    if(req.method!=='POST'){res.setHeader('Allow','POST');return json(res,405,{ok:false,error:'Method not allowed.'});}
    const type=req.headers['content-type']||'';if(!type.startsWith('application/json'))return json(res,415,{ok:false,error:'Expected JSON.'});
    const origin=req.headers.origin;const host=req.headers.host;
    if(origin){try{if(new URL(origin).host!==host)return json(res,403,{ok:false,error:'Invalid origin.'});}catch{return json(res,403,{ok:false,error:'Invalid origin.'});}}
    if(rateLimit(req.socket.remoteAddress||'unknown'))return json(res,429,{ok:false,error:'Too many requests. Please try again later.'});
    let size=0,parts=[];
    try{for await(const chunk of req){size+=chunk.length;if(size>MAX_BODY)return json(res,413,{ok:false,error:'Request is too large.'});parts.push(chunk);}}
    catch{return json(res,400,{ok:false,error:'Could not read request.'});}
    let p;try{p=JSON.parse(Buffer.concat(parts).toString('utf8'));}catch{return json(res,400,{ok:false,error:'Invalid JSON.'});}
    if(p&&typeof p.website==='string'&&p.website.trim())return json(res,200,{ok:true,message:'Inquiry received.'});
    const problem=validate(p);if(problem)return json(res,422,{ok:false,error:problem});
    if(!process.env.BREVO_API_KEY||!process.env.BREVO_SENDER_EMAIL)return json(res,503,{ok:false,error:'Email service is not configured yet. Please contact us by email.'});
    try{await send(p);const id=randomUUID();console.log('Inquiry accepted by email provider',id);return json(res,200,{ok:true,message:'Your inquiry was accepted for email delivery. Thank you!'});}
    catch(err){console.error('Inquiry delivery failed:',err.message);return json(res,502,{ok:false,error:'We could not deliver your inquiry. Please try again later or contact us directly.'});}
  }
  if(req.method!=='GET'&&req.method!=='HEAD'){res.writeHead(405);return res.end();}
  const filename=pathname==='/'?'index.html':decodeURIComponent(pathname).replace(/^\//,'');
  if(!allowed.has(filename)){res.writeHead(404,{'Content-Type':'text/plain'});return res.end('Not found');}
  const file=path.join(ROOT,filename);
  fs.readFile(file,(err,body)=>{if(err){res.writeHead(404);return res.end('Not found');}res.writeHead(200,{'Content-Type':MIME[path.extname(file)]||'application/octet-stream','Cache-Control':filename.endsWith('.html')?'no-cache':'public, max-age=3600'});res.end(req.method==='HEAD'?undefined:body);});
});}
if(require.main===module){const port=Number(process.env.PORT||3000);createServer().listen(port,'0.0.0.0',()=>console.log(`Lyken running at http://localhost:${port}`));}
module.exports={createServer,validate,sendEmail};
