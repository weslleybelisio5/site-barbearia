// Comunicação com o Supabase usando apenas fetch (sem bibliotecas externas = site mais leve e rápido).
import { CONFIG } from './config.js';

const SKEY = 'bdc_session';
const loadSession = () => { try { return JSON.parse(localStorage.getItem(SKEY)); } catch { return null; } };
const saveSession = (s) => { try { s ? localStorage.setItem(SKEY, JSON.stringify(s)) : localStorage.removeItem(SKEY); } catch {} };

function friendly(msg, status) {
  const m = String(msg || '');
  if (/Invalid login credentials/i.test(m)) return 'E-mail ou senha incorretos.';
  if (/already registered|already been registered/i.test(m)) return 'Este e-mail já está cadastrado. Tente entrar.';
  if (/Password should be at least/i.test(m)) return 'A senha precisa ter pelo menos 6 caracteres.';
  if (/rate limit|too many/i.test(m)) return 'Muitas tentativas. Aguarde alguns minutos e tente de novo.';
  if (/Email not confirmed/i.test(m)) return 'Seu e-mail ainda não foi confirmado.';
  if (/JWT expired|invalid JWT/i.test(m)) return 'Sua sessão expirou. Entre novamente.';
  if (status === 401 || status === 403) return 'Você não tem permissão para isso.';
  if (status >= 500) return 'O sistema está instável no momento. Tente novamente em instantes.';
  // mensagens escritas por nós no banco já vêm em português claro
  return m || 'Não foi possível concluir. Tente novamente.';
}

async function refreshIfNeeded() {
  const s = loadSession();
  if (!s) return null;
  if (s.expires_at && s.expires_at - 60 > Math.floor(Date.now() / 1000)) return s;
  try {
    const r = await raw('/auth/v1/token?grant_type=refresh_token', { method: 'POST', body: { refresh_token: s.refresh_token }, anon: true });
    const ns = toSession(r);
    saveSession(ns);
    return ns;
  } catch { saveSession(null); return null; }
}

function toSession(r) {
  return { access_token: r.access_token, refresh_token: r.refresh_token,
           expires_at: r.expires_at || (Math.floor(Date.now() / 1000) + (r.expires_in || 3600)), user: r.user };
}

async function raw(path, { method = 'GET', body, token, anon, headers = {} } = {}) {
  let res;
  try {
    res = await fetch(CONFIG.SUPABASE_URL + path, {
      method,
      headers: { apikey: CONFIG.SUPABASE_KEY, 'Content-Type': 'application/json',
                 Authorization: 'Bearer ' + (anon ? CONFIG.SUPABASE_KEY : (token || CONFIG.SUPABASE_KEY)), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new Error('Sem conexão com a internet. Este site precisa de internet para funcionar.');
  }
  let data = null;
  const text = await res.text();
  if (text) { try { data = JSON.parse(text); } catch { data = text; } }
  if (!res.ok) {
    const msg = data && (data.message || data.msg || data.error_description || data.error);
    const err = new Error(friendly(msg, res.status));
    err.status = res.status; err.code = data && data.code;
    throw err;
  }
  return data;
}

async function authed(path, opts = {}) {
  const s = await refreshIfNeeded();
  return raw(path, { ...opts, token: s && s.access_token });
}

export const api = {
  session: () => loadSession(),
  // chama uma função do banco (regras de negócio ficam no servidor)
  rpc: (name, args = {}) => authed('/rest/v1/rpc/' + name, { method: 'POST', body: args }),
  // lê uma tabela. Exemplo: api.select('services', 'select=*&is_active=eq.true')
  select: (table, query = '') => authed('/rest/v1/' + table + (query ? '?' + query : '')),
  insert: (table, rows) => authed('/rest/v1/' + table, { method: 'POST', body: rows, headers: { Prefer: 'return=representation' } }),
  update: (table, query, patch) => authed('/rest/v1/' + table + '?' + query, { method: 'PATCH', body: patch, headers: { Prefer: 'return=representation' } }),
  remove: (table, query) => authed('/rest/v1/' + table + '?' + query, { method: 'DELETE' }),
  auth: {
    async signUp(email, password, meta) {
      const r = await raw('/auth/v1/signup', { method: 'POST', anon: true, body: { email, password, data: meta } });
      if (r && r.access_token) { saveSession(toSession(r)); return { loggedIn: true }; }
      return { loggedIn: false, needsConfirm: true };
    },
    async signIn(email, password) {
      const r = await raw('/auth/v1/token?grant_type=password', { method: 'POST', anon: true, body: { email, password } });
      saveSession(toSession(r));
      return r.user;
    },
    async signOut() {
      try { const s = loadSession(); if (s) await raw('/auth/v1/logout', { method: 'POST', token: s.access_token }); } catch {}
      saveSession(null);
    },
    recover: (email, redirectTo) => raw('/auth/v1/recover' + (redirectTo ? '?redirect_to=' + encodeURIComponent(redirectTo) : ''), { method: 'POST', anon: true, body: { email } }),
    updatePassword: (password, token) => raw('/auth/v1/user', { method: 'PUT', token: token || (loadSession() || {}).access_token, body: { password } }),
    setSessionFromHash(hash) { // volta do e-mail de recuperação de senha
      const p = new URLSearchParams(hash.replace(/^#/, ''));
      if (!p.get('access_token')) return null;
      const s = { access_token: p.get('access_token'), refresh_token: p.get('refresh_token'),
                  expires_at: Math.floor(Date.now() / 1000) + Number(p.get('expires_in') || 3600), user: null };
      saveSession(s); return s;
    },
  },
};

// Perfil + papel do usuário logado (admin ou cliente) — validado no servidor pelas políticas RLS
export async function currentProfile() {
  const s = loadSession();
  if (!s) return null;
  try {
    // O ID do usuário já vem salvo na sessão. Evita uma chamada extra ao Auth
    // antes de consultar o perfil, acelerando a abertura do painel.
    let userId = s.user && s.user.id;
    if (!userId) {
      const u = await authed('/auth/v1/user');
      userId = u && u.id;
    }
    if (!userId) return null;
    const rows = await api.select('profiles', 'select=id,role&id=eq.' + encodeURIComponent(userId));
    return rows[0] || null;
  } catch { return null; }
}
