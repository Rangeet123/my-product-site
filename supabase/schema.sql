-- Case Room: database setup for Supabase.
-- Paste this whole file into Supabase > SQL Editor and click Run. It is safe to run more than once.
--
-- Shape: each table holds one JSON document per row, keyed by the id the page generates.
-- Row Level Security decides who can read and write; the page's public "anon" key can do
-- nothing beyond what these rules allow.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default '' check (char_length(name) <= 40),
  created_at timestamptz not null default now()
);

create table if not exists public.cases (
  id text primary key check (char_length(id) <= 120),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  data jsonb not null check (pg_column_size(data) < 60000),
  created_at timestamptz not null default now()
);

create table if not exists public.replies (
  id text primary key check (char_length(id) <= 120),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  data jsonb not null check (pg_column_size(data) < 60000),
  created_at timestamptz not null default now()
);

create table if not exists public.solutions (
  id text primary key check (char_length(id) <= 200),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  data jsonb not null check (pg_column_size(data) < 200000),
  created_at timestamptz not null default now()
);

-- A person's private workspace for one case. Only they can read it.
create table if not exists public.work (
  id text primary key check (char_length(id) <= 200),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  data jsonb not null check (pg_column_size(data) < 200000),
  created_at timestamptz not null default now()
);

create table if not exists public.votes (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  item_id text not null check (char_length(item_id) <= 200),
  created_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

create table if not exists public.saved (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  case_id text not null check (char_length(case_id) <= 120),
  created_at timestamptz not null default now(),
  primary key (user_id, case_id)
);

alter table public.profiles  enable row level security;
alter table public.cases     enable row level security;
alter table public.replies   enable row level security;
alter table public.solutions enable row level security;
alter table public.work      enable row level security;
alter table public.votes     enable row level security;
alter table public.saved     enable row level security;

-- Profiles: signed-in people can see names; each person edits only their own.
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (true);
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated with check (id = (select auth.uid()));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Cases, replies, solutions: every signed-in person reads; each person writes only their own rows.
drop policy if exists cases_read on public.cases;
create policy cases_read on public.cases for select to authenticated using (true);
drop policy if exists cases_insert on public.cases;
create policy cases_insert on public.cases for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists cases_update on public.cases;
create policy cases_update on public.cases for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists cases_delete on public.cases;
create policy cases_delete on public.cases for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists replies_read on public.replies;
create policy replies_read on public.replies for select to authenticated using (true);
drop policy if exists replies_insert on public.replies;
create policy replies_insert on public.replies for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists replies_update on public.replies;
create policy replies_update on public.replies for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists replies_delete on public.replies;
create policy replies_delete on public.replies for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists solutions_read on public.solutions;
create policy solutions_read on public.solutions for select to authenticated using (true);
drop policy if exists solutions_insert on public.solutions;
create policy solutions_insert on public.solutions for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists solutions_update on public.solutions;
create policy solutions_update on public.solutions for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists solutions_delete on public.solutions;
create policy solutions_delete on public.solutions for delete to authenticated using (user_id = (select auth.uid()));

-- Work and saved cases: private to their owner.
drop policy if exists work_all on public.work;
create policy work_all on public.work for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists saved_all on public.saved;
create policy saved_all on public.saved for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Votes: everyone signed in can count them; each person adds or removes only their own.
drop policy if exists votes_read on public.votes;
create policy votes_read on public.votes for select to authenticated using (true);
drop policy if exists votes_insert on public.votes;
create policy votes_insert on public.votes for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists votes_delete on public.votes;
create policy votes_delete on public.votes for delete to authenticated using (user_id = (select auth.uid()));

grant select, insert, update, delete on public.profiles, public.cases, public.replies, public.solutions, public.work, public.votes, public.saved to authenticated;

-- AI usage: one row per person per day. People can read their own count; only the
-- bump_ai_usage() function can change it, and it only ever counts upwards.
create table if not exists public.ai_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  count integer not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage enable row level security;
drop policy if exists ai_usage_read on public.ai_usage;
create policy ai_usage_read on public.ai_usage for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.ai_usage from authenticated, anon;
grant select on public.ai_usage to authenticated;

create or replace function public.bump_ai_usage() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '28000'; end if;
  insert into public.ai_usage (user_id, day, count)
  values (auth.uid(), (now() at time zone 'Asia/Kolkata')::date, 1)
  on conflict (user_id, day) do update set count = public.ai_usage.count + 1
  returning count into n;
  return n;
end $$;
revoke all on function public.bump_ai_usage() from public, anon;
grant execute on function public.bump_ai_usage() to authenticated;

-- AI exchanges: what was sent to the model and what came back. Written only by the server
-- function using the secret key; a member can read their own rows and nobody else's.
create table if not exists public.ai_exchanges (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  mode text not null,
  case_title text not null default '',
  input text not null,
  output text not null,
  model text not null default '',
  created_at timestamptz not null default now()
);
alter table public.ai_exchanges enable row level security;
drop policy if exists ai_exchanges_read on public.ai_exchanges;
create policy ai_exchanges_read on public.ai_exchanges for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.ai_exchanges from authenticated, anon;
grant select on public.ai_exchanges to authenticated;
