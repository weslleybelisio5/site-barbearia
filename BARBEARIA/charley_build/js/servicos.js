import { $, esc, mountChrome, registerSW } from './common.js';
import { loadServices, serviceCard } from './services.js';
registerSW();
await mountChrome('servicos.html');
try {
  const list = await loadServices();
  $('#svc-list').innerHTML = list.length ? list.map(serviceCard).join('') : '<p class="empty">Serviços em breve.</p>';
  if (list.some((x) => x.is_variable_price)) $('#svc-note').hidden = false;
} catch (e) { $('#svc-list').innerHTML = `<p class="err">${esc(e.message)}</p>`; }
