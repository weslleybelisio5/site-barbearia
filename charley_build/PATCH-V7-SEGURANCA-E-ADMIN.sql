-- PATCH V7 — Barbearia do Charley
-- Hardening do Supabase + correções de cadastro, RPCs e catálogo público.
-- Compatível com o banco atual em PostgreSQL 17.
-- O PATCH V6 e os scripts-base não devem ser reexecutados.
-- Esta versão já foi aplicada e verificada no projeto ativo em 13/11/2026.
-- Arquivo mantido no repositório para auditoria e recuperação; não executar às cegas
-- em outro projeto sem comparar o schema e fazer backup primeiro.

begin;

-- 1. Perfis: todo novo usuário Auth recebe perfil na tabela usada pela versão atual.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_name text;
begin
  v_name := nullif(btrim(coalesce(
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    split_part(coalesce(new.email, ''), '@', 1)
  )), '');

  insert into public.profiles (id, full_name, email, role)
  values (new.id, coalesce(v_name, 'Novo cliente'), new.email, 'client')
  on conflict (id) do update
    set full_name = coalesce(nullif(public.profiles.full_name, ''), excluded.full_name),
        email = coalesce(excluded.email, public.profiles.email),
        updated_at = pg_catalog.now();

  return new;
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

alter function public._today() set search_path = pg_catalog;
alter function public.criar_reserva_segura(uuid, uuid, timestamptz, interval)
  set search_path = pg_catalog, public;
alter function public.realizar_venda_produto(uuid, uuid, uuid, integer, text)
  set search_path = pg_catalog, public;
alter function public.processar_fila_espera()
  set search_path = pg_catalog, public;

-- 2. Remove EXECUTE público de funções SECURITY DEFINER e libera apenas RPCs necessárias.
do $$
declare fn record;
begin
  for fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    execute format(
      'revoke execute on function %s from public, anon, authenticated',
      fn.signature
    );
  end loop;
end;
$$;

-- Fluxos públicos/guest necessários para agendamento e consulta segura por token.
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.get_available_slots(date, integer, uuid, uuid) to anon, authenticated;
grant execute on function public.create_appointment(uuid[], timestamptz, text, text, uuid, text) to anon, authenticated;
grant execute on function public.get_guest_appointment(uuid) to anon, authenticated;
grant execute on function public.cancel_appointment(uuid, uuid) to anon, authenticated;
grant execute on function public.reschedule_appointment(uuid, timestamptz, uuid) to anon, authenticated;

-- Área do cliente: cada função valida o usuário/dono do registro no próprio banco.
grant execute on function public.claim_appointment(uuid) to authenticated;
grant execute on function public.join_waitlist(uuid[], date, time, time) to authenticated;
grant execute on function public.cancel_waitlist(uuid) to authenticated;
grant execute on function public.accept_waitlist_offer(uuid) to authenticated;
grant execute on function public.decline_waitlist_offer(uuid) to authenticated;
grant execute on function public.request_subscription(uuid) to authenticated;
grant execute on function public.request_cancel_subscription(uuid) to authenticated;
grant execute on function public.my_subscription() to authenticated;
grant execute on function public.submit_privacy_request(text, text) to authenticated;
grant execute on function public.submit_review(uuid, integer, text) to authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;
grant execute on function public.mark_notification_read(uuid) to authenticated;

-- RPCs administrativos. As funções admin_* validam o papel no corpo via _require_admin()
-- ou is_admin(); admin_alerts permanece reservado ao agendador de banco.
do $$
declare fn record;
begin
  for fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and p.proname like 'admin\_%' escape '\'
      and p.proname <> 'admin_alerts'
  loop
    execute format('grant execute on function %s to authenticated', fn.signature);
  end loop;
end;
$$;

grant execute on function public.complete_appointment(uuid, jsonb, text, numeric, text, boolean, text, text)
  to authenticated;
