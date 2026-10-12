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


-- Migración para interacción entre usuarios y banners

-- Discord Local: migración para servidores compartidos, mensajes en tiempo real,
-- mensajes directos, banners de perfil y permisos de Storage.
-- Ejecutar completo en Supabase > SQL Editor > New query usando el proyecto correcto.

-- 1) Banners personales (compatible con la tabla profiles ya existente).
alter table public.profiles add column if not exists banner_url text;
alter table public.profiles add column if not exists avatar_decoration jsonb;

-- 2) Servidores compartidos.
create table if not exists public.app_servers (
  id text primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 70),
  description text not null default '' check (char_length(description) <= 300),
  color text not null default '#5865f2',
  icon_url text,
  banner_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.app_server_members (
  server_id text not null references public.app_servers(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member')),
  joined_at timestamptz not null default now(),
  primary key (server_id, user_id)
);

create table if not exists public.app_channels (
  id text primary key,
  server_id text not null references public.app_servers(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 70),
  type text not null default 'text' check (type in ('text','voice','forum')),
  category text not null default 'canales de texto',
  topic text not null default '',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  unique (server_id, name)
);
create index if not exists app_channels_server_position_idx on public.app_channels(server_id, position);

-- Helpers SECURITY DEFINER evitan la recursión de políticas RLS entre servidores y miembros.
create or replace function public.app_is_server_member(p_server_id text)
returns boolean language sql stable security definer set search_path = public, auth
as $$ select exists (select 1 from public.app_server_members m where m.server_id = p_server_id and m.user_id = auth.uid()); $$;

create or replace function public.app_is_server_admin(p_server_id text)
returns boolean language sql stable security definer set search_path = public, auth
as $$ select exists (select 1 from public.app_server_members m where m.server_id = p_server_id and m.user_id = auth.uid() and m.role in ('owner','admin')); $$;

create or replace function public.app_is_server_owner(p_server_id text)
returns boolean language sql stable security definer set search_path = public, auth
as $$ select exists (select 1 from public.app_servers s where s.id = p_server_id and s.owner_id = auth.uid()); $$;

create table if not exists public.app_server_invites (
  code text primary key,
  server_id text not null references public.app_servers(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),
  max_uses integer,
  use_count integer not null default 0
);
create index if not exists app_server_invites_server_idx on public.app_server_invites(server_id);

-- 3) Mensajes privados compartidos entre dos cuentas.
create table if not exists public.app_conversations (
  id text primary key,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.app_conversation_members (
  conversation_id text not null references public.app_conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create or replace function public.app_is_conversation_member(p_conversation_id text)
returns boolean language sql stable security definer set search_path = public, auth
as $$ select exists (select 1 from public.app_conversation_members m where m.conversation_id = p_conversation_id and m.user_id = auth.uid()); $$;

create or replace function public.get_or_create_direct_conversation(p_other_user uuid)
returns text language plpgsql security definer set search_path = public, auth
as $$
declare
  conversation_key text;
  caller uuid := auth.uid();
begin
  if caller is null then raise exception 'Debes iniciar sesión.' using errcode = '42501'; end if;
  if p_other_user is null or p_other_user = caller then raise exception 'El destinatario no es válido.' using errcode = '22023'; end if;
  if not exists (select 1 from auth.users u where u.id = p_other_user) then raise exception 'No existe esa cuenta.' using errcode = '22023'; end if;
  conversation_key := 'dm:' || least(caller::text, p_other_user::text) || ':' || greatest(caller::text, p_other_user::text);
  insert into public.app_conversations(id, created_by) values (conversation_key, caller) on conflict (id) do nothing;
  insert into public.app_conversation_members(conversation_id, user_id) values (conversation_key, caller) on conflict do nothing;
  insert into public.app_conversation_members(conversation_id, user_id) values (conversation_key, p_other_user) on conflict do nothing;
  return conversation_key;
end;
$$;

-- 4) Mensajes de canales y mensajes directos. Adjuntos y multimedia apuntan a Storage.
create table if not exists public.app_messages (
  id text primary key,
  server_id text references public.app_servers(id) on delete cascade,
  channel_id text references public.app_channels(id) on delete cascade,
  conversation_id text references public.app_conversations(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  content text not null default '',
  image_url text,
  attachment jsonb,
  poll jsonb,
  reply_to jsonb,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz,
  constraint app_messages_target_check check (
    (server_id is not null and channel_id is not null and conversation_id is null)
    or (server_id is null and channel_id is null and conversation_id is not null)
  )
);
create index if not exists app_messages_channel_created_idx on public.app_messages(channel_id, created_at);
create index if not exists app_messages_conversation_created_idx on public.app_messages(conversation_id, created_at);
create index if not exists app_messages_author_idx on public.app_messages(author_id, created_at);

-- 5) RLS y permisos. Las cuentas solo acceden a servidores/conversaciones de los que son miembros.
alter table public.app_servers enable row level security;
alter table public.app_server_members enable row level security;
alter table public.app_channels enable row level security;
alter table public.app_server_invites enable row level security;
alter table public.app_conversations enable row level security;
alter table public.app_conversation_members enable row level security;
alter table public.app_messages enable row level security;

grant select, insert, update, delete on public.app_servers to authenticated;
grant select, insert, update, delete on public.app_server_members to authenticated;
grant select, insert, update, delete on public.app_channels to authenticated;
grant select, insert, update, delete on public.app_conversations to authenticated;
grant select, insert, update, delete on public.app_conversation_members to authenticated;
grant select, insert, update, delete on public.app_messages to authenticated;
grant select, insert, update, delete on public.app_server_invites to authenticated;

drop policy if exists app_servers_select_member on public.app_servers;
create policy app_servers_select_member on public.app_servers for select to authenticated using (public.app_is_server_member(id));
drop policy if exists app_servers_insert_owner on public.app_servers;
create policy app_servers_insert_owner on public.app_servers for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists app_servers_update_owner on public.app_servers;
create policy app_servers_update_owner on public.app_servers for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists app_servers_delete_owner on public.app_servers;
create policy app_servers_delete_owner on public.app_servers for delete to authenticated using (owner_id = auth.uid());

drop policy if exists app_server_members_select_self_or_member on public.app_server_members;
create policy app_server_members_select_self_or_member on public.app_server_members for select to authenticated using (user_id = auth.uid() or public.app_is_server_member(server_id));
drop policy if exists app_server_members_insert_owner_self on public.app_server_members;
create policy app_server_members_insert_owner_self on public.app_server_members for insert to authenticated with check (user_id = auth.uid() and role = 'owner' and public.app_is_server_owner(server_id));
drop policy if exists app_server_members_update_admin on public.app_server_members;
create policy app_server_members_update_admin on public.app_server_members for update to authenticated using (public.app_is_server_admin(server_id)) with check (public.app_is_server_admin(server_id));
drop policy if exists app_server_members_delete_admin_or_self on public.app_server_members;
create policy app_server_members_delete_admin_or_self on public.app_server_members for delete to authenticated using (user_id = auth.uid() or public.app_is_server_admin(server_id));

drop policy if exists app_channels_select_member on public.app_channels;
create policy app_channels_select_member on public.app_channels for select to authenticated using (public.app_is_server_member(server_id));
drop policy if exists app_channels_insert_admin on public.app_channels;
create policy app_channels_insert_admin on public.app_channels for insert to authenticated with check (public.app_is_server_admin(server_id));
drop policy if exists app_channels_update_admin on public.app_channels;
create policy app_channels_update_admin on public.app_channels for update to authenticated using (public.app_is_server_admin(server_id)) with check (public.app_is_server_admin(server_id));
drop policy if exists app_channels_delete_admin on public.app_channels;
create policy app_channels_delete_admin on public.app_channels for delete to authenticated using (public.app_is_server_admin(server_id));

-- Los códigos de invitación solo se crean/consumen mediante las funciones controladas de abajo.
drop policy if exists app_server_invites_no_direct_access on public.app_server_invites;
create policy app_server_invites_no_direct_access on public.app_server_invites for select to authenticated using (false);
drop policy if exists app_server_invites_no_insert on public.app_server_invites;
create policy app_server_invites_no_insert on public.app_server_invites for insert to authenticated with check (false);
drop policy if exists app_server_invites_no_update on public.app_server_invites;
create policy app_server_invites_no_update on public.app_server_invites for update to authenticated using (false) with check (false);
drop policy if exists app_server_invites_no_delete on public.app_server_invites;
create policy app_server_invites_no_delete on public.app_server_invites for delete to authenticated using (false);

-- Debe poder leerse la lista de miembros propios y sus conversaciones.
drop policy if exists app_conversations_select_member on public.app_conversations;
create policy app_conversations_select_member on public.app_conversations for select to authenticated using (public.app_is_conversation_member(id));
drop policy if exists app_conversations_insert_member on public.app_conversations;
create policy app_conversations_insert_member on public.app_conversations for insert to authenticated with check (created_by = auth.uid());
drop policy if exists app_conversations_update_creator on public.app_conversations;
create policy app_conversations_update_creator on public.app_conversations for update to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid());
drop policy if exists app_conversations_delete_creator on public.app_conversations;
create policy app_conversations_delete_creator on public.app_conversations for delete to authenticated using (created_by = auth.uid());

