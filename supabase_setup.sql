-- ==========================================
-- GrowthCircle Dashboard Supabase Schema Setup
-- Run this script in your Supabase SQL Editor
-- ==========================================

-- 1. Create Profiles Table (user settings, role, phone)
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  username text unique not null,
  phone text,
  role text check (role in ('admin', 'student')) not null default 'student',
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- 2. Create Members Table (tracked community members)
create table if not exists public.members (
  id uuid default gen_random_uuid() primary key,
  name text not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- 3. Create Daily Records Table (scores and notes)
create table if not exists public.records (
  id text primary key, -- Compounded as member_id_date (e.g. member-uuid_2026-07-15)
  member_id uuid references public.members(id) on delete cascade on update cascade not null,
  date date not null,
  task_score integer check (task_score between 0 and 5) default 0,
  task_text text,
  engagement integer check (engagement between 0 and 5) default 0,
  attendance integer check (attendance between 0 and 5) default 0,
  growth integer check (growth between 0 and 5) default 0,
  habit text,
  screen_time numeric default 0,
  att_level integer default 0,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- 4. Enable Row Level Security (RLS) on all tables
alter table public.profiles enable row level security;
alter table public.members enable row level security;
alter table public.records enable row level security;

-- 5. Set up RLS Policies

-- Drop existing policies to ensure idempotency
drop policy if exists "Allow public read of profiles" on public.profiles;
drop policy if exists "Allow users to update own profile" on public.profiles;

drop policy if exists "Allow authenticated read of members" on public.members;
drop policy if exists "Allow admin write of members" on public.members;
drop policy if exists "Allow admin and owner write of members" on public.members;

drop policy if exists "Allow authenticated read of records" on public.records;
drop policy if exists "Allow admin write of records" on public.records;
drop policy if exists "Allow admin and owner write of records" on public.records;

-- Profiles Policies
create policy "Allow public read of profiles" on public.profiles
  for select using (true);

create policy "Allow users to update own profile" on public.profiles
  for update using (auth.uid() = id);

-- Members Policies
create policy "Allow authenticated read of members" on public.members
  for select using (auth.role() = 'authenticated');

create policy "Allow admin and owner write of members" on public.members
  for all using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and (
        p.role = 'admin' or 
        lower(members.name) = lower(p.username)
      )
    )
  );

-- Records Policies
create policy "Allow authenticated read of records" on public.records
  for select using (auth.role() = 'authenticated');

create policy "Allow admin and owner write of records" on public.records
  for all using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and (
        p.role = 'admin' or 
        exists (
          select 1 from public.members m
          where m.id = records.member_id and lower(m.name) = lower(p.username)
        )
      )
    )
  );

-- 6. Trigger Function to automatically create a profile for new Auth users
create or replace function public.handle_new_user()
returns trigger as $$
declare
  username_val text;
  role_val text;
begin
  username_val := coalesce(new.raw_user_meta_data->>'username', 'user_' || substr(new.id::text, 1, 8));
  
  role_val := coalesce(
    new.raw_user_meta_data->>'role',
    case 
      when new.email = 'admin@growthcircle.com' or username_val = 'Growthcircle' then 'admin'::text
      else 'student'::text
    end
  );

  insert into public.profiles (id, username, phone, role)
  values (
    new.id,
    username_val,
    coalesce(new.raw_user_meta_data->>'phone', ''),
    role_val
  );

  -- Automatically register new students in the members table so they appear on the dashboard
  if role_val = 'student' then
    -- Check if admin manually created a member with this name. If so, link it by updating the ID.
    if exists (select 1 from public.members where lower(name) = lower(username_val)) then
      update public.members
      set id = new.id
      where lower(name) = lower(username_val);
    else
      insert into public.members (id, name)
      values (new.id, username_val)
      on conflict (id) do nothing;
    end if;
  end if;

  return new;
end;
$$ language plpgsql security definer;

-- Trigger execution setup
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- 7. Access Code verification & role update function (RPC)
create or replace function public.submit_access_code(input_code text)
returns text as $$
declare
  target_role text;
begin
  if input_code = 'admin@growthcircle' then
    target_role := 'admin';
  elsif input_code = 'student@growthcircle' then
    target_role := 'student';
  else
    return null;
  end if;

  -- Update the calling user's profile
  update public.profiles
  set role = target_role
  where id = auth.uid();

  -- Automatically add/re-link the member record after verifying the code
  if target_role = 'student' then
    -- Get username from profile
    declare
      u_name text;
    begin
      select username into u_name from public.profiles where id = auth.uid();
      if u_name is not null then
        if exists (select 1 from public.members where lower(name) = lower(u_name)) then
          update public.members
          set id = auth.uid()
          where lower(name) = lower(u_name);
        else
          insert into public.members (id, name)
          values (auth.uid(), u_name)
          on conflict (id) do nothing;
        end if;
      end if;
    end;
  end if;

  return target_role;
end;
$$ language plpgsql security definer;
