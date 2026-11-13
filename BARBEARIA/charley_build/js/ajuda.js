import { mountChrome, registerSW } from './common.js';
registerSW(); await mountChrome('ajuda.html');
const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
if (!reduce && 'IntersectionObserver' in window) {
  const io = new IntersectionObserver((entries) => entries.forEach((entry) => { if (entry.isIntersecting) { entry.target.classList.add('is-visible'); io.unobserve(entry.target); } }), { threshold: .12 });
  document.querySelectorAll('.help-card,.step,.tutorial-visual,.help-bottom').forEach((el) => { el.classList.add('reveal'); io.observe(el); });
}
document.querySelectorAll('[data-tutorial]').forEach((el) => el.addEventListener('click', (event) => { const target = document.getElementById(`tutorial-${el.dataset.tutorial}`); if (target) { event.preventDefault(); target.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' }); } }));
