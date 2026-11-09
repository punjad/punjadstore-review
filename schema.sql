-- Run this whole script in Supabase > SQL Editor.
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  display_name text not null check (char_length(display_name) between 1 and 40),
  customer_key text not null check (char_length(customer_key) between 1 and 80),
  rating int not null check (rating between 1 and 5),
  review_text text not null check (char_length(review_text) between 1 and 1000),
  image_url text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
create index if not exists reviews_status_created_idx on public.reviews(status, created_at desc);
create table if not exists public.customer_credits (
  customer_key text primary key,
  credits int not null default 0 check (credits >= 0),
  updated_at timestamptz not null default now()
);
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.reviews enable row level security;
alter table public.customer_credits enable row level security;
alter table public.admin_users enable row level security;

-- Public can submit reviews, but cannot choose an approved status.
drop policy if exists "public submit pending reviews" on public.reviews;
create policy "public submit pending reviews" on public.reviews for insert to anon, authenticated
with check (status = 'pending');
-- Only approved reviews are public.
drop policy if exists "public read approved reviews" on public.reviews;
create policy "public read approved reviews" on public.reviews for select to anon, authenticated
using (status = 'approved');
-- Admins can see and manage all reviews.
drop policy if exists "admins manage reviews" on public.reviews;
create policy "admins manage reviews" on public.reviews for all to authenticated
using (exists(select 1 from public.admin_users a where a.user_id = auth.uid()))
with check (exists(select 1 from public.admin_users a where a.user_id = auth.uid()));
-- Credits are never directly readable or writable from the client; use the limited RPC below.

create or replace function public.get_customer_credits(p_customer_key text)
returns integer language sql security definer set search_path = public
as $$ select coalesce((select credits from customer_credits where customer_key = lower(trim(p_customer_key))),0); $$;
grant execute on function public.get_customer_credits(text) to anon, authenticated;

create or replace function public.moderate_review(p_review_id uuid, p_new_status text)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.reviews%rowtype;
begin
  if not exists(select 1 from public.admin_users where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_new_status not in ('approved','rejected') then raise exception 'invalid status'; end if;
  select * into r from public.reviews where id = p_review_id for update;
  if not found then raise exception 'review not found'; end if;
  if r.status <> 'pending' then raise exception 'review already moderated'; end if;
  update public.reviews set status = p_new_status where id = p_review_id;
  if p_new_status = 'approved' then
    insert into public.customer_credits(customer_key, credits, updated_at)
    values(lower(trim(r.customer_key)),1,now())
    on conflict(customer_key) do update set credits = customer_credits.credits + 1, updated_at = now();
  end if;
end; $$;
grant execute on function public.moderate_review(uuid,text) to authenticated;

-- Create a public Storage bucket for optional review images.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('review-images','review-images',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
drop policy if exists "public upload review images" on storage.objects;
create policy "public upload review images" on storage.objects for insert to anon, authenticated
with check (bucket_id = 'review-images');
drop policy if exists "public view review images" on storage.objects;
create policy "public view review images" on storage.objects for select to anon, authenticated
using (bucket_id = 'review-images');

-- After creating your admin account in Supabase Authentication > Users,
-- replace THE-ADMIN-USER-UUID below with that user's UUID and run this line:
-- insert into public.admin_users(user_id) values ('THE-ADMIN-USER-UUID') on conflict do nothing;
