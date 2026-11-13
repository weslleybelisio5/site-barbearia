import { api } from './api.js';
import { brl, esc, durText } from './common.js';
export const loadServices = () => api.select('services', 'select=*&is_active=eq.true&order=sort_order');
export const priceLabel = (s) => (s.is_variable_price ? 'A partir de ' : '') + brl(s.price);
export const serviceCard = (s) => `<article class="card svc"><div><h3>${esc(s.name)}</h3><p>${esc(s.description || '')}${s.description ? ' · ' : ''}${durText(s.duration_min)}${s.includes_cut ? ' · já inclui o corte' : ''}</p></div><div class="price">${priceLabel(s)}</div></article>`;
