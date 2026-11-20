const toggle=document.getElementById('menu-toggle');
const nav=document.getElementById('navlinks');
if(toggle&&nav){toggle.addEventListener('click',()=>{const open=nav.classList.toggle('open');toggle.setAttribute('aria-expanded',String(open));toggle.textContent=open?'✕':'☰'});nav.querySelectorAll('a').forEach(a=>a.addEventListener('click',()=>{nav.classList.remove('open');toggle.setAttribute('aria-expanded','false');toggle.textContent='☰'}));}
const year=document.getElementById('year');if(year)year.textContent=new Date().getFullYear();
const form=document.getElementById('contact-form');
if(form){
  const requested=new URLSearchParams(location.search).get('service');
  if(requested){const service=form.querySelector('[name="service"]');const selected=[...service.options].find(o=>o.textContent.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/-$/,'')===requested);if(selected)service.value=selected.value;}
  form.addEventListener('submit',async e=>{
    e.preventDefault();if(!form.reportValidity())return;
    const button=form.querySelector('[type="submit"]'),note=document.getElementById('form-note');
    button.disabled=true;button.textContent='Sending your inquiry…';note.classList.remove('form-success','form-error');note.textContent='Sending your inquiry…';
    try{
      const payload=Object.fromEntries(new FormData(form).entries());
      const response=await fetch('/api/contact',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
      let result;try{result=await response.json();}catch{throw new Error('Unexpected server response. Please try again later.');}
      if(!response.ok||!result.ok)throw new Error(result.error||'Your inquiry could not be sent.');
      form.reset();note.classList.add('form-success');note.textContent='Thank you! Your inquiry was accepted for email delivery. We will review it and respond by email.';
    }catch(err){note.classList.add('form-error');note.textContent=err.message||'Unable to send inquiry. Please try again later.';}
    finally{button.disabled=false;button.textContent='Send Project Inquiry →';}
  });
}
