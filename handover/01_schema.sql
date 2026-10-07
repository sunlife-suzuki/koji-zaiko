-- =====================================================================
-- koji-zaiko（資材在庫管理）スキーマ移管用 SQL  [01_schema.sql]
-- 新しい Supabase プロジェクトの SQL Editor でこのファイルを丸ごと実行してください。
-- 実行順: 01_schema.sql →（任意: 初期データSQL）→ 03_admin_bootstrap.sql
--   ※ 初期データ（資材・工番・入出庫）が必要な場合のみ、別途受け渡すデータSQLを間に実行。
--     不要なら空の状態から運用開始できます。
--
-- ★ 重要（必ず書き換える箇所）★
--   下の is_company_user() 内のメールドメインを、譲渡先の会社ドメインに変更してください。
--   例: '%@sunlife-corporation.jp'  →  '%@YOURCOMPANY.co.jp'
--   アプリ側 index.html の COMPANY_DOMAIN も同じ値に合わせる必要があります。
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) テーブル
-- ---------------------------------------------------------------------
create table if not exists public.items (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  unit          text,
  initial_stock numeric not null default 0,
  reorder_point numeric,
  location      text,
  note          text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  carryover     numeric not null default 0,
  category      text,
  unit_price    numeric
);

create table if not exists public.job_codes (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  department    text,
  kind          text,
  contract_date date,
  orderer       text,
  work_name     text,
  place         text,
  source        text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create table if not exists public.item_serials (
  id         uuid primary key default gen_random_uuid(),
  item_id    uuid not null references public.items(id) on delete cascade,
  serial     text not null unique,
  note       text,
  created_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id              uuid primary key default gen_random_uuid(),
  item_id         uuid not null references public.items(id),
  tx_date         date not null default current_date,
  tx_type         text not null,
  quantity        numeric not null,
  job_no          text,
  counterparty    text,
  person          text not null,
  note            text,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  attachment_path text,
  serials         text,
  is_test         boolean not null default false,
  unit_price      numeric,
  constraint transactions_tx_type_check
    check (tx_type = any (array['出庫','入庫','返却','処分','棚卸調整'])),
  constraint transactions_quantity_check
    check (
      ((tx_type = any (array['出庫','入庫','返却','処分'])) and quantity > 0)
      or (tx_type = '棚卸調整' and quantity <> 0)
    )
);

create table if not exists public.app_admins (
  email    text primary key,
  added_by text,
  added_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2) 権限判定ヘルパー関数
--    ★ is_company_user() のドメインを譲渡先会社のものに変更すること ★
-- ---------------------------------------------------------------------
create or replace function public.is_company_user()
 returns boolean
 language sql stable
 set search_path to 'public'
as $$
  select coalesce(auth.jwt() ->> 'email', '') like '%@sunlife-corporation.jp';
$$;

create or replace function public.is_admin()
 returns boolean
 language sql stable security definer
 set search_path to 'public'
as $$
  select public.is_company_user()
     and exists (
       select 1 from public.app_admins
       where lower(email) = lower(coalesce(auth.jwt() ->> 'email',''))
     );
$$;

-- ---------------------------------------------------------------------
-- 3) 業務用 RPC（SECURITY DEFINER）
-- ---------------------------------------------------------------------
create or replace function public.list_stock()
 returns table(id uuid, name text, unit text, category text, unit_price numeric, initial_stock numeric, reorder_point numeric, location text, note text, total_out numeric, total_in numeric, current_stock numeric)
 language plpgsql stable security definer
 set search_path to 'public'
as $$
begin
  if not public.is_company_user() then raise exception 'not authorized'; end if;
  return query
    select i.id, i.name, i.unit, i.category, i.unit_price, i.initial_stock, i.reorder_point, i.location, i.note,
      coalesce(sum(t.quantity) filter (where t.tx_type in ('出庫','処分')), 0)::numeric,
      coalesce(sum(t.quantity) filter (where t.tx_type in ('入庫','返却')), 0)::numeric,
      (i.initial_stock + i.carryover
        + coalesce(sum(t.quantity) filter (where t.tx_type in ('入庫','返却')), 0)
        - coalesce(sum(t.quantity) filter (where t.tx_type in ('出庫','処分')), 0)
        + coalesce(sum(t.quantity) filter (where t.tx_type = '棚卸調整'), 0))::numeric
    from public.items i
    left join public.transactions t on t.item_id = i.id
    where i.is_active = true
    group by i.id
    order by i.name;
