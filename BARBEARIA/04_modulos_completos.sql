-- ============================================================
-- BARBEARIA DO CHARLEY - SCRIPT 4: MODULOS COMPLETOS
-- Caixa, financeiro, estoque, vendas, cupons, assinaturas, lista de espera (fila + convite 15 min),
-- avaliacoes, galeria, novidades, FAQ, tarefas, campanhas, privacidade, relatorios e dados DEMO.
-- Rode DEPOIS dos scripts 1, 2 e 3. Pode ser rodado de novo sem estragar nada.
-- ============================================================

-- ---------- Ajustes em tabelas existentes ----------
alter table public.payments add column if not exists kind text not null default 'service';
alter table public.payments add column if not exists subscription_id uuid;
alter table public.payments add column if not exists sale_id uuid;
alter table public.payments add column if not exists cash_session_id uuid;
alter table public.appointment_items add column if not exists credit_used boolean not null default false;
alter table public.appointments add column if not exists discount_value numeric(10,2) not null default 0;
alter table public.appointments add column if not exists discount_reason text;
alter table public.appointments add column if not exists coupon_id uuid;

-- ---------- Ferramentas internas ----------
create table if not exists public.alert_log (
  kind text not null, ref text not null, created_at timestamptz not null default now(), primary key (kind, ref)
);
alter table public.alert_log enable row level security;

create or replace function public._alert_once(p_kind text, p_ref text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into public.alert_log (kind, ref) values (p_kind, p_ref);
  return true;
exception when unique_violation then return false;
end $$;

create or replace function public._notify_admins(p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, type, title, body, data)
  select id, p_type, p_title, p_body, p_data from public.profiles where role = 'admin' and is_active;
$$;

create or replace function public._today() returns date
language sql stable as $$ select (now() at time zone 'America/Recife')::date $$;

-- ============================================================
-- CAIXA
-- ============================================================
create table if not exists public.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  opened_by uuid, opened_at timestamptz not null default now(),
  opening_amount numeric(10,2) not null default 0 check (opening_amount >= 0),
  closed_by uuid, closed_at timestamptz,
  expected_cash numeric(10,2), counted_cash numeric(10,2), difference numeric(10,2),
  totals jsonb, note text,
  status text not null default 'open' check (status in ('open','closed')),
  is_demo boolean not null default false
);
create unique index if not exists one_open_cash on public.cash_sessions (status) where status = 'open';

create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.cash_sessions(id) on delete cascade,
  kind text not null check (kind in ('in','out')),
  amount numeric(10,2) not null check (amount > 0),
  method text not null default 'cash',
  reason text not null,
  created_by uuid, created_at timestamptz not null default now()
);

create or replace function public.payments_set_session() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.cash_session_id is null then
    select id into new.cash_session_id from public.cash_sessions where status = 'open' limit 1;
  end if;
  return new;
end $$;
drop trigger if exists trg_payments_session on public.payments;
create trigger trg_payments_session before insert on public.payments
  for each row execute function public.payments_set_session();