drop policy if exists app_conversation_members_select_member on public.app_conversation_members;
create policy app_conversation_members_select_member on public.app_conversation_members for select to authenticated using (user_id = auth.uid() or public.app_is_conversation_member(conversation_id));
drop policy if exists app_conversation_members_insert_self on public.app_conversation_members;
create policy app_conversation_members_insert_self on public.app_conversation_members for insert to authenticated with check (user_id = auth.uid() and public.app_is_conversation_member(conversation_id));
drop policy if exists app_conversation_members_delete_self on public.app_conversation_members;
create policy app_conversation_members_delete_self on public.app_conversation_members for delete to authenticated using (user_id = auth.uid());

drop policy if exists app_messages_select_member on public.app_messages;
create policy app_messages_select_member on public.app_messages for select to authenticated using (
  (server_id is not null and public.app_is_server_member(server_id))
  or (conversation_id is not null and public.app_is_conversation_member(conversation_id))
);
drop policy if exists app_messages_insert_member_author on public.app_messages;
create policy app_messages_insert_member_author on public.app_messages for insert to authenticated with check (
  author_id = auth.uid() and (
    (server_id is not null and channel_id is not null and public.app_is_server_member(server_id)
      and exists (select 1 from public.app_channels c where c.id = channel_id and c.server_id = app_messages.server_id))
    or (conversation_id is not null and public.app_is_conversation_member(conversation_id))
  )
);
drop policy if exists app_messages_update_own on public.app_messages;
create policy app_messages_update_own on public.app_messages for update to authenticated using (author_id = auth.uid()) with check (
  author_id = auth.uid() and (
    (server_id is not null and channel_id is not null and public.app_is_server_member(server_id))
    or (conversation_id is not null and public.app_is_conversation_member(conversation_id))
  )
);
drop policy if exists app_messages_delete_own on public.app_messages;
create policy app_messages_delete_own on public.app_messages for delete to authenticated using (author_id = auth.uid());

