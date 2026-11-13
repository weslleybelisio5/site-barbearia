import { $, esc, mountChrome, registerSW } from './common.js';
import { api } from './api.js';
registerSW();
await mountChrome('faq.html');
try {
  const rows = await api.select('faq_items','select=question,answer&is_active=eq.true&order=sort_order');
  if (rows.length) {
    const box = document.createElement('section'); box.className='block';
    box.innerHTML = `<div class="wrap" style="max-width:760px"><h2>Mais dúvidas</h2>${rows.map(r=>`<details><summary>${esc(r.question)}</summary><p>${esc(r.answer)}</p></details>`).join('')}</div>`;
    document.querySelector('main').append(box);
  }
} catch {}
