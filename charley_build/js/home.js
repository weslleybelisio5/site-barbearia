import { $, esc, mountChrome, registerSW, getSettings, getHours, hoursSummary } from './common.js';
import { loadServices, serviceCard } from './services.js';
import { api } from './api.js';

registerSW();
await mountChrome('index.html');
const s = await getSettings();

try {
  const list = await loadServices();
  $('#svc-list').innerHTML = list.length ? list.map(serviceCard).join('') : '<p class="empty">Serviços em breve.</p>';
  if (list.some((x) => x.is_variable_price)) $('#svc-note').hidden = false;
} catch (e) { $('#svc-list').innerHTML = `<p class="err">${esc(e.message)}</p>`; }

const h = hoursSummary(await getHours(), s);
$('#hours').innerHTML = h.lines.length
  ? `<table class="t"><tbody>${h.lines.map((l) => `<tr><th scope="row">${esc(l.days)}</th><td>${esc(l.label)}</td></tr>`).join('')}</tbody></table><p class="hint">${esc(h.lunch)}</p>`
  : '<p class="muted">Horários indisponíveis no momento.</p>';
$('#addr').textContent = s.shop_address;
$('#map').src = 'https://www.google.com/maps?q=' + encodeURIComponent(s.shop_address) + '&output=embed';
$('#route').href = 'https://www.google.com/maps/dir/?api=1&destination=' + encodeURIComponent(s.shop_address);

// Conteúdo administrável publicado no painel
try {
  const news = await api.select('announcements', 'select=id,title,body,image_url,published_at&status=eq.published&order=published_at.desc&limit=3');
  if (news.length) { $('#novidades').hidden = false; $('#news-list').innerHTML = news.map(n => `<article class="card">${n.image_url ? `<img src="${esc(n.image_url)}" alt="" loading="lazy" style="width:100%;border-radius:10px">` : ''}<h3>${esc(n.title)}</h3><p>${esc(n.body)}</p></article>`).join(''); }
} catch {}
try {
  const gallery = await api.select('gallery_items', 'select=id,title,description,image_url&is_visible=eq.true&is_demo=eq.false&order=is_featured.desc,published_at.desc&limit=6');
  if (gallery.length) { $('#galeria').hidden = false; $('#gallery-list').innerHTML = gallery.map(g => `<article class="card"><img src="${esc(g.image_url)}" alt="${esc(g.title)}" loading="lazy" style="width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:10px"><h3>${esc(g.title)}</h3>${g.description ? `<p>${esc(g.description)}</p>` : ''}</article>`).join(''); }
} catch {}


// Entrada suave dos blocos ao rolar a página e microinteração discreta no hero.
document.body.classList.add('home-motion');
const revealTargets = [...document.querySelectorAll('main .block .wrap')];
if ('IntersectionObserver' in window) {
  const revealObserver = new IntersectionObserver((entries, observer) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-inview');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -35px 0px' });
  revealTargets.forEach((el) => revealObserver.observe(el));
} else {
  revealTargets.forEach((el) => el.classList.add('is-inview'));
}
const hero = document.querySelector('.hero');
const heroObject = document.querySelector('.hero-object');
if (hero && heroObject && window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
  hero.addEventListener('pointermove', (event) => {
    const rect = hero.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width - 0.5;
    const y = (event.clientY - rect.top) / rect.height - 0.5;
    heroObject.style.transform = `translate3d(${x * 7}px, ${y * 6}px, 0) rotateY(${x * 3}deg) rotateX(${-y * 2}deg)`;
  });
  hero.addEventListener('pointerleave', () => { heroObject.style.transform = ''; });
}