-- Crear invitación segura para un servidor que se administra.
create or replace function public.create_discord_server_invite(p_server_id text)
returns text language plpgsql security definer set search_path = public, auth
as $$
declare token text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.' using errcode = '42501'; end if;
  if not public.app_is_server_admin(p_server_id) then raise exception 'Solo un administrador del servidor puede crear invitaciones.' using errcode = '42501'; end if;
  token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.app_server_invites(code, server_id, created_by) values (token, p_server_id, auth.uid());
  return token;
end;
$$;

-- Aceptar invitación. La operación de alta se ejecuta dentro de una función controlada.
create or replace function public.join_discord_server(p_code text)
returns text language plpgsql security definer set search_path = public, auth
as $$
declare invited public.app_server_invites%rowtype;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.' using errcode = '42501'; end if;
  select * into invited from public.app_server_invites i where i.code = p_code and i.expires_at > now() and (i.max_uses is null or i.use_count < i.max_uses) for update;
  if not found then raise exception 'Invitación inexistente, vencida o agotada.' using errcode = '22023'; end if;
  insert into public.app_server_members(server_id, user_id, role) values (invited.server_id, auth.uid(), 'member') on conflict (server_id, user_id) do nothing;
  update public.app_server_invites set use_count = use_count + 1 where code = p_code;
  return invited.server_id;
end;
$$;

