-- Ejecuta este archivo completo en Supabase > SQL Editor > New query.
-- Solo crea perfiles públicos básicos. No guarda contraseñas ni correos públicos.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (char_length(username) between 3 and 32),
  display_name text not null default 'Usuario' check (char_length(display_name) <= 60),
  bio text not null default '' check (char_length(bio) <= 1500),
  avatar_url text,
  status text not null default 'online'
    check (status in ('online', 'idle', 'dnd', 'offline')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Los nombres de usuario son únicos sin distinguir mayúsculas/minúsculas.
create unique index if not exists profiles_username_lower_unique
  on public.profiles (lower(username));

alter table public.profiles enable row level security;

grant select, insert, update on table public.profiles to authenticated;

-- Los usuarios autenticados pueden ver perfiles públicos, pero no sus correos.
drop policy if exists "profiles_select_authenticated" on public.profiles;
create policy "profiles_select_authenticated"
  on public.profiles for select to authenticated
  using (auth.uid() is not null);

-- Cada usuario solo puede crear o modificar la fila cuyo id es su propio auth.uid().
drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
  on public.profiles for insert to authenticated
  with check (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  chosen_username text;
  chosen_display_name text;
begin
  chosen_username := left(
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'username'), ''),
      'user_' || substr(new.id::text, 1, 8)
    ),
    32
  );

  -- Evita que dos cuentas nuevas intenten ocupar el mismo nombre.
  if exists (
    select 1 from public.profiles p
    where lower(p.username) = lower(chosen_username)
      and p.id <> new.id
  ) then
    chosen_username := left(chosen_username, 23) || '_' || substr(new.id::text, 1, 8);
  end if;

  chosen_display_name := left(
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
      chosen_username
    ),
    60
  );

  insert into public.profiles (id, username, display_name, bio, status)
  values (new.id, chosen_username, chosen_display_name, '', 'online')
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute procedure public.handle_new_auth_user();

create or replace function public.set_profile_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute procedure public.set_profile_updated_at();


-- Guardado persistente completo por cuenta. Incluye perfil extendido, servidores,
-- canales, mensajes, amigos, MD, ajustes, pestañas del perfil y configuraciones.
create table if not exists public.user_app_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  app_data jsonb not null default '{}'::jsonb,
  schema_version integer not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.user_app_data enable row level security;
grant select, insert, update, delete on table public.user_app_data to authenticated;
drop policy if exists "user_app_data_select_own" on public.user_app_data;
create policy "user_app_data_select_own" on public.user_app_data
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists "user_app_data_insert_own" on public.user_app_data;
create policy "user_app_data_insert_own" on public.user_app_data
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "user_app_data_update_own" on public.user_app_data;
create policy "user_app_data_update_own" on public.user_app_data
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "user_app_data_delete_own" on public.user_app_data;
create policy "user_app_data_delete_own" on public.user_app_data
  for delete to authenticated using (auth.uid() = user_id);

-- Bucket para guardar por separado avatares, decoraciones, adjuntos y recursos de servidores.
insert into storage.buckets (id, name, public, file_size_limit)
values ('discord-assets', 'discord-assets', true, 26214400)
on conflict (id) do update set public = true, file_size_limit = 26214400;

drop policy if exists "discord_assets_public_read" on storage.objects;
create policy "discord_assets_public_read" on storage.objects
  for select to authenticated using (bucket_id = 'discord-assets');
drop policy if exists "discord_assets_insert_own_folder" on storage.objects;
create policy "discord_assets_insert_own_folder" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists "discord_assets_update_own_folder" on storage.objects;
create policy "discord_assets_update_own_folder" on storage.objects
  for update to authenticated using (
    bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text
  ) with check (
    bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists "discord_assets_delete_own_folder" on storage.objects;
create policy "discord_assets_delete_own_folder" on storage.objects
  for delete to authenticated using (
    bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text
  );
