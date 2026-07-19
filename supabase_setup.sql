-- ==========================================
-- GrowthCircle Dashboard Supabase Schema Setup
-- Run this script in your Supabase SQL Editor
-- ==========================================

-- 0. Migration / Constraint Fixes for Existing Tables
do $$
begin
  -- Drop old check constraint first so we can update values without violating it
  alter table public.profiles drop constraint if exists profiles_role_check;
  
  -- Update role values from 'member' to 'student'
  update public.profiles set role = 'student' where role = 'member';
  
  -- Add the new check constraint and default
  alter table public.profiles add constraint profiles_role_check check (role in ('admin', 'student'));
  alter table public.profiles alter column role set default 'student';
exception
  when others then null; -- ignore if table doesn't exist yet
end $$;

do $$
begin
  -- Drop old records foreign key and add the new one with ON UPDATE CASCADE
  alter table public.records drop constraint if exists records_member_id_fkey;
  alter table public.records add constraint records_member_id_fkey foreign key (member_id) references public.members(id) on delete cascade on update cascade;
exception
  when others then null; -- ignore if table doesn't exist yet
end $$;

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

-- 3. Create Daily Records Table (7 checkboxed habits)
create table if not exists public.records (
  id text primary key, -- Compounded as member_id_date (e.g. member-uuid_2026-07-15)
  member_id uuid references public.members(id) on delete cascade on update cascade not null,
  date date not null,
  slept_at_1030 boolean default false not null,
  woke_up_5 boolean default false not null,
  time_blocked boolean default false not null,
  ate_frog boolean default false not null,
  physical_habit boolean default false not null,
  screen_time_target boolean default false not null,
  night_review boolean default false not null,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Idempotent column updates for existing tables
do $$
begin
  alter table public.records add column if not exists slept_at_1030 boolean default false not null;
  alter table public.records add column if not exists woke_up_5 boolean default false not null;
  alter table public.records add column if not exists time_blocked boolean default false not null;
  alter table public.records add column if not exists ate_frog boolean default false not null;
  alter table public.records add column if not exists physical_habit boolean default false not null;
  alter table public.records add column if not exists screen_time_target boolean default false not null;
  alter table public.records add column if not exists night_review boolean default false not null;

  -- Drop old columns if they exist
  alter table public.records drop column if exists task_score;
  alter table public.records drop column if exists task_text;
  alter table public.records drop column if exists engagement;
  alter table public.records drop column if exists attendance;
  alter table public.records drop column if exists growth;
  alter table public.records drop column if exists habit;
  alter table public.records drop column if exists screen_time;
  alter table public.records drop column if exists att_level;
exception
  when others then null;
end $$;

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
        members.id = auth.uid() or
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
        records.member_id = auth.uid() or
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

-- 8. Function for admins to create a new user with verified email and password
create or replace function public.admin_create_user(
  input_email text,
  input_password text,
  input_username text,
  input_phone text default ''
)
returns uuid as $$
declare
  new_user_id uuid;
begin
  -- Check if the calling user is an admin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Unauthorized: Only administrators can create new members.';
  end if;

  -- Validate inputs
  if input_email is null or input_email = '' then
    raise exception 'Email is required.';
  end if;
  if input_password is null or length(input_password) < 6 then
    raise exception 'Password must be at least 6 characters.';
  end if;
  if input_username is null or input_username = '' then
    raise exception 'Username is required.';
  end if;

  -- Check if user already exists in auth.users
  if exists (select 1 from auth.users where email = input_email) then
    raise exception 'A user with this email already exists.';
  end if;

  -- Generate new UUID
  new_user_id := gen_random_uuid();

  -- Insert into auth.users (email is automatically confirmed)
  -- We must explicitly set token columns to empty strings ('') instead of NULL,
  -- otherwise GoTrue / Supabase Auth will fail with a 500 "Database error querying schema"
  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    confirmation_token,
    recovery_token,
    email_change_token_new,
    email_change
  ) values (
    new_user_id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    input_email,
    crypt(input_password, gen_salt('bf')),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    json_build_object('username', input_username, 'phone', input_phone, 'role', 'student')::jsonb,
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

  -- Insert identity to enable email/password login
  insert into auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  ) values (
    new_user_id,
    new_user_id,
    format('{"sub": "%s", "email": "%s"}', new_user_id, input_email)::jsonb,
    'email',
    new_user_id,
    now(),
    now(),
    now()
  );

  return new_user_id;
end;
$$ language plpgsql security definer;

-- 9. Fix any existing users created with NULL tokens to prevent "Database error querying schema" 500 error
update auth.users
set confirmation_token = coalesce(confirmation_token, ''),
    recovery_token = coalesce(recovery_token, ''),
    email_change_token_new = coalesce(email_change_token_new, ''),
    email_change = coalesce(email_change, '')
where confirmation_token is null
   or recovery_token is null
   or email_change_token_new is null
   or email_change is null;