-- Votos colaborativos: se modifica la encuesta dentro de una transacción y solo
-- miembros autorizados del canal o MD pueden votar. Bloquear la fila evita perder
-- votos cuando dos personas votan casi al mismo tiempo.
create or replace function public.cast_discord_poll_vote(p_message_id text, p_option_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  msg public.app_messages%rowtype;
  caller text := auth.uid()::text;
  selected_before boolean := false;
  new_options jsonb;
  multi_choice boolean := false;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para votar.' using errcode = '42501';
  end if;

  select * into msg
  from public.app_messages
  where id = p_message_id
  for update;

  if not found then
    raise exception 'No se encontró el mensaje de la encuesta.' using errcode = 'P0002';
  end if;

  if msg.poll is null or jsonb_typeof(msg.poll->'options') <> 'array' then
    raise exception 'Este mensaje no contiene una encuesta válida.' using errcode = '22023';
  end if;

  if msg.server_id is not null then
    if not public.app_is_server_member(msg.server_id) then
      raise exception 'No eres miembro de este servidor.' using errcode = '42501';
    end if;
  elsif msg.conversation_id is not null then
    if not public.app_is_conversation_member(msg.conversation_id) then
      raise exception 'No perteneces a esta conversación.' using errcode = '42501';
    end if;
  else
    raise exception 'La encuesta no pertenece a un canal ni a un mensaje directo.' using errcode = '22023';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(msg.poll->'options') opt
    where opt->>'id' = p_option_id
  ) then
    raise exception 'La opción seleccionada no existe.' using errcode = '22023';
  end if;

  select coalesce((msg.poll->>'multi')::boolean, false) into multi_choice;
  select exists (
    select 1
    from jsonb_array_elements(msg.poll->'options') opt
    cross join lateral jsonb_array_elements_text(coalesce(opt->'votes', '[]'::jsonb)) voter(value)
    where opt->>'id' = p_option_id and voter.value = caller
  ) into selected_before;

  if multi_choice then
    select jsonb_agg(
      case when opt->>'id' = p_option_id then
        jsonb_set(
          opt,
          '{votes}',
          case when selected_before
            then coalesce(opt->'votes', '[]'::jsonb) - caller
            else coalesce(opt->'votes', '[]'::jsonb) || jsonb_build_array(caller)
          end,
          true
        )
      else opt end
      order by ordinal
    ) into new_options
    from jsonb_array_elements(msg.poll->'options') with ordinality row_data(opt, ordinal);
  elsif selected_before then
    -- Al pulsar otra vez la opción elegida, se quita el voto.
    select jsonb_agg(
      jsonb_set(opt, '{votes}', coalesce(opt->'votes', '[]'::jsonb) - caller, true)
      order by ordinal
    ) into new_options
    from jsonb_array_elements(msg.poll->'options') with ordinality row_data(opt, ordinal);
  else
    -- Voto único: primero quitar el usuario de todas las opciones y añadirlo a la elegida.
    select jsonb_agg(
      jsonb_set(
        opt,
        '{votes}',
        case when opt->>'id' = p_option_id
          then (coalesce(opt->'votes', '[]'::jsonb) - caller) || jsonb_build_array(caller)
          else coalesce(opt->'votes', '[]'::jsonb) - caller
        end,
        true
      )
      order by ordinal
    ) into new_options
    from jsonb_array_elements(msg.poll->'options') with ordinality row_data(opt, ordinal);
  end if;

  update public.app_messages
  set poll = jsonb_set(msg.poll, '{options}', coalesce(new_options, '[]'::jsonb), true)
  where id = p_message_id;

  return jsonb_set(msg.poll, '{options}', coalesce(new_options, '[]'::jsonb), true);
end;
$$;

revoke all on function public.create_discord_server_invite(text) from public;
revoke all on function public.join_discord_server(text) from public;
revoke all on function public.get_or_create_direct_conversation(uuid) from public;
revoke all on function public.cast_discord_poll_vote(text, text) from public;
grant execute on function public.create_discord_server_invite(text) to authenticated;
grant execute on function public.join_discord_server(text) to authenticated;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;
grant execute on function public.cast_discord_poll_vote(text, text) to authenticated;
revoke all on function public.app_is_server_member(text) from public;
revoke all on function public.app_is_server_admin(text) from public;
revoke all on function public.app_is_server_owner(text) from public;
revoke all on function public.app_is_conversation_member(text) from public;
grant execute on function public.app_is_server_member(text) to authenticated;
grant execute on function public.app_is_server_admin(text) to authenticated;
grant execute on function public.app_is_server_owner(text) to authenticated;
grant execute on function public.app_is_conversation_member(text) to authenticated;

-- Activar Realtime para mensajes, cambios del servidor y cambios de canales.
do $$
declare table_name text;
begin
  foreach table_name in array array['app_messages', 'app_servers', 'app_channels'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = table_name) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    end if;
  end loop;
exception when undefined_object then
  raise notice 'No se encontró supabase_realtime; activa Realtime en app_messages, app_servers y app_channels desde el dashboard.';
end $$;

-- El bucket discord-assets debe seguir siendo público para que los enlaces de imágenes
-- de perfiles, servidores y mensajes se puedan mostrar a todos los miembros del servidor.
insert into storage.buckets (id, name, public, file_size_limit)
values ('discord-assets', 'discord-assets', true, 26214400)
on conflict (id) do update set public = true, file_size_limit = 26214400;

-- Los usuarios solo pueden subir/borrar los archivos colocados en su propia carpeta de Storage.
drop policy if exists discord_assets_public_read on storage.objects;
create policy discord_assets_public_read on storage.objects for select to authenticated using (bucket_id = 'discord-assets');
drop policy if exists discord_assets_insert_own_folder on storage.objects;
create policy discord_assets_insert_own_folder on storage.objects for insert to authenticated with check (bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists discord_assets_update_own_folder on storage.objects;
create policy discord_assets_update_own_folder on storage.objects for update to authenticated using (bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text) with check (bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists discord_assets_delete_own_folder on storage.objects;
create policy discord_assets_delete_own_folder on storage.objects for delete to authenticated using (bucket_id = 'discord-assets' and (storage.foldername(name))[1] = auth.uid()::text);

-- End migration.