end;
$$;

create or replace function public.list_job_nos()
 returns table(job_no text)
 language sql stable security definer
 set search_path to 'public'
as $$
  select s.job_no
  from (
    select t.job_no as job_no, max(t.created_at) as last_used
    from transactions t
    where t.job_no is not null and btrim(t.job_no) <> ''
    group by t.job_no
  ) s
  order by s.last_used desc
  limit 500;
$$;

create or replace function public.list_job_costs()
 returns table(job_no text, work_name text, out_qty numeric, ret_qty numeric, total_cost numeric, item_count bigint)
 language plpgsql stable security definer
 set search_path to 'public'
as $$
begin
  if not public.is_company_user() then raise exception 'not authorized'; end if;
  return query
    select t.job_no,
      (select jc.work_name from public.job_codes jc where jc.code = t.job_no limit 1),
      coalesce(sum(t.quantity) filter (where t.tx_type='出庫'),0)::numeric,
      coalesce(sum(t.quantity) filter (where t.tx_type='返却'),0)::numeric,
      coalesce(sum(case when t.tx_type='出庫' then t.quantity*coalesce(t.unit_price,0)
                        when t.tx_type='返却' then -t.quantity*coalesce(t.unit_price,0) else 0 end),0)::numeric,
      count(distinct t.item_id)
    from public.transactions t
    where t.job_no is not null and t.job_no <> ''
      and t.tx_type in ('出庫','返却')
    group by t.job_no
    order by t.job_no;
end;
$$;

create or replace function public.job_cost_detail(p_job text)
 returns table(name text, unit text, unit_price numeric, out_qty numeric, ret_qty numeric, net_qty numeric, amount numeric)
 language plpgsql stable security definer
 set search_path to 'public'
as $$
begin
  if not public.is_company_user() then raise exception 'not authorized'; end if;
  return query
    select i.name, i.unit, t.unit_price,
      coalesce(sum(t.quantity) filter (where t.tx_type='出庫'),0)::numeric,
      coalesce(sum(t.quantity) filter (where t.tx_type='返却'),0)::numeric,
      coalesce(sum(case when t.tx_type='出庫' then t.quantity when t.tx_type='返却' then -t.quantity else 0 end),0)::numeric,
      coalesce(sum(case when t.tx_type='出庫' then t.quantity*coalesce(t.unit_price,0)
                        when t.tx_type='返却' then -t.quantity*coalesce(t.unit_price,0) else 0 end),0)::numeric
    from public.transactions t join public.items i on i.id = t.item_id
    where t.job_no = p_job and t.tx_type in ('出庫','返却')
    group by i.name, i.unit, t.unit_price
    order by i.name, t.unit_price;
end;
$$;

create or replace function public.list_transactions(p_from date, p_to date)
 returns table(id uuid, tx_date date, tx_type text, item_name text, quantity numeric, unit text, job_no text, counterparty text, person text, note text, login_email text, attachment_path text, created_at timestamptz, serials text)
 language plpgsql stable security definer
 set search_path to 'public'
as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return query
    select t.id, t.tx_date, t.tx_type, i.name, t.quantity, i.unit,
           t.job_no, t.counterparty, t.person, t.note, u.email::text,
           t.attachment_path, t.created_at, t.serials
    from public.transactions t
    join public.items i on i.id = t.item_id
    left join auth.users u on u.id = t.created_by
    where t.tx_date >= p_from and t.tx_date <= p_to
    order by t.tx_date, t.created_at;
end;
$$;

create or replace function public.purge_old_transactions()
 returns integer
 language plpgsql security definer
 set search_path to 'public'
as $$
declare
  cutoff date := (current_date - interval '1 year')::date;
  deleted integer;
begin
  update public.items i set carryover = i.carryover + agg.net
  from (
    select item_id,
           sum(case when tx_type in ('入庫','返却') then quantity
                    when tx_type in ('出庫','処分') then -quantity
                    when tx_type = '棚卸調整' then quantity
                    else 0 end) as net
    from public.transactions where tx_date < cutoff group by item_id
  ) agg
  where agg.item_id = i.id;
  delete from public.transactions where tx_date < cutoff;
  get diagnostics deleted = row_count;
  return deleted;
end;
$$;