create or replace function public.cash_summary(p_session uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.cash_sessions%rowtype; v_pay jsonb; v_in numeric; v_out numeric; v_cash numeric; v_exp numeric;
begin
  perform public._require_admin();
  if p_session is null then select * into s from public.cash_sessions where status = 'open' limit 1;
  else select * into s from public.cash_sessions where id = p_session; end if;
  if s.id is null then return null; end if;
  select coalesce(jsonb_object_agg(method, t), '{}'::jsonb) into v_pay
    from (select method, sum(amount) t from public.payments where cash_session_id = s.id group by method) x;
  select coalesce(sum(amount) filter (where kind = 'in'  and method = 'cash'), 0),
         coalesce(sum(amount) filter (where kind = 'out' and method = 'cash'), 0)
    into v_in, v_out from public.cash_movements where session_id = s.id;
  v_cash := coalesce((v_pay ->> 'cash')::numeric, 0);
  v_exp := s.opening_amount + v_cash + v_in - v_out;
  return jsonb_build_object('id', s.id, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opening_amount', s.opening_amount, 'payments_by_method', v_pay, 'manual_in', v_in, 'manual_out', v_out,
    'expected_cash', v_exp, 'counted_cash', s.counted_cash, 'difference', s.difference, 'note', s.note,
    'movements', coalesce((select jsonb_agg(jsonb_build_object('kind', m.kind, 'amount', m.amount, 'method', m.method,
        'reason', m.reason, 'at', m.created_at) order by m.created_at) from public.cash_movements m where m.session_id = s.id), '[]'::jsonb));
end $$;

create or replace function public.cash_open(p_amount numeric default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public._require_admin();
  if coalesce(p_amount, 0) < 0 then raise exception 'Valor inicial inválido.'; end if;
  begin
    insert into public.cash_sessions (opened_by, opening_amount) values (auth.uid(), coalesce(p_amount, 0)) returning id into v;
  exception when unique_violation then raise exception 'Já existe um caixa aberto. Feche-o antes de abrir outro.';
  end;
  return jsonb_build_object('id', v);
end $$;

create or replace function public.cash_add_movement(p_kind text, p_amount numeric, p_reason text, p_method text default 'cash') returns jsonb
language plpgsql security definer set search_path = public as $$
declare s uuid;
begin
  perform public._require_admin();
  if p_kind not in ('in','out') then raise exception 'Tipo inválido.'; end if;
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Informe um valor maior que zero.'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Informe o motivo.'; end if;
  select id into s from public.cash_sessions where status = 'open' limit 1;
  if s is null then raise exception 'Abra o caixa primeiro.'; end if;
  insert into public.cash_movements (session_id, kind, amount, method, reason, created_by) values (s, p_kind, p_amount, p_method, trim(p_reason), auth.uid());
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cash_close(p_counted numeric, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.cash_sessions%rowtype; v jsonb; v_exp numeric;
begin
  perform public._require_admin();
  select * into s from public.cash_sessions where status = 'open' for update;
  if not found then raise exception 'Não há caixa aberto.'; end if;
  if coalesce(p_counted, -1) < 0 then raise exception 'Informe o valor contado em dinheiro.'; end if;
  v := public.cash_summary(s.id);
  v_exp := (v ->> 'expected_cash')::numeric;
  update public.cash_sessions set status = 'closed', closed_at = now(), closed_by = auth.uid(), expected_cash = v_exp,
         counted_cash = p_counted, difference = p_counted - v_exp, totals = v -> 'payments_by_method', note = p_note
   where id = s.id;
  return jsonb_build_object('expected_cash', v_exp, 'counted_cash', p_counted, 'difference', p_counted - v_exp);
end $$;

-- ============================================================
-- DESPESAS
-- ============================================================
create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(), name text not null unique, is_active boolean not null default true
);
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.expense_categories(id) on delete set null,
  description text not null,
  amount numeric(10,2) not null check (amount >= 0),
  due_date date not null default current_date,
  paid_at timestamptz,
  method text check (method in ('pix','cash','debit','credit','other')),
  status text not null default 'pending' check (status in ('pending','paid')),
  is_demo boolean not null default false,
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists idx_exp_due on public.expenses (due_date, status);
insert into public.expense_categories (name) values ('Aluguel'),('Energia'),('Água'),('Internet'),('Produtos/materiais'),
  ('Manutenção'),('Alimentação'),('Marketing'),('Impostos/taxas'),('Outros') on conflict (name) do nothing;

-- ============================================================
-- PRODUTOS, ESTOQUE, KITS
-- ============================================================
create table if not exists public.product_categories (id uuid primary key default gen_random_uuid(), name text not null unique);
insert into public.product_categories (name) values ('Cabelo'),('Barba'),('Acessórios'),('Outros') on conflict (name) do nothing;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null, description text, photo_url text,
  price numeric(10,2) not null check (price >= 0),
  cost numeric(10,2) not null default 0 check (cost >= 0),
  category_id uuid references public.product_categories(id) on delete set null,
  quantity int not null default 0 check (quantity >= 0),
  low_stock_limit int not null default 2 check (low_stock_limit >= 0),
  is_active boolean not null default true,
  is_demo boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
drop trigger if exists trg_products_updated on public.products;
create trigger trg_products_updated before update on public.products for each row execute function public.set_updated_at();

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  kind text not null check (kind in ('in','out','adjust','sale')),
  delta int not null, reason text, sale_id uuid,
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists idx_stockmov_prod on public.stock_movements (product_id, created_at desc);

create table if not exists public.kits (
  id uuid primary key default gen_random_uuid(),
  name text not null, description text, photo_url text,
  price numeric(10,2) not null check (price >= 0),
  is_active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.kit_items (
  id uuid primary key default gen_random_uuid(),
  kit_id uuid not null references public.kits(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity int not null default 1 check (quantity > 0),
  unique (kit_id, product_id)
);

create or replace function public.trg_low_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_active and not new.is_demo and new.quantity <= new.low_stock_limit and new.quantity is distinct from old.quantity then
    if public._alert_once('low_stock', new.id::text || ':' || public._today()::text) then
      perform public._notify_admins('low_stock', 'Estoque baixo: ' || new.name, 'Restam ' || new.quantity || ' unidade(s).', jsonb_build_object('product_id', new.id));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_products_low_stock on public.products;
create trigger trg_products_low_stock after update on public.products for each row execute function public.trg_low_stock();

create or replace function public.stock_move(p_product uuid, p_kind text, p_qty int, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_delta int; v_q int;
begin
  perform public._require_admin();
  if p_kind not in ('in','out','adjust') then raise exception 'Tipo inválido.'; end if;
  if p_qty is null or p_qty = 0 then raise exception 'Informe a quantidade.'; end if;
  if p_kind in ('in','out') and p_qty < 0 then raise exception 'A quantidade precisa ser positiva.'; end if;
  if p_kind = 'adjust' and nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Informe o motivo do ajuste.'; end if;
  v_delta := case when p_kind = 'out' then -p_qty else p_qty end;
  update public.products set quantity = quantity + v_delta where id = p_product returning quantity into v_q;
  if not found then raise exception 'Produto não encontrado.'; end if;
  insert into public.stock_movements (product_id, kind, delta, reason) values (p_product, p_kind, v_delta, p_reason);
  return jsonb_build_object('quantity', v_q);
exception when check_violation then raise exception 'O estoque não pode ficar negativo.';
end $$;

-- vitrine publica (sem custo e sem quantidade exata)
create or replace view public.public_products as
  select p.id, p.name, p.description, p.photo_url, p.price, pc.name as category, (p.quantity > 0) as in_stock
  from public.products p left join public.product_categories pc on pc.id = p.category_id
  where p.is_active and not p.is_demo;
create or replace view public.public_kits as
  select k.id, k.name, k.description, k.photo_url, k.price,
         coalesce((select jsonb_agg(jsonb_build_object('name', p.name, 'qty', ki.quantity)) from public.kit_items ki
                   join public.products p on p.id = ki.product_id where ki.kit_id = k.id), '[]'::jsonb) as items
  from public.kits k where k.is_active;
grant select on public.public_products, public.public_kits to anon, authenticated;

-- ============================================================
-- CUPONS
-- ============================================================
create table if not exists public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null unique, kind text not null check (kind in ('percent','fixed')),
  amount numeric(10,2) not null check (amount > 0),
  starts_at timestamptz, ends_at timestamptz,
  max_uses int, max_per_customer int, min_purchase numeric(10,2) not null default 0,
  applies_to text not null default 'all' check (applies_to in ('all','services','products')),
  is_active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references public.coupons(id), customer_id uuid references public.customers(id) on delete set null,
  sale_id uuid, appointment_id uuid, discount numeric(10,2) not null, created_at timestamptz not null default now()
);

create or replace function public._apply_coupon(p_code text, p_customer uuid, p_subtotal numeric, p_scope text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.coupons%rowtype; v_n int; v_d numeric;
begin
  select * into c from public.coupons where upper(code) = upper(trim(p_code)) for update;
  if not found or not c.is_active then raise exception 'Cupom inválido.'; end if;
  if c.starts_at is not null and now() < c.starts_at then raise exception 'Este cupom ainda não começou.'; end if;
  if c.ends_at is not null and now() > c.ends_at then raise exception 'Este cupom expirou.'; end if;
  if c.applies_to <> 'all' and c.applies_to <> p_scope then raise exception 'Este cupom não vale para este tipo de compra.'; end if;
  if p_subtotal < c.min_purchase then raise exception 'Compra mínima para este cupom: R$ %.', c.min_purchase; end if;
  if c.max_uses is not null then
    select count(*) into v_n from public.coupon_redemptions where coupon_id = c.id;
    if v_n >= c.max_uses then raise exception 'Este cupom atingiu o limite de usos.'; end if;
  end if;
  if c.max_per_customer is not null then
    if p_customer is null then raise exception 'Este cupom exige um cliente cadastrado.'; end if;
    select count(*) into v_n from public.coupon_redemptions where coupon_id = c.id and customer_id = p_customer;
    if v_n >= c.max_per_customer then raise exception 'Este cliente já usou o limite deste cupom.'; end if;
  end if;
  v_d := case when c.kind = 'percent' then round(p_subtotal * least(c.amount, 100) / 100, 2) else least(c.amount, p_subtotal) end;
  return jsonb_build_object('coupon_id', c.id, 'discount', v_d);
end $$;

-- ============================================================
-- VENDAS
-- ============================================================
create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  request_id uuid unique,
  customer_id uuid references public.customers(id) on delete set null,
  appointment_id uuid references public.appointments(id) on delete set null,
  subtotal numeric(10,2) not null, discount_kind text, discount_value numeric(10,2) not null default 0, discount_reason text,
  coupon_id uuid references public.coupons(id), total numeric(10,2) not null,
  method text not null, status text not null default 'paid' check (status in ('paid','void')),
  is_demo boolean not null default false, created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  kind text not null check (kind in ('product','kit')),
  product_id uuid references public.products(id) on delete set null, kit_id uuid references public.kits(id) on delete set null,
  name text not null, qty int not null check (qty > 0),
  unit_price_original numeric(10,2) not null, unit_price_final numeric(10,2) not null, unit_cost numeric(10,2) not null default 0
);
create index if not exists idx_sales_created on public.sales (created_at);

create or replace function public.admin_register_sale(
  p_items jsonb, p_method text, p_customer_id uuid default null, p_appointment_id uuid default null,
  p_discount_kind text default null, p_discount_amount numeric default 0, p_discount_reason text default null,
  p_coupon text default null, p_request uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; v_type text; v_id uuid; v_qty int; pr public.products%rowtype; k public.kits%rowtype; ki record;
  v_sub numeric := 0; v_manual numeric := 0; v_cdisc numeric := 0; v_cid uuid; v_cup jsonb; v_total numeric;
  v_sale uuid; v_demo boolean := false; v_cost numeric; v_exist uuid;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Adicione pelo menos um item.'; end if;
  if p_request is not null then
    select id into v_exist from public.sales where request_id = p_request;
    if v_exist is not null then return jsonb_build_object('id', v_exist, 'duplicate', true); end if;
  end if;
  if p_customer_id is not null then select is_demo into v_demo from public.customers where id = p_customer_id; end if;
  v_demo := coalesce(v_demo, false);

  -- 1) calcula subtotal e valida estoque (trava as linhas)
  for it in select * from jsonb_array_elements(p_items) loop
    v_type := it ->> 'type'; v_id := (it ->> 'id')::uuid; v_qty := coalesce((it ->> 'qty')::int, 1);
    if v_qty <= 0 then raise exception 'Quantidade inválida.'; end if;
    if v_type = 'product' then
      select * into pr from public.products where id = v_id for update;
      if not found then raise exception 'Produto não encontrado.'; end if;
      if pr.quantity < v_qty then raise exception 'Estoque insuficiente de %: restam %.', pr.name, pr.quantity; end if;
      v_sub := v_sub + pr.price * v_qty;
    elsif v_type = 'kit' then
      select * into k from public.kits where id = v_id;
      if not found then raise exception 'Kit não encontrado.'; end if;
      for ki in select ki2.quantity, p.id, p.name, p.quantity as stock from public.kit_items ki2 join public.products p on p.id = ki2.product_id where ki2.kit_id = k.id loop
        perform 1 from public.products where id = ki.id for update;
        if ki.stock < ki.quantity * v_qty then raise exception 'Estoque insuficiente de % (componente do kit %).', ki.name, k.name; end if;
      end loop;
      v_sub := v_sub + k.price * v_qty;
    else raise exception 'Tipo de item inválido.'; end if;
  end loop;

  -- 2) descontos
  if coalesce(p_discount_amount, 0) > 0 then
    if nullif(trim(coalesce(p_discount_reason, '')), '') is null then raise exception 'Informe o motivo do desconto.'; end if;
    v_manual := case when p_discount_kind = 'percent' then round(v_sub * least(p_discount_amount, 100) / 100, 2) else least(p_discount_amount, v_sub) end;
  end if;
  if nullif(trim(coalesce(p_coupon, '')), '') is not null then
    v_cup := public._apply_coupon(p_coupon, p_customer_id, v_sub - v_manual, 'products');
    v_cdisc := (v_cup ->> 'discount')::numeric; v_cid := (v_cup ->> 'coupon_id')::uuid;
  end if;
  v_total := v_sub - v_manual - v_cdisc;

  insert into public.sales (request_id, customer_id, appointment_id, subtotal, discount_kind, discount_value, discount_reason, coupon_id, total, method, is_demo)
  values (p_request, p_customer_id, p_appointment_id, v_sub, p_discount_kind, v_manual + v_cdisc, nullif(trim(coalesce(p_discount_reason, '')), ''), v_cid, v_total, p_method, v_demo)
  returning id into v_sale;

  -- 3) baixa de estoque e itens
  for it in select * from jsonb_array_elements(p_items) loop
    v_type := it ->> 'type'; v_id := (it ->> 'id')::uuid; v_qty := coalesce((it ->> 'qty')::int, 1);
    if v_type = 'product' then
      select * into pr from public.products where id = v_id;
      update public.products set quantity = quantity - v_qty where id = v_id;
      insert into public.stock_movements (product_id, kind, delta, reason, sale_id) values (v_id, 'sale', -v_qty, 'Venda', v_sale);
      insert into public.sale_items (sale_id, kind, product_id, name, qty, unit_price_original, unit_price_final, unit_cost)
      values (v_sale, 'product', v_id, pr.name, v_qty, pr.price, pr.price, pr.cost);
    else
      select * into k from public.kits where id = v_id; v_cost := 0;
      for ki in select ki2.quantity, p.id, p.cost from public.kit_items ki2 join public.products p on p.id = ki2.product_id where ki2.kit_id = k.id loop
        update public.products set quantity = quantity - ki.quantity * v_qty where id = ki.id;
        insert into public.stock_movements (product_id, kind, delta, reason, sale_id) values (ki.id, 'sale', -ki.quantity * v_qty, 'Venda do kit ' || k.name, v_sale);
        v_cost := v_cost + ki.cost * ki.quantity;
      end loop;
      insert into public.sale_items (sale_id, kind, kit_id, name, qty, unit_price_original, unit_price_final, unit_cost)
      values (v_sale, 'kit', v_id, k.name, v_qty, k.price, k.price, v_cost);
    end if;
  end loop;

  if v_cid is not null then
    insert into public.coupon_redemptions (coupon_id, customer_id, sale_id, discount) values (v_cid, p_customer_id, v_sale, v_cdisc);
  end if;
  if v_total > 0 then
    insert into public.payments (customer_id, amount, method, kind, sale_id, created_by, is_demo, appointment_id)
    values (p_customer_id, v_total, p_method, 'product', v_sale, auth.uid(), v_demo, p_appointment_id);
  end if;
  return jsonb_build_object('id', v_sale, 'total', v_total, 'discount', v_manual + v_cdisc);
end $$;

-- ============================================================
-- PLANOS E ASSINATURAS
-- ============================================================
create table if not exists public.plans (
  id uuid primary key default gen_random_uuid(),
  name text not null, description text, price numeric(10,2) not null check (price >= 0),
  max_subscribers int, is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
drop trigger if exists trg_plans_updated on public.plans;
create trigger trg_plans_updated before update on public.plans for each row execute function public.set_updated_at();
create table if not exists public.plan_items (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans(id) on delete cascade,
  service_id uuid not null references public.services(id), quantity int not null check (quantity > 0),
  unique (plan_id, service_id)
);
create table if not exists public.plan_versions (
  id uuid primary key default gen_random_uuid(), plan_id uuid not null references public.plans(id) on delete cascade,
  snapshot jsonb not null, scope text, changed_by uuid default auth.uid(), changed_at timestamptz not null default now()
);

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id), plan_id uuid not null references public.plans(id),
  status text not null default 'pending' check (status in ('pending','active','past_due','suspended','cancel_requested','cancelling','cancelled')),
  price numeric(10,2) not null, started_at timestamptz,
  cycle_start date, cycle_end date, note text,
  is_demo boolean not null default false, created_at timestamptz not null default now()
);
create unique index if not exists one_live_sub on public.subscriptions (customer_id)
  where status in ('pending','active','past_due','suspended','cancel_requested','cancelling');
create table if not exists public.subscription_items (
  id uuid primary key default gen_random_uuid(), subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  service_id uuid not null references public.services(id), quantity int not null check (quantity > 0), unique (subscription_id, service_id)
);
create table if not exists public.subscription_cycles (
  id uuid primary key default gen_random_uuid(), subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  cycle_start date not null, cycle_end date not null, price numeric(10,2) not null, payment_id uuid,
  created_at timestamptz not null default now()
);
create table if not exists public.subscription_credits (
  id uuid primary key default gen_random_uuid(), subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  cycle_id uuid references public.subscription_cycles(id) on delete cascade, service_id uuid not null references public.services(id),
  total int not null check (total >= 0), used int not null default 0, expires_on date not null, expired boolean not null default false,
  check (used >= 0 and used <= total)
);
create table if not exists public.credit_transactions (
  id uuid primary key default gen_random_uuid(), subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  credit_id uuid references public.subscription_credits(id) on delete set null,
  appointment_id uuid references public.appointments(id) on delete set null, appointment_item_id uuid,
  kind text not null check (kind in ('grant','use','refund','adjust','expire')), delta int not null, reason text,
  created_by uuid, created_at timestamptz not null default now()
);
create unique index if not exists uq_credit_use_item on public.credit_transactions (appointment_item_id)
  where kind = 'use' and appointment_item_id is not null;

create or replace function public._consume_credit(p_customer uuid, p_service uuid, p_appt uuid, p_item uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare c record; v_today date := public._today();
begin
  select sc.* into c from public.subscription_credits sc join public.subscriptions s on s.id = sc.subscription_id
   where s.customer_id = p_customer and s.status in ('active','cancel_requested','cancelling') and s.cycle_end > v_today
     and sc.service_id = p_service and not sc.expired and sc.used < sc.total and sc.expires_on > v_today
   order by sc.expires_on limit 1 for update of sc;
  if not found then return false; end if;
  begin
    insert into public.credit_transactions (subscription_id, credit_id, appointment_id, appointment_item_id, kind, delta, reason, created_by)
    values (c.subscription_id, c.id, p_appt, p_item, 'use', -1, p_reason, auth.uid());
  exception when unique_violation then return false;
  end;
  update public.subscription_credits set used = used + 1 where id = c.id;
  return true;
end $$;

create or replace function public._open_cycle(p_sub uuid, p_method text) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions%rowtype; v_today date := public._today(); v_cycle uuid; v_pay uuid;
begin
  select * into s from public.subscriptions where id = p_sub for update;
  if s.status = 'active' and s.cycle_start = v_today then raise exception 'A mensalidade de hoje já foi registrada.'; end if;
  insert into public.credit_transactions (subscription_id, credit_id, kind, delta, reason)
    select subscription_id, id, 'expire', -(total - used), 'Ciclo encerrado' from public.subscription_credits
     where subscription_id = p_sub and not expired and total - used > 0;
  update public.subscription_credits set expired = true where subscription_id = p_sub and not expired;
  insert into public.subscription_cycles (subscription_id, cycle_start, cycle_end, price) values (p_sub, v_today, v_today + 30, s.price) returning id into v_cycle;
  if s.price > 0 then
    insert into public.payments (customer_id, amount, method, kind, subscription_id, created_by, is_demo)
    values (s.customer_id, s.price, p_method, 'subscription', p_sub, auth.uid(), s.is_demo) returning id into v_pay;
    update public.subscription_cycles set payment_id = v_pay where id = v_cycle;
  end if;
  insert into public.subscription_credits (subscription_id, cycle_id, service_id, total, expires_on)
    select p_sub, v_cycle, service_id, quantity, v_today + 30 from public.subscription_items where subscription_id = p_sub;
  insert into public.credit_transactions (subscription_id, credit_id, kind, delta, reason)
    select subscription_id, id, 'grant', total, 'Novo ciclo de 30 dias' from public.subscription_credits where cycle_id = v_cycle;
  update public.subscriptions set cycle_start = v_today, cycle_end = v_today + 30, status = 'active', started_at = coalesce(started_at, now()) where id = p_sub;
  return v_cycle;
end $$;

create or replace function public.request_subscription(p_plan uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl public.plans%rowtype; p public.profiles%rowtype; v_cust uuid; v_n int; v_sub uuid;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para assinar.'; end if;
  select * into pl from public.plans where id = p_plan and is_active;
  if not found then raise exception 'Plano indisponível.'; end if;
  if pl.max_subscribers is not null then
    select count(*) into v_n from public.subscriptions where plan_id = p_plan and status in ('pending','active','past_due','suspended','cancel_requested','cancelling');
    if v_n >= pl.max_subscribers then raise exception 'Este plano atingiu o limite de assinantes.'; end if;
  end if;
  select * into p from public.profiles where id = auth.uid();
  v_cust := public.ensure_customer(p.full_name, p.whatsapp, p.id);
  begin
    insert into public.subscriptions (customer_id, plan_id, price, is_demo) values (v_cust, p_plan, pl.price, false) returning id into v_sub;
  exception when unique_violation then raise exception 'Você já tem uma assinatura em andamento.';
  end;
  insert into public.subscription_items (subscription_id, service_id, quantity) select v_sub, service_id, quantity from public.plan_items where plan_id = p_plan;
  perform public._notify_admins('subscription_request', 'Novo pedido de assinatura', coalesce(p.full_name, 'Cliente') || ' - ' || pl.name, jsonb_build_object('subscription_id', v_sub));
  return jsonb_build_object('id', v_sub);
end $$;

create or replace function public.admin_activate_subscription(p_sub uuid, p_method text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions%rowtype; v_c uuid; v_prof uuid;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  select * into s from public.subscriptions where id = p_sub for update;
  if not found then raise exception 'Assinatura não encontrada.'; end if;
  if s.status <> 'pending' then raise exception 'Esta assinatura não está pendente.'; end if;
  v_c := public._open_cycle(p_sub, p_method);
  select profile_id into v_prof from public.customers where id = s.customer_id;
  if v_prof is not null then
    insert into public.notifications (user_id, type, title, body) values (v_prof, 'subscription_active', 'Assinatura ativada!', 'Seus créditos já estão disponíveis.');
  end if;
  return jsonb_build_object('cycle_id', v_c);
end $$;

create or replace function public.admin_renew_subscription(p_sub uuid, p_method text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions%rowtype; v_c uuid;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  select * into s from public.subscriptions where id = p_sub for update;
  if not found then raise exception 'Assinatura não encontrada.'; end if;
  if s.status not in ('active','past_due','suspended') then raise exception 'Esta assinatura não pode ser renovada agora.'; end if;
  v_c := public._open_cycle(p_sub, p_method);
  return jsonb_build_object('cycle_id', v_c);
end $$;

create or replace function public.request_cancel_subscription(p_sub uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions%rowtype;
begin
  select s2.* into s from public.subscriptions s2 join public.customers c on c.id = s2.customer_id where s2.id = p_sub and c.profile_id = auth.uid() for update of s2;
  if not found then raise exception 'Assinatura não encontrada.'; end if;
  if s.status not in ('active','past_due','suspended','pending') then raise exception 'Não é possível pedir cancelamento agora.'; end if;
  update public.subscriptions set status = case when s.status = 'pending' then 'cancelled' else 'cancel_requested' end where id = p_sub;
  perform public._notify_admins('subscription_cancel', 'Pedido de cancelamento de assinatura', 'Confirme no painel.', jsonb_build_object('subscription_id', p_sub));
end $$;

create or replace function public.admin_confirm_cancel(p_sub uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s public.subscriptions%rowtype;
begin
  perform public._require_admin();
  select * into s from public.subscriptions where id = p_sub for update;
  if not found then raise exception 'Assinatura não encontrada.'; end if;
  if s.status in ('cancelled') then raise exception 'Já cancelada.'; end if;
  -- mantem os creditos ate o fim do ciclo ja pago; depois encerra
  update public.subscriptions set status = case when s.status in ('active','cancel_requested') and s.cycle_end > public._today() then 'cancelling' else 'cancelled' end where id = p_sub;
end $$;

create or replace function public.admin_set_subscription_status(p_sub uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_status not in ('suspended','active') then raise exception 'Status inválido.'; end if;
  update public.subscriptions set status = p_status where id = p_sub and status in ('past_due','suspended','active');
  if not found then raise exception 'Não foi possível alterar esta assinatura.'; end if;
end $$;

create or replace function public.admin_adjust_credit(p_sub uuid, p_service uuid, p_delta int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare c public.subscription_credits%rowtype;
begin
  perform public._require_admin();
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Informe o motivo do ajuste.'; end if;
  if coalesce(p_delta, 0) = 0 then raise exception 'Informe a quantidade.'; end if;
  select sc.* into c from public.subscription_credits sc where sc.subscription_id = p_sub and sc.service_id = p_service and not sc.expired
   order by sc.expires_on desc limit 1 for update;
  if not found then raise exception 'Este serviço não tem crédito no ciclo atual.'; end if;
  if c.total + p_delta < c.used then raise exception 'O crédito não pode ficar negativo.'; end if;
  update public.subscription_credits set total = total + p_delta where id = c.id;
  insert into public.credit_transactions (subscription_id, credit_id, kind, delta, reason, created_by) values (p_sub, c.id, 'adjust', p_delta, trim(p_reason), auth.uid());
end $$;

create or replace function public.admin_noshow_credit(p_appointment uuid, p_discount boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.appointments%rowtype; it record; n int := 0;
begin
  perform public._require_admin();
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Informe o motivo.'; end if;
  select * into a from public.appointments where id = p_appointment;
  if not found or a.status <> 'no_show' then raise exception 'Marque a falta antes.'; end if;
  if p_discount and a.customer_id is not null then
    for it in select * from public.appointment_items where appointment_id = a.id and service_id is not null loop
      if public._consume_credit(a.customer_id, it.service_id, a.id, it.id, 'Falta: ' || trim(p_reason)) then n := n + 1; end if;
    end loop;
  end if;
  update public.appointments set notes = coalesce(notes || E'\n', '') || 'Falta - crédito ' || case when p_discount then 'descontado' else 'mantido' end || ': ' || trim(p_reason) where id = a.id;
  return jsonb_build_object('credits_used', n);
end $$;

create or replace function public.admin_update_plan(p_plan uuid, p_name text, p_description text, p_price numeric, p_max int,
  p_active boolean, p_items jsonb, p_scope text default 'new', p_subs uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_plan; it jsonb; v_targets uuid[];
begin
  perform public._require_admin();
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Informe o nome do plano.'; end if;
  if coalesce(p_price, -1) < 0 then raise exception 'Preço inválido.'; end if;
  if p_scope not in ('new','all','selected') then raise exception 'Escopo inválido.'; end if;
  if v_id is null then
    insert into public.plans (name, description, price, max_subscribers, is_active) values (trim(p_name), p_description, p_price, p_max, coalesce(p_active, true)) returning id into v_id;
  else
    update public.plans set name = trim(p_name), description = p_description, price = p_price, max_subscribers = p_max, is_active = coalesce(p_active, true) where id = v_id;
    if not found then raise exception 'Plano não encontrado.'; end if;
  end if;
  delete from public.plan_items where plan_id = v_id;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if coalesce((it ->> 'quantity')::int, 0) > 0 then
      insert into public.plan_items (plan_id, service_id, quantity) values (v_id, (it ->> 'service_id')::uuid, (it ->> 'quantity')::int)
      on conflict (plan_id, service_id) do update set quantity = excluded.quantity;
    end if;
  end loop;
  insert into public.plan_versions (plan_id, snapshot, scope) values (v_id,
    jsonb_build_object('name', p_name, 'price', p_price, 'items', coalesce(p_items, '[]'::jsonb), 'active', p_active), p_scope);
  if p_plan is not null and p_scope <> 'new' then
    select array_agg(id) into v_targets from public.subscriptions
     where plan_id = v_id and status in ('active','past_due','suspended','cancel_requested','pending') and (p_scope = 'all' or id = any(p_subs));
    if v_targets is not null then
      update public.subscriptions set price = p_price where id = any(v_targets);
      delete from public.subscription_items where subscription_id = any(v_targets);
      insert into public.subscription_items (subscription_id, service_id, quantity)
        select t, pi.service_id, pi.quantity from unnest(v_targets) t join public.plan_items pi on pi.plan_id = v_id;
    end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.my_subscription() returns jsonb
language sql stable security definer set search_path = public as $$
  select (select jsonb_build_object(
      'id', s.id, 'status', s.status, 'plan_name', p.name, 'price', s.price, 'cycle_start', s.cycle_start, 'cycle_end', s.cycle_end,
      'credits', coalesce((select jsonb_agg(jsonb_build_object('service', sv.name, 'total', cr.total, 'used', cr.used, 'expires_on', cr.expires_on, 'expired', cr.expired) order by sv.sort_order)
                           from public.subscription_credits cr join public.services sv on sv.id = cr.service_id
                           where cr.subscription_id = s.id and cr.cycle_id = (select id from public.subscription_cycles where subscription_id = s.id order by cycle_start desc, created_at desc limit 1)), '[]'::jsonb),
      'usage', coalesce((select jsonb_agg(jsonb_build_object('date', t.created_at, 'kind', t.kind, 'delta', t.delta, 'reason', t.reason) order by t.created_at desc)
                         from (select * from public.credit_transactions where subscription_id = s.id order by created_at desc limit 30) t), '[]'::jsonb),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('date', pm.paid_at, 'amount', pm.amount, 'method', pm.method) order by pm.paid_at desc)
                            from public.payments pm where pm.subscription_id = s.id), '[]'::jsonb))
    from public.subscriptions s join public.plans p on p.id = s.plan_id join public.customers cu on cu.id = s.customer_id
    where cu.profile_id = auth.uid() and s.status <> 'cancelled' order by s.created_at desc limit 1)
$$;

-- rotina diaria: vencimentos, expiracao de creditos e lembretes (3 dias antes, no dia, depois)
create or replace function public.subscriptions_daily() returns int
language plpgsql security definer set search_path = public as $$
declare s record; v_today date := public._today(); v_prof uuid; n int := 0; v_diff int;
begin
  for s in select sb.*, cu.profile_id, cu.full_name, p.name as plan_name from public.subscriptions sb
           join public.customers cu on cu.id = sb.customer_id join public.plans p on p.id = sb.plan_id
           where sb.status in ('active','past_due','cancel_requested','cancelling','suspended') and sb.cycle_end is not null and not sb.is_demo loop
    v_diff := s.cycle_end - v_today;
    if v_diff <= 0 then
      insert into public.credit_transactions (subscription_id, credit_id, kind, delta, reason)
        select subscription_id, id, 'expire', -(total - used), 'Ciclo encerrado' from public.subscription_credits
         where subscription_id = s.id and not expired and total - used > 0;
      update public.subscription_credits set expired = true where subscription_id = s.id and not expired;
      if s.status = 'cancelling' then update public.subscriptions set status = 'cancelled' where id = s.id;
      elsif s.status in ('active','cancel_requested') then
        update public.subscriptions set status = case when s.status = 'cancel_requested' then 'cancel_requested' else 'past_due' end where id = s.id;
        if s.status = 'active' and public._alert_once('sub_overdue_admin', s.id::text || ':' || s.cycle_end::text) then
          perform public._notify_admins('subscription_overdue', 'Mensalidade vencida', coalesce(s.full_name, 'Cliente') || ' - ' || s.plan_name, jsonb_build_object('subscription_id', s.id));
          n := n + 1;
        end if;
      end if;
    end if;
    if s.profile_id is not null and s.status in ('active','past_due') then
      if v_diff = 3 and public._alert_once('sub_due_3', s.id::text || ':' || s.cycle_end::text) then
        insert into public.notifications (user_id, type, title, body) values (s.profile_id, 'subscription_due', 'Sua mensalidade vence em 3 dias', s.plan_name); n := n + 1;
      elsif v_diff = 0 and public._alert_once('sub_due_0', s.id::text || ':' || s.cycle_end::text) then
        insert into public.notifications (user_id, type, title, body) values (s.profile_id, 'subscription_due', 'Sua mensalidade vence hoje', s.plan_name); n := n + 1;
      elsif v_diff < 0 and public._alert_once('sub_due_late', s.id::text || ':' || s.cycle_end::text) then
        insert into public.notifications (user_id, type, title, body) values (s.profile_id, 'subscription_due', 'Mensalidade em atraso', 'Fale com a barbearia para regularizar.'); n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;

-- ============================================================
-- FINALIZAR ATENDIMENTO (credito de assinatura, desconto com motivo, cupom, pagamento unico)
-- ============================================================
drop function if exists public.complete_appointment(uuid, jsonb, text, numeric, text);
drop function if exists public.admin_walkin(uuid[], text, text, uuid, jsonb, text, numeric);

create or replace function public._finalize_appointment(
  p_id uuid, p_prices jsonb, p_method text, p_discount numeric, p_note text, p_use_credits boolean, p_reason text, p_coupon text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.appointments%rowtype; it record; v_price numeric; v_sub numeric := 0; v_final numeric; v_credits int := 0;
        v_manual numeric := coalesce(p_discount, 0); v_cdisc numeric := 0; v_cid uuid; v_cup jsonb;
begin
  select * into a from public.appointments where id = p_id;
  for it in select * from public.appointment_items where appointment_id = p_id order by sequence loop
    v_price := coalesce((p_prices ->> it.id::text)::numeric, (p_prices ->> it.service_id::text)::numeric, it.price_estimated);
    if v_price < 0 then raise exception 'O valor não pode ser negativo.'; end if;
    if p_use_credits and a.customer_id is not null and it.service_id is not null
       and public._consume_credit(a.customer_id, it.service_id, p_id, it.id, 'Atendimento concluído') then
      v_price := 0; v_credits := v_credits + 1;
      update public.appointment_items set price_final = 0, credit_used = true where id = it.id;
    else
      update public.appointment_items set price_final = v_price where id = it.id;
    end if;
    v_sub := v_sub + v_price;
  end loop;
  if v_manual < 0 or v_manual > v_sub then raise exception 'Desconto inválido.'; end if;
  if v_manual > 0 and nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Informe o motivo do desconto.'; end if;
  if nullif(trim(coalesce(p_coupon, '')), '') is not null then
    v_cup := public._apply_coupon(p_coupon, a.customer_id, v_sub - v_manual, 'services');
    v_cdisc := (v_cup ->> 'discount')::numeric; v_cid := (v_cup ->> 'coupon_id')::uuid;
  end if;
  v_final := v_sub - v_manual - v_cdisc;
  update public.appointments set final_total = v_final, discount_value = v_manual + v_cdisc,
         discount_reason = nullif(trim(coalesce(p_reason, '')), ''), coupon_id = v_cid where id = p_id;
  if v_cid is not null then
    insert into public.coupon_redemptions (coupon_id, customer_id, appointment_id, discount) values (v_cid, a.customer_id, p_id, v_cdisc);
  end if;
  if v_final > 0 then
    insert into public.payments (appointment_id, customer_id, amount, method, note, created_by, kind, is_demo)
    values (p_id, a.customer_id, v_final, p_method, p_note, auth.uid(), 'service', a.is_demo);
  end if;
  return jsonb_build_object('final_total', v_final, 'credits_used', v_credits);
end $$;

create or replace function public.complete_appointment(
  p_id uuid, p_prices jsonb default '{}'::jsonb, p_method text default 'cash', p_discount numeric default 0, p_note text default null,
  p_use_credits boolean default true, p_discount_reason text default null, p_coupon text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.appointments%rowtype; r jsonb;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  select * into a from public.appointments where id = p_id for update;
  if not found then raise exception 'Agendamento não encontrado.'; end if;
  if a.status not in ('pending','confirmed') then raise exception 'Este agendamento já foi finalizado.'; end if;
  r := public._finalize_appointment(p_id, p_prices, p_method, p_discount, p_note, p_use_credits, p_discount_reason, p_coupon);
  update public.appointments set status = 'completed' where id = p_id;
  if a.client_id is not null then
    insert into public.notifications (user_id, type, title, body, data)
    values (a.client_id, 'review_invite', 'Como foi seu atendimento?', 'Deixe sua avaliação na área do cliente.', jsonb_build_object('appointment_id', p_id));
  end if;
  return r || jsonb_build_object('id', p_id);
end $$;

create or replace function public.admin_walkin(
  p_service_ids uuid[], p_name text default null, p_whatsapp text default null, p_customer_id uuid default null,
  p_prices jsonb default '{}'::jsonb, p_method text default 'cash', p_discount numeric default 0,
  p_use_credits boolean default true, p_discount_reason text default null, p_coupon text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_n int; v_dur int; v_barber uuid; v_id uuid; v_cust uuid := p_customer_id; v_name text; v_wa text; v_profile uuid; v_total numeric; v_demo boolean := false; r jsonb;
begin
  perform public._require_admin();
  if p_method not in ('pix','cash','debit','credit','other') then raise exception 'Forma de pagamento inválida.'; end if;
  select array_agg(distinct x) into v_ids from unnest(p_service_ids) x;
  if v_ids is null or array_length(v_ids, 1) is null then raise exception 'Selecione pelo menos um serviço.'; end if;
  select count(*), sum(duration_min), sum(price) into v_n, v_dur, v_total from public.services where id = any(v_ids);
  if v_n is distinct from array_length(v_ids, 1) then raise exception 'Algum serviço escolhido não existe.'; end if;
  if v_cust is not null then
    select full_name, whatsapp, profile_id, is_demo into v_name, v_wa, v_profile, v_demo from public.customers where id = v_cust;
  else
    v_name := coalesce(nullif(trim(p_name), ''), 'Cliente avulso');
    v_wa := nullif(regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'), '');
    if v_wa is not null then
      v_cust := public.ensure_customer(v_name, v_wa, null);
      select profile_id into v_profile from public.customers where id = v_cust;
    end if;
  end if;
  v_barber := (select id from public.barbers where is_active order by created_at limit 1);
  insert into public.appointments (barber_id, client_id, customer_id, guest_name, guest_whatsapp, start_at, end_at, status, source, estimated_total, is_demo)
  values (v_barber, v_profile, v_cust, v_name, v_wa, now(), now() + make_interval(mins => v_dur), 'completed', 'walk_in', v_total, coalesce(v_demo, false))
  returning id into v_id;
  perform public._add_items(v_id, v_ids);
  r := public._finalize_appointment(v_id, p_prices, p_method, p_discount, null, p_use_credits, p_discount_reason, p_coupon);
  return r || jsonb_build_object('id', v_id);
end $$;

-- ============================================================
-- LISTA DE ESPERA: fila (ordem de inscricao) + convite de 15 minutos
-- ============================================================
create table if not exists public.waitlist_offers (
  id uuid primary key default gen_random_uuid(),
  waitlist_id uuid not null references public.waitlist(id) on delete cascade,
  client_id uuid not null references public.profiles(id) on delete cascade,
  offered_start timestamptz not null, duration_min int not null,
  expires_at timestamptz not null,
  status text not null default 'offered' check (status in ('offered','accepted','expired','declined')),
  created_at timestamptz not null default now()
);
create index if not exists idx_offers_status on public.waitlist_offers (status, expires_at);

create or replace function public.waitlist_process(p_date date) returns void
language plpgsql security definer set search_path = public as $$
declare w record; v_dur int; v_slot timestamptz; v_offer uuid;
begin
  if exists (select 1 from public.waitlist_offers o join public.waitlist wl on wl.id = o.waitlist_id
             where o.status = 'offered' and o.expires_at > now() and wl.desired_date = p_date) then
    return;  -- ja existe um convite valido para esse dia
  end if;
  for w in select * from public.waitlist where status = 'active' and desired_date = p_date order by created_at loop
    select sum(duration_min) into v_dur from public.services where id = any(w.service_ids);
    if v_dur is null then continue; end if;
    select min(s.slot_start) into v_slot from public.get_available_slots(p_date, v_dur) s
     where (s.slot_start at time zone 'America/Recife')::time >= w.from_time
       and (s.slot_start at time zone 'America/Recife')::time + make_interval(mins => v_dur) <= w.to_time;
    if v_slot is not null then
      insert into public.waitlist_offers (waitlist_id, client_id, offered_start, duration_min, expires_at)
      values (w.id, w.client_id, v_slot, v_dur, now() + interval '15 minutes') returning id into v_offer;
      update public.waitlist set status = 'notified', notified_at = now() where id = w.id;
      insert into public.notifications (user_id, type, title, body, data)
      values (w.client_id, 'waitlist_offer', 'Abriu um horário para você!',
              'Dia ' || to_char(p_date, 'DD/MM') || ' às ' || to_char(v_slot at time zone 'America/Recife', 'HH24:MI') || '. Você tem 15 minutos para aceitar.',
              jsonb_build_object('offer_id', v_offer, 'date', p_date));
      return;
    end if;
  end loop;
end $$;

create or replace function public.notify_waitlist() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status in ('pending','confirmed') and old.start_at > now() and (new.status = 'cancelled' or new.start_at <> old.start_at) then
    perform public.waitlist_process((old.start_at at time zone 'America/Recife')::date);
  end if;
  return new;
end $$;

create or replace function public.accept_waitlist_offer(p_offer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.waitlist_offers%rowtype; w public.waitlist%rowtype; r jsonb;
begin
  select * into o from public.waitlist_offers where id = p_offer and client_id = auth.uid() for update;
  if not found then raise exception 'Convite não encontrado.'; end if;
  if o.status <> 'offered' then raise exception 'Este convite não está mais disponível.'; end if;
  if o.expires_at < now() then raise exception 'O prazo de 15 minutos deste convite acabou.'; end if;
  select * into w from public.waitlist where id = o.waitlist_id;
  r := public.create_appointment(w.service_ids, o.offered_start, null, null);
  update public.waitlist_offers set status = 'accepted' where id = o.id;
  update public.waitlist set status = 'booked' where id = w.id;
  return r;
end $$;

create or replace function public.decline_waitlist_offer(p_offer uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.waitlist_offers%rowtype; d date;
begin
  select * into o from public.waitlist_offers where id = p_offer and client_id = auth.uid() and status = 'offered' for update;
  if not found then raise exception 'Convite não encontrado.'; end if;
  update public.waitlist_offers set status = 'declined' where id = o.id;
  update public.waitlist set status = 'expired' where id = o.waitlist_id returning desired_date into d;
  perform public.waitlist_process(d);
end $$;

create or replace function public.waitlist_expire() returns int
language plpgsql security definer set search_path = public as $$
declare o record; n int := 0; d date;
begin
  for o in select * from public.waitlist_offers where status = 'offered' and expires_at < now() for update skip locked loop
    update public.waitlist_offers set status = 'expired' where id = o.id;
    update public.waitlist set status = 'expired' where id = o.waitlist_id returning desired_date into d;
    insert into public.notifications (user_id, type, title, body) values (o.client_id, 'waitlist_expired', 'Seu convite expirou', 'O horário foi oferecido para o próximo da fila.');
    perform public.waitlist_process(d); n := n + 1;
  end loop;
  return n;
end $$;

alter table public.waitlist_offers enable row level security;
drop policy if exists offers_read on public.waitlist_offers;
create policy offers_read on public.waitlist_offers for select using (client_id = auth.uid() or public.is_admin());
drop policy if exists offers_admin on public.waitlist_offers;
create policy offers_admin on public.waitlist_offers for all using (public.is_admin()) with check (public.is_admin());

-- ============================================================
-- CONTEUDO: galeria, novidades, FAQ, avaliacoes
-- ============================================================
create table if not exists public.gallery_items (
  id uuid primary key default gen_random_uuid(), title text not null, description text, category text not null default 'outros',
  image_url text not null, published_at timestamptz not null default now(), is_featured boolean not null default false,
  is_visible boolean not null default true, is_demo boolean not null default false, created_at timestamptz not null default now()
);
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(), title text not null, body text not null, image_url text,
  published_at timestamptz not null default now(), expires_at timestamptz,
  status text not null default 'draft' check (status in ('draft','published')), is_featured boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.faq_items (
  id uuid primary key default gen_random_uuid(), question text not null, answer text not null,
  sort_order int not null default 0, is_active boolean not null default true
);
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  appointment_id uuid unique references public.appointments(id) on delete set null,
  rating int not null check (rating between 1 and 5), comment text, display_name text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','hidden')),
  created_at timestamptz not null default now()
);

create or replace view public.public_reviews as
  select id, display_name, rating, comment, created_at from public.reviews where status = 'approved';
grant select on public.public_reviews to anon, authenticated;

create or replace function public.submit_review(p_appointment uuid, p_rating int, p_comment text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.appointments%rowtype; p public.profiles%rowtype; v_name text;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para avaliar.'; end if;
  select * into a from public.appointments where id = p_appointment and client_id = auth.uid() and status = 'completed';
  if not found then raise exception 'Só é possível avaliar atendimentos concluídos da sua conta.'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'Escolha de 1 a 5 estrelas.'; end if;
  select * into p from public.profiles where id = auth.uid();
  v_name := split_part(coalesce(p.full_name, 'Cliente'), ' ', 1);
  begin
    insert into public.reviews (profile_id, appointment_id, rating, comment, display_name)
    values (auth.uid(), p_appointment, p_rating, left(nullif(trim(coalesce(p_comment, '')), ''), 500), v_name);
  exception when unique_violation then raise exception 'Você já avaliou este atendimento.';
  end;
  perform public._notify_admins('review_pending', 'Nova avaliação para aprovar', v_name || ' deu ' || p_rating || ' estrela(s).', '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_publish_announcement_notice(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare a public.announcements%rowtype; n int;
begin
  perform public._require_admin();
  select * into a from public.announcements where id = p_id and status = 'published';
  if not found then raise exception 'Publique a novidade antes de avisar os clientes.'; end if;
  if not public._alert_once('announcement_notice', p_id::text) then raise exception 'Os clientes já foram avisados desta novidade.'; end if;
  insert into public.notifications (user_id, type, title, body) select id, 'announcement', a.title, left(a.body, 140) from public.profiles where role = 'client' and is_active;
  get diagnostics n = row_count;
  return n;
end $$;

-- ============================================================
-- TAREFAS, METAS, CAMPANHAS, PRIVACIDADE
-- ============================================================
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(), title text not null, description text, due_at timestamptz,
  priority text not null default 'media' check (priority in ('baixa','media','alta')), category text,
  status text not null default 'pendente' check (status in ('pendente','em_andamento','concluida')),
  created_at timestamptz not null default now()
);
create table if not exists public.goals (
  id uuid primary key default gen_random_uuid(),
  period text not null check (period in ('day','week','month')),
  metric text not null check (metric in ('revenue','profit','product_qty','product_revenue')),
  target numeric(12,2) not null check (target >= 0), unique (period, metric)
);
create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(), name text not null, objective text, description text,
  starts_at date, ends_at date, segment text, message text,
  status text not null default 'draft' check (status in ('draft','prepared','finished')), created_at timestamptz not null default now()
);
create table if not exists public.campaign_recipients (
  id uuid primary key default gen_random_uuid(), campaign_id uuid not null references public.campaigns(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  status text not null default 'prepared' check (status in ('prepared','opened','sent_manual','responded','skipped')),
  result_note text, updated_at timestamptz not null default now(), unique (campaign_id, customer_id)
);
create table if not exists public.privacy_requests (
  id uuid primary key default gen_random_uuid(), profile_id uuid references public.profiles(id) on delete set null,
  contact text, kind text not null check (kind in ('access','correction','deletion')), details text,
  status text not null default 'open' check (status in ('open','done','rejected')),
  created_at timestamptz not null default now(), resolved_at timestamptz
);

create or replace function public.submit_privacy_request(p_kind text, p_details text default null) returns void
language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para fazer a solicitação.'; end if;
  if p_kind not in ('access','correction','deletion') then raise exception 'Tipo inválido.'; end if;
  select * into p from public.profiles where id = auth.uid();
  insert into public.privacy_requests (profile_id, contact, kind, details) values (auth.uid(), coalesce(p.email, p.whatsapp), p_kind, left(p_details, 1000));
  perform public._notify_admins('privacy_request', 'Nova solicitação de privacidade', coalesce(p.full_name, 'Cliente') || ' - ' || p_kind, '{}'::jsonb);
end $$;

-- Anonimiza o cliente sem apagar registros financeiros/historico
create or replace function public.admin_anonymize_customer(p_customer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.customers%rowtype;
begin
  perform public._require_admin();
  select * into c from public.customers where id = p_customer;
  if not found then raise exception 'Cliente não encontrado.'; end if;
  update public.appointments set guest_name = null, guest_whatsapp = null, notes = null where customer_id = p_customer;
  update public.customers set full_name = 'Cliente anonimizado', whatsapp = null, email = null, birth_date = null, notes = null,
         marketing_opt_in = false, is_active = false where id = p_customer;
  update public.reviews set comment = null, display_name = 'Cliente', status = 'hidden' where profile_id = c.profile_id and c.profile_id is not null;
  if c.profile_id is not null then delete from auth.users where id = c.profile_id; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ============================================================
-- ALERTAS PARA O CHARLEY (rodam a cada 15 minutos)
-- ============================================================
create or replace function public.admin_alerts() returns int
language plpgsql security definer set search_path = public as $$
declare a record; t record; e record; n int := 0;
begin
  for a in select * from public.appointments where status in ('pending','confirmed') and not is_demo
           and start_at + interval '15 minutes' < now() and start_at > now() - interval '12 hours' loop
    if now() < a.end_at then
      if public._alert_once('late15', a.id::text) then
        perform public._notify_admins('late', 'Cliente com mais de 15 min de atraso', coalesce(a.guest_name, 'Cliente') || ' - decida: atender, remarcar ou cancelar.', jsonb_build_object('appointment_id', a.id)); n := n + 1;
      end if;
    else
      if public._alert_once('decide', a.id::text) then
        perform public._notify_admins('decide', 'Atendimento sem desfecho', coalesce(a.guest_name, 'Cliente') || ' - marque como concluído ou falta.', jsonb_build_object('appointment_id', a.id)); n := n + 1;
      end if;
    end if;
  end loop;
  for t in select * from public.tasks where status <> 'concluida' and due_at is not null and due_at < now() loop
    if public._alert_once('task_late', t.id::text) then
      perform public._notify_admins('task_overdue', 'Tarefa atrasada', t.title, '{}'::jsonb); n := n + 1;
    end if;
  end loop;
  for e in select * from public.expenses where status = 'pending' and not is_demo and due_date <= public._today() + 3 loop
    if e.due_date < public._today() then
      if public._alert_once('bill_late', e.id::text) then perform public._notify_admins('bill_late', 'Conta atrasada', e.description, '{}'::jsonb); n := n + 1; end if;
    elsif public._alert_once('bill_soon', e.id::text) then
      perform public._notify_admins('bill_soon', 'Conta vence em breve', e.description || ' - ' || to_char(e.due_date, 'DD/MM'), '{}'::jsonb); n := n + 1;
    end if;
  end loop;
  n := n + public.subscriptions_daily();
  return n;
end $$;

do $$
begin
  begin create extension if not exists pg_cron; exception when others then raise notice 'pg_cron indisponível: %', sqlerrm; end;
  begin
    perform cron.schedule('alertas-barbearia', '*/15 * * * *', 'select public.admin_alerts()');
    perform cron.schedule('espera-barbearia', '* * * * *', 'select public.waitlist_expire()');
    raise notice 'OK: rotinas automáticas agendadas.';
  exception when others then raise notice 'AVISO: rotinas automáticas NÃO agendadas (%).', sqlerrm;
  end;
end $$;

-- ============================================================
-- RELATORIOS (somente administrador; dados DEMO nunca entram)
-- ============================================================
create or replace function public.report_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; tz text := 'America/Recife';
begin
  perform public._require_admin();
  r := jsonb_build_object(
    'revenue', coalesce((select sum(amount) from public.payments where not is_demo and (paid_at at time zone tz)::date between p_from and p_to), 0),
    'by_method', coalesce((select jsonb_object_agg(method, t) from (select method, sum(amount) t from public.payments where not is_demo and (paid_at at time zone tz)::date between p_from and p_to group by method) x), '{}'::jsonb),
    'by_kind', coalesce((select jsonb_object_agg(kind, t) from (select kind, sum(amount) t from public.payments where not is_demo and (paid_at at time zone tz)::date between p_from and p_to group by kind) x), '{}'::jsonb),
    'expenses', coalesce((select sum(amount) from public.expenses where not is_demo and status = 'paid' and (paid_at at time zone tz)::date between p_from and p_to), 0),
    'expenses_by_category', coalesce((select jsonb_object_agg(coalesce(c.name, 'Sem categoria'), x.t) from (select category_id, sum(amount) t from public.expenses
        where not is_demo and status = 'paid' and (paid_at at time zone tz)::date between p_from and p_to group by category_id) x left join public.expense_categories c on c.id = x.category_id), '{}'::jsonb),
    'appointments', (select jsonb_build_object('total', count(*), 'completed', count(*) filter (where status = 'completed'),
        'cancelled', count(*) filter (where status = 'cancelled'), 'no_show', count(*) filter (where status = 'no_show'),
        'open', count(*) filter (where status in ('pending','confirmed'))) from public.appointments where not is_demo and (start_at at time zone tz)::date between p_from and p_to),
    'new_customers', (select count(*) from public.customers where not is_demo and (created_at at time zone tz)::date between p_from and p_to),
    'avg_ticket', coalesce((select round(avg(final_total), 2) from public.appointments where status = 'completed' and not is_demo and (start_at at time zone tz)::date between p_from and p_to), 0),
    'top_services', coalesce((select jsonb_agg(x) from (select i.service_name as name, count(*) as qty, sum(coalesce(i.price_final, 0)) as revenue, round(avg(i.duration_min)) as avg_min
        from public.appointment_items i join public.appointments a on a.id = i.appointment_id
        where a.status = 'completed' and not a.is_demo and (a.start_at at time zone tz)::date between p_from and p_to
        group by i.service_name order by count(*) desc limit 12) x), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(x) from (select si.name, sum(si.qty) as qty, sum(si.qty * si.unit_price_final) as revenue, sum(si.qty * (si.unit_price_final - si.unit_cost)) as margin
        from public.sale_items si join public.sales s on s.id = si.sale_id
        where s.status = 'paid' and not s.is_demo and (s.created_at at time zone tz)::date between p_from and p_to
        group by si.name order by sum(si.qty) desc limit 12) x), '[]'::jsonb),
    'products_qty', coalesce((select sum(si.qty) from public.sale_items si join public.sales s on s.id = si.sale_id where s.status = 'paid' and not s.is_demo and (s.created_at at time zone tz)::date between p_from and p_to), 0),
    'products_revenue', coalesce((select sum(si.qty * si.unit_price_final) from public.sale_items si join public.sales s on s.id = si.sale_id where s.status = 'paid' and not s.is_demo and (s.created_at at time zone tz)::date between p_from and p_to), 0),
    'subs', jsonb_build_object(
        'active', (select count(*) from public.subscriptions where status = 'active' and not is_demo),
        'past_due', (select count(*) from public.subscriptions where status = 'past_due' and not is_demo),
        'pending', (select count(*) from public.subscriptions where status = 'pending' and not is_demo),
        'cancel_requested', (select count(*) from public.subscriptions where status = 'cancel_requested' and not is_demo),
        'mrr', coalesce((select sum(price) from public.subscriptions where status in ('active','cancel_requested','cancelling') and not is_demo), 0),
        'revenue', coalesce((select sum(amount) from public.payments where kind = 'subscription' and not is_demo and (paid_at at time zone tz)::date between p_from and p_to), 0),
        'cancelled', (select count(*) from public.subscriptions where status = 'cancelled' and not is_demo),
        'by_plan', coalesce((select jsonb_object_agg(name, t) from (select p.name, count(*) t from public.subscriptions s join public.plans p on p.id = s.plan_id
            where s.status in ('active','past_due','cancel_requested','cancelling') and not s.is_demo group by p.name) x), '{}'::jsonb)));
  return r || jsonb_build_object('profit', (r ->> 'revenue')::numeric - (r ->> 'expenses')::numeric);
end $$;

create or replace function public.report_series(p_from date, p_to date, p_unit text default 'day')
returns table(period date, revenue numeric, expenses numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_step interval := case when p_unit = 'month' then interval '1 month' else interval '1 day' end; tz text := 'America/Recife';
begin
  perform public._require_admin();
  return query
  select d::date,
    coalesce((select sum(p.amount) from public.payments p where not p.is_demo and (p.paid_at at time zone tz)::date >= d::date and (p.paid_at at time zone tz)::date < (d + v_step)::date), 0),
    coalesce((select sum(e.amount) from public.expenses e where not e.is_demo and e.status = 'paid' and (e.paid_at at time zone tz)::date >= d::date and (e.paid_at at time zone tz)::date < (d + v_step)::date), 0)
  from generate_series(p_from::timestamp, p_to::timestamp, v_step) d;
end $$;

create or replace function public.admin_customer_stats(p_service uuid default null)
returns table(customer_id uuid, full_name text, whatsapp text, created_at timestamptz, last_visit date, visits int, spent numeric, has_plan boolean, marketing_opt_in boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.full_name, c.whatsapp, c.created_at,
         max((a.start_at at time zone 'America/Recife')::date) filter (where a.status = 'completed'),
         (count(a.id) filter (where a.status = 'completed'))::int,
         coalesce(sum(a.final_total) filter (where a.status = 'completed'), 0),
         exists (select 1 from public.subscriptions s where s.customer_id = c.id and s.status in ('active','past_due','cancel_requested','cancelling','suspended')),
         c.marketing_opt_in
  from public.customers c left join public.appointments a on a.customer_id = c.id
  where public.is_admin() and not c.is_demo and c.is_active
    and (p_service is null or exists (select 1 from public.appointment_items i join public.appointments a2 on a2.id = i.appointment_id
                                      where a2.customer_id = c.id and a2.status = 'completed' and i.service_id = p_service))
  group by c.id
$$;

-- ============================================================
-- DADOS DE DEMONSTRACAO (marcados como DEMO e fora de todos os relatorios)
-- ============================================================
create or replace function public.demo_counts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return jsonb_build_object(
    'clientes', (select count(*) from public.customers where is_demo),
    'agendamentos', (select count(*) from public.appointments where is_demo),
    'pagamentos', (select count(*) from public.payments where is_demo),
    'vendas', (select count(*) from public.sales where is_demo),
    'produtos', (select count(*) from public.products where is_demo),
    'despesas', (select count(*) from public.expenses where is_demo));
end $$;

create or replace function public.demo_seed() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_barber uuid; v_corte uuid; v_barba uuid; v_c uuid; v_a uuid; i int; v_start timestamptz; v_amt numeric; v_prod uuid; v_sale uuid;
begin
  perform public._require_admin();
  if exists (select 1 from public.customers where is_demo) then raise exception 'Os dados de demonstração já foram criados. Remova-os antes de criar de novo.'; end if;
  select id into v_barber from public.barbers where is_active order by created_at limit 1;
  select id into v_corte from public.services where is_cut limit 1;
  select id into v_barba from public.services where name = 'Barba' limit 1;
  for i in 1..5 loop
    insert into public.customers (full_name, whatsapp, is_demo) values ('Cliente DEMO ' || i, '8190000000' || i, true);
  end loop;
  for i in 1..12 loop
    select id into v_c from public.customers where is_demo order by full_name offset ((i - 1) % 5) limit 1;
    v_start := (((public._today() - i)::timestamp + time '10:00') at time zone 'America/Recife') + ((i % 4) * interval '1 hour');
    insert into public.appointments (barber_id, customer_id, guest_name, guest_whatsapp, start_at, end_at, status, source, estimated_total, final_total, is_demo)
    select v_barber, v_c, c.full_name, c.whatsapp, v_start, v_start + interval '30 minutes', 'completed', 'admin', 25, 25, true from public.customers c where c.id = v_c
    returning id into v_a;
    perform public._add_items(v_a, array[v_corte]);
    update public.appointment_items set price_final = 25 where appointment_id = v_a;
    insert into public.payments (appointment_id, customer_id, amount, method, kind, paid_at, is_demo)
    values (v_a, v_c, 25, (array['pix','cash','debit','credit'])[1 + (i % 4)], 'service', v_start + interval '30 minutes', true);
  end loop;
  insert into public.products (name, price, cost, quantity, low_stock_limit, is_demo) values ('Pomada DEMO', 30, 15, 10, 2, true) returning id into v_prod;
  insert into public.sales (customer_id, subtotal, total, method, is_demo) values (v_c, 30, 30, 'pix', true) returning id into v_sale;
  insert into public.sale_items (sale_id, kind, product_id, name, qty, unit_price_original, unit_price_final, unit_cost) values (v_sale, 'product', v_prod, 'Pomada DEMO', 1, 30, 30, 15);
  insert into public.payments (customer_id, amount, method, kind, sale_id, is_demo) values (v_c, 30, 'pix', 'product', v_sale, true);
  insert into public.expenses (description, amount, due_date, paid_at, status, method, is_demo, category_id)
  values ('Aluguel DEMO', 600, public._today() - 5, now() - interval '5 days', 'paid', 'pix', true, (select id from public.expense_categories where name = 'Aluguel')),
         ('Energia DEMO', 120, public._today() - 3, now() - interval '3 days', 'paid', 'pix', true, (select id from public.expense_categories where name = 'Energia'));
  return public.demo_counts();
end $$;

create or replace function public.demo_clear(p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  perform public._require_admin();
  if p_confirm is distinct from 'REMOVER DEMO' then raise exception 'Digite exatamente REMOVER DEMO para confirmar.'; end if;
  r := public.demo_counts();
  delete from public.payments where is_demo;
  delete from public.coupon_redemptions where sale_id in (select id from public.sales where is_demo);
  delete from public.sales where is_demo;
  delete from public.appointments where is_demo;
  delete from public.subscriptions where is_demo;
  delete from public.customers where is_demo;
  delete from public.expenses where is_demo;
  delete from public.products where is_demo;
  delete from public.gallery_items where is_demo;
  delete from public.notifications where is_demo;
  return r;
end $$;

-- ============================================================
-- SEGURANCA (RLS) DAS TABELAS NOVAS
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['cash_sessions','cash_movements','expense_categories','expenses','product_categories','products','stock_movements',
    'kits','kit_items','coupons','coupon_redemptions','sales','sale_items','plan_versions','subscriptions','subscription_items','subscription_cycles',
    'subscription_credits','credit_transactions','tasks','goals','campaigns','campaign_recipients','privacy_requests']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_admin', t);
    execute format('create policy %I on public.%I for all using (public.is_admin()) with check (public.is_admin())', t || '_admin', t);
  end loop;
end $$;

-- cliente pode ver as proprias solicitacoes de privacidade
drop policy if exists privacy_own on public.privacy_requests;
create policy privacy_own on public.privacy_requests for select using (profile_id = auth.uid());

-- planos: publicos para leitura (apenas ativos)
alter table public.plans enable row level security;
alter table public.plan_items enable row level security;
drop policy if exists plans_read on public.plans;
create policy plans_read on public.plans for select using (is_active or public.is_admin());
drop policy if exists plans_admin on public.plans;
create policy plans_admin on public.plans for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists plan_items_read on public.plan_items;
create policy plan_items_read on public.plan_items for select using (true);
drop policy if exists plan_items_admin on public.plan_items;
create policy plan_items_admin on public.plan_items for all using (public.is_admin()) with check (public.is_admin());

-- conteudo publico
alter table public.gallery_items enable row level security;
alter table public.announcements enable row level security;
alter table public.faq_items enable row level security;
alter table public.reviews enable row level security;
drop policy if exists gallery_read on public.gallery_items;
create policy gallery_read on public.gallery_items for select using ((is_visible and not is_demo and published_at <= now()) or public.is_admin());
drop policy if exists gallery_admin on public.gallery_items;
create policy gallery_admin on public.gallery_items for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists news_read on public.announcements;
create policy news_read on public.announcements for select using ((status = 'published' and published_at <= now() and (expires_at is null or expires_at > now())) or public.is_admin());
drop policy if exists news_admin on public.announcements;
create policy news_admin on public.announcements for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists faq_read on public.faq_items;
create policy faq_read on public.faq_items for select using (is_active or public.is_admin());
drop policy if exists faq_admin on public.faq_items;
create policy faq_admin on public.faq_items for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists reviews_own on public.reviews;
create policy reviews_own on public.reviews for select using (profile_id = auth.uid() or public.is_admin());
drop policy if exists reviews_admin on public.reviews;
create policy reviews_admin on public.reviews for all using (public.is_admin()) with check (public.is_admin());

-- historico de alteracoes (preco, planos, estoque, caixa, pagamentos...)
do $$
declare t text;
begin
  foreach t in array array['plans','plan_items','subscriptions','products','cash_sessions','expenses','coupons','sales','kits']
  loop
    execute format('drop trigger if exists %I on public.%I', 'trg_audit_' || t, t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_row()', 'trg_audit_' || t, t);
  end loop;
end $$;

-- ============================================================
-- ARMAZENAMENTO DE IMAGENS (bucket "media", publico para leitura, so admin envia)
-- ============================================================
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('media', 'media', true, 1048576, array['image/webp','image/jpeg','image/png'])
  on conflict (id) do update set public = true, file_size_limit = 1048576;
  drop policy if exists media_read on storage.objects;
  create policy media_read on storage.objects for select using (bucket_id = 'media');
  drop policy if exists media_insert on storage.objects;
  create policy media_insert on storage.objects for insert with check (bucket_id = 'media' and public.is_admin());
  drop policy if exists media_update on storage.objects;
  create policy media_update on storage.objects for update using (bucket_id = 'media' and public.is_admin());
  drop policy if exists media_delete on storage.objects;
  create policy media_delete on storage.objects for delete using (bucket_id = 'media' and public.is_admin());
exception when others then
  raise notice 'AVISO: nao foi possivel configurar o armazenamento de imagens (%). Envio de fotos pelo painel ficara desativado.', sqlerrm;
end $$;

-- ============================================================
-- CONTEUDO INICIAL (somente o que consta no documento / fotos enviadas)
-- ============================================================
insert into public.faq_items (question, answer, sort_order)
select * from (values
 ('Como agendo um horário?', 'Na página Agendar, escolha um ou mais serviços, o dia e um horário livre, informe nome e WhatsApp e confirme. Não precisa de conta.', 1),
 ('Quais são os horários de funcionamento?', 'Terça a quinta, das 10:00 às 19:00. Sexta e sábado, das 10:00 às 20:00. Domingo e segunda a barbearia fica fechada. Há um intervalo fixo das 13:30 às 15:00 nos dias de funcionamento.', 2),
 ('Posso cancelar meu agendamento?', 'Sim, sozinho pelo site até 2 horas antes do horário. Depois disso, fale com a barbearia pelo WhatsApp.', 3),
 ('Posso remarcar?', 'Sim, a qualquer momento, inclusive dentro das 2 horas, desde que exista outro horário livre. O horário antigo é liberado no mesmo instante em que o novo é reservado.', 4),
 ('E se eu me atrasar?', 'Há tolerância de 15 minutos. Passando disso, o Charley decide se atende, se remarca ou se cancela. Nada é cancelado automaticamente.', 5),
 ('Posso marcar mais de um serviço no mesmo horário?', 'Sim. O site soma a duração e o valor e mostra o horário previsto de término.', 6),
 ('Por que alguns preços aparecem como “a partir de”?', 'Progressiva, luzes e platinado dependem do cabelo. O Charley avalia pessoalmente e informa o valor final. Luzes + corte e platinado + corte já incluem o corte.', 7),
 ('Como posso pagar?', 'O pagamento é feito na barbearia, em Pix, dinheiro, débito ou crédito.', 8),
 ('Preciso ter conta para agendar?', 'Não. Com conta você acompanha histórico, notificações, lista de espera, assinatura e avaliações; sem conta, basta nome e WhatsApp.', 9),
 ('Como funciona a lista de espera?', 'Se não houver horário, entre na fila na sua conta. Quando uma vaga abrir, o primeiro da fila é avisado e tem 15 minutos para aceitar; se não aceitar, o convite passa ao próximo.', 10),
 ('Como funcionam os planos mensais?', 'Você solicita o plano no site e o Charley ativa após receber o pagamento. O ciclo dura 30 dias e os créditos não usados expiram no fim do ciclo.', 11)
) as v(q, a, o) where not exists (select 1 from public.faq_items);

insert into public.gallery_items (title, category, image_url)
select * from (values
 ('Degradê com topete', 'degradê', 'img/galeria/corte-01.webp'),
 ('Freestyle na nuca', 'freestyle', 'img/galeria/corte-02.webp'),
 ('Corte e barba', 'barba', 'img/galeria/corte-barba-01.webp')
) as v(t, c, u) where not exists (select 1 from public.gallery_items);