grant execute on function public.cash_summary(uuid) to authenticated;
grant execute on function public.cash_open(numeric) to authenticated;
grant execute on function public.cash_add_movement(text, numeric, text, text) to authenticated;
grant execute on function public.cash_close(numeric, text) to authenticated;
grant execute on function public.stock_move(uuid, text, integer, text) to authenticated;
grant execute on function public.report_summary(date, date) to authenticated;
grant execute on function public.report_series(date, date, text) to authenticated;
grant execute on function public.demo_counts() to authenticated;
grant execute on function public.demo_seed() to authenticated;
grant execute on function public.demo_clear(text) to authenticated;

-- Legacy Portuguese RPCs are no longer used by the current frontend.
revoke execute on function public.criar_reserva_segura(uuid, uuid, timestamptz, interval)
  from public, anon, authenticated;
revoke execute on function public.realizar_venda_produto(uuid, uuid, uuid, integer, text)
  from public, anon, authenticated;
revoke execute on function public.processar_fila_espera()
  from public, anon, authenticated;
revoke execute on function public.setting_int(text, integer) from public, anon, authenticated;
revoke execute on function public.setting_text(text, text) from public, anon, authenticated;
revoke execute on function public.ensure_customer(text, text, uuid) from public, anon, authenticated;

-- 3. Catálogo público: somente colunas seguras; custo, dono de avaliação e quantidade exata não saem.
alter table public.products
  add column if not exists public_in_stock boolean
  generated always as (quantity > 0) stored;

revoke select on table public.products, public.kits, public.kit_items,
  public.product_categories, public.reviews from public, anon, authenticated;

grant select (id, name, description, photo_url, price, category_id,
  is_active, is_demo, public_in_stock) on public.products to anon;
grant select on public.products to authenticated;

grant select (id, name, description, photo_url, price, is_active)
  on public.kits to anon;
grant select on public.kits to authenticated;

grant select (kit_id, product_id, quantity) on public.kit_items to anon;
grant select on public.kit_items to authenticated;

grant select (id, name) on public.product_categories to anon;
grant select on public.product_categories to authenticated;

grant select (id, display_name, rating, comment, created_at, status)
  on public.reviews to anon;
grant select on public.reviews to authenticated;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='products' and policyname='products_public_read') then
    create policy products_public_read on public.products
      for select to anon, authenticated using (is_active and not is_demo);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='kits' and policyname='kits_public_read') then
    create policy kits_public_read on public.kits
      for select to anon, authenticated using (is_active);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='kit_items' and policyname='kit_items_public_read') then
    create policy kit_items_public_read on public.kit_items
      for select to anon, authenticated using (
        exists (select 1 from public.kits k where k.id = kit_items.kit_id and k.is_active)
      );
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='product_categories' and policyname='product_categories_public_read') then
    create policy product_categories_public_read on public.product_categories
      for select to anon, authenticated using (
        exists (select 1 from public.products p
          where p.category_id = product_categories.id and p.is_active and not p.is_demo)
      );
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='reviews' and policyname='reviews_public_read') then
    create policy reviews_public_read on public.reviews
      for select to anon, authenticated using (status = 'approved');
  end if;
end;
$$;

create or replace view public.public_products
with (security_invoker = true)
as
select p.id, p.name, p.description, p.photo_url, p.price,
       pc.name as category, p.public_in_stock as in_stock
from public.products p
left join public.product_categories pc on pc.id = p.category_id
where p.is_active and not p.is_demo;

alter view public.public_kits set (security_invoker = true);
alter view public.public_reviews set (security_invoker = true);

-- 4. Índices para agenda, caixa, relatórios e relacionamentos acessados com frequência.
create index if not exists idx_appt_barber_start
  on public.appointments (barber_id, start_at);
create index if not exists idx_blocks_barber_start
  on public.availability_blocks (barber_id, start_at);
create index if not exists idx_cash_movements_session_created
  on public.cash_movements (session_id, created_at desc);
create index if not exists idx_payments_cash_session
  on public.payments (cash_session_id);
create index if not exists idx_payments_customer_paid
  on public.payments (customer_id, paid_at desc);
create index if not exists idx_sale_items_sale
  on public.sale_items (sale_id);
create index if not exists idx_campaign_recipients_customer
  on public.campaign_recipients (customer_id);
create index if not exists idx_reviews_profile
  on public.reviews (profile_id);
create index if not exists idx_waitlist_client_created
  on public.waitlist (client_id, created_at desc);

commit;
