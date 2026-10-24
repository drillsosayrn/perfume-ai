
create schema if not exists majinor_private;
revoke all on schema majinor_private from public, anon, authenticated;
create table majinor_private.admins(user_id uuid primary key references auth.users(id) on delete cascade);
create table public.majinor_conversations(
 id uuid primary key, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), title text not null,
 keep boolean not null default false, deleted_at timestamptz);
create table majinor_private.sessions(id uuid primary key references public.majinor_conversations(id) on delete cascade, token text not null);
create table public.majinor_messages(
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.majinor_conversations(id) on delete cascade,
 role text not null check(role in ('user','model','error')), content text not null check(length(content)<=16000),
 created_at timestamptz not null default now());
create index on public.majinor_messages(conversation_id,created_at);
create table public.majinor_knowledge(
 id uuid primary key default gen_random_uuid(), title text not null check(length(title)<=200),
 content text not null check(length(content)<=8000), active boolean not null default false,
 created_at timestamptz not null default now());
alter table public.majinor_conversations enable row level security;
alter table public.majinor_messages enable row level security;
alter table public.majinor_knowledge enable row level security;
alter table majinor_private.admins enable row level security;
alter table majinor_private.sessions enable row level security;
create function majinor_private.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from majinor_private.admins where user_id=auth.uid())
$$;
revoke execute on function majinor_private.is_admin() from public,anon;
grant usage on schema majinor_private to authenticated;
grant execute on function majinor_private.is_admin() to authenticated;
revoke all on public.majinor_conversations,public.majinor_messages,public.majinor_knowledge from public,anon,authenticated;
grant select,update on public.majinor_conversations to authenticated;
grant select on public.majinor_messages to authenticated;
grant select,insert,update,delete on public.majinor_knowledge to authenticated;
create policy admin_read_conversations on public.majinor_conversations for select to authenticated using ((select majinor_private.is_admin()));
create policy admin_update_conversations on public.majinor_conversations for update to authenticated using ((select majinor_private.is_admin())) with check((select majinor_private.is_admin()));
create policy admin_read_messages on public.majinor_messages for select to authenticated using ((select majinor_private.is_admin()));
create policy admin_knowledge on public.majinor_knowledge for all to authenticated using ((select majinor_private.is_admin())) with check((select majinor_private.is_admin()));
create function public.majinor_admin_check() returns boolean language sql stable security invoker set search_path='' as $$
 select majinor_private.is_admin()
$$;
revoke execute on function public.majinor_admin_check() from public,anon;
grant execute on function public.majinor_admin_check() to authenticated;
create function public.majinor_record_turn(p_id uuid,p_token text,p_user text,p_reply text,p_error boolean default false)
returns boolean language plpgsql security definer set search_path='' as $$
declare old_token text; deleted timestamptz; n integer; ts timestamptz;
begin
 if p_token is null or length(p_token)<>64 or p_user is null or length(p_user)<1 or length(p_user)>2000 or p_reply is null or length(p_reply)>16000 then raise exception 'Invalid input'; end if;
 insert into public.majinor_conversations(id,title) values(p_id,left(p_user,120)) on conflict do nothing;
 insert into majinor_private.sessions(id,token) values(p_id,p_token) on conflict do nothing;
 select s.token,c.deleted_at into old_token,deleted from majinor_private.sessions s join public.majinor_conversations c on c.id=s.id where s.id=p_id for update of s;
 if old_token<>p_token or old_token is null then raise exception 'Session mismatch'; end if;
 if deleted is not null then return false; end if;
 select count(*) into n from public.majinor_messages where conversation_id=p_id;
 if n>=400 then return false; end if;
 ts := clock_timestamp();
 insert into public.majinor_messages(conversation_id,role,content,created_at) values(p_id,'user',p_user,ts),(p_id,case when p_error then 'error' else 'model' end,p_reply,ts+interval '1 microsecond');
 update public.majinor_conversations set updated_at=now() where id=p_id;
 return true;
end $$;
revoke execute on function public.majinor_record_turn(uuid,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.majinor_record_turn(uuid,text,text,text,boolean) to anon;
create function public.majinor_active_knowledge() returns table(title text,content text)
language sql stable security definer set search_path='' as $$
 select k.title,k.content from public.majinor_knowledge k where k.active=true order by k.created_at desc limit 30
$$;
revoke execute on function public.majinor_active_knowledge() from public,anon,authenticated;
grant execute on function public.majinor_active_knowledge() to anon;