create or replace function public.prevent_last_admin_delete()
 returns trigger
 language plpgsql security definer
 set search_path to 'public'
as $$
begin
  if (select count(*) from public.app_admins) <= 1 then
    raise exception '最後の管理者は削除できません';
  end if;
  return old;
end;
$$;

drop trigger if exists trg_prevent_last_admin on public.app_admins;
create trigger trg_prevent_last_admin
  before delete on public.app_admins
  for each row execute function public.prevent_last_admin_delete();

-- ---------------------------------------------------------------------
-- 4) Row Level Security（RLS）とポリシー
-- ---------------------------------------------------------------------
alter table public.items        enable row level security;
alter table public.job_codes    enable row level security;
alter table public.item_serials enable row level security;
alter table public.transactions enable row level security;
alter table public.app_admins   enable row level security;

-- items: 社内ユーザは閲覧・追加・更新可
drop policy if exists items_select on public.items;
create policy items_select on public.items for select using (public.is_company_user());
drop policy if exists items_insert on public.items;
create policy items_insert on public.items for insert with check (public.is_company_user());
drop policy if exists items_update on public.items;
create policy items_update on public.items for update using (public.is_company_user()) with check (public.is_company_user());

-- job_codes: 社内ユーザは閲覧・全書込可（全員が編集できる仕様）
drop policy if exists jc_select on public.job_codes;
create policy jc_select on public.job_codes for select using (public.is_company_user());
drop policy if exists jc_write_all on public.job_codes;
create policy jc_write_all on public.job_codes for all using (public.is_company_user()) with check (public.is_company_user());

-- item_serials: 社内ユーザは閲覧、管理者は全操作
drop policy if exists is_select on public.item_serials;
create policy is_select on public.item_serials for select using (public.is_company_user());
drop policy if exists is_admin_all on public.item_serials;
create policy is_admin_all on public.item_serials for all using (public.is_admin()) with check (public.is_admin());

-- transactions: 管理者は全件閲覧、本人は自分の当日分のみ編集/削除
drop policy if exists tx_select on public.transactions;
create policy tx_select on public.transactions for select using (public.is_admin());
drop policy if exists tx_select_own on public.transactions;
create policy tx_select_own on public.transactions for select using (public.is_company_user() and (created_by = auth.uid()));
drop policy if exists tx_insert on public.transactions;
create policy tx_insert on public.transactions for insert with check (public.is_company_user());
drop policy if exists tx_update_own on public.transactions;
create policy tx_update_own on public.transactions for update
  using (created_by = auth.uid() and ((created_at at time zone 'Asia/Tokyo')::date = (now() at time zone 'Asia/Tokyo')::date))
  with check (created_by = auth.uid());
drop policy if exists tx_delete_own on public.transactions;
create policy tx_delete_own on public.transactions for delete
  using (created_by = auth.uid() and ((created_at at time zone 'Asia/Tokyo')::date = (now() at time zone 'Asia/Tokyo')::date));

-- app_admins: 管理者のみ閲覧・追加・削除
drop policy if exists admins_select on public.app_admins;
create policy admins_select on public.app_admins for select using (public.is_admin());
drop policy if exists admins_insert on public.app_admins;
create policy admins_insert on public.app_admins for insert with check (public.is_admin());
drop policy if exists admins_delete on public.app_admins;
create policy admins_delete on public.app_admins for delete using (public.is_admin());

-- ---------------------------------------------------------------------
-- 5) RPC 実行権限
-- ---------------------------------------------------------------------
grant execute on function public.is_company_user()           to anon, authenticated;
grant execute on function public.is_admin()                  to anon, authenticated;
grant execute on function public.list_stock()                to anon, authenticated;
grant execute on function public.list_job_nos()              to anon, authenticated;
grant execute on function public.list_job_costs()            to anon, authenticated;
grant execute on function public.job_cost_detail(text)       to anon, authenticated;
grant execute on function public.list_transactions(date,date) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6) Storage バケット（施工証明書などの添付用、非公開）とポリシー
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('certificates','certificates', false)
on conflict (id) do nothing;

drop policy if exists cert_select on storage.objects;
create policy cert_select on storage.objects for select to authenticated
  using (bucket_id = 'certificates' and public.is_company_user());
drop policy if exists cert_insert on storage.objects;
create policy cert_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'certificates' and public.is_company_user());

-- 完了。次は 02_data.sql を実行してください。
