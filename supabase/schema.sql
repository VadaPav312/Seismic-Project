-- SEISMIC — Supabase schema.
--
-- Run this once, whole, in the Supabase dashboard: SQL Editor → New query →
-- paste → Run. It is idempotent, so running it twice is harmless.
--
-- Two tables and one storage policy. Everything is scoped to the signed-in
-- user by row-level security, which is enforced by the database rather than by
-- the app — the app ships with a public key and anyone can send whatever they
-- like to it, so client-side checks would be decoration.

-- ─────────────────────────────────────────────────────────────────────────────
--  sync_records — buildings, events, assessments and notes.
--
--  One row per record, the record itself in a jsonb column. These are only ever
--  fetched whole and by owner, so real columns would buy nothing and cost a
--  migration every time a Swift struct gains a property.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.sync_records (
    id          uuid        primary key,
    user_id     uuid        not null references auth.users (id) on delete cascade,
    kind        text        not null check (kind in ('building', 'event', 'assessment', 'note')),
    updated_at  timestamptz not null default now(),
    payload     jsonb       not null
);

create index if not exists sync_records_owner_idx on public.sync_records (user_id, kind);

alter table public.sync_records enable row level security;

-- Recreated rather than guarded: `create policy` has no `if not exists`, and a
-- half-applied policy is worse than one replaced cleanly.
drop policy if exists "own records" on public.sync_records;
create policy "own records" on public.sync_records
    for all to authenticated
    using      (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- ─────────────────────────────────────────────────────────────────────────────
--  community_tags — the shared map.
--
--  This one gets real columns because it is queried by bounding box and time.
--  A jsonb blob would mean dragging every tag in the world to the device to
--  find the ones on your street.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.community_tags (
    id                uuid        primary key,
    "buildingID"      uuid,
    verdict           text        not null,
    latitude          double precision not null,
    longitude         double precision not null,
    "buildingLabel"   text        not null default '',
    "postedAt"        timestamptz not null default now(),
    tier              text        not null default 'unverified',
    "evidenceSummary" text        not null default '',
    notes             text        not null default '',
    "agreementCount"  integer     not null default 0,
    "disputeCount"    integer     not null default 0,
    "photoCount"      integer     not null default 0,
    "expiresAt"       timestamptz not null,
    author_id         uuid        default auth.uid() references auth.users (id) on delete set null
);

-- The quoted mixed-case names are not a style choice: PostgREST matches column
-- names exactly, and the app encodes Swift property names as-is. Unquoted
-- identifiers would be folded to lowercase and every query would miss.

create index if not exists community_tags_area_idx
    on public.community_tags (latitude, longitude, "postedAt" desc);

alter table public.community_tags enable row level security;

-- Tags are readable by everyone, including signed-out users: a neighbour
-- checking whether the block is safe should not have to make an account first.
drop policy if exists "tags are public" on public.community_tags;
create policy "tags are public" on public.community_tags
    for select to anon, authenticated
    using ("expiresAt" > now());

-- Writing one requires an account, and you may only edit your own.
drop policy if exists "post own tags" on public.community_tags;
create policy "post own tags" on public.community_tags
    for insert to authenticated
    with check (auth.uid() = author_id);

drop policy if exists "amend own tags" on public.community_tags;
create policy "amend own tags" on public.community_tags
    for update to authenticated
    using (auth.uid() = author_id);

-- ─────────────────────────────────────────────────────────────────────────────
--  Storage — damage photographs.
--
--  The bucket must already exist and must be PRIVATE. These are photographs of
--  the inside of somebody's home, tied to a location; a public bucket makes
--  them world-readable to anyone who can guess a path.
--
--  The app writes to <user-id>/<photo-id>.jpg, and this policy is what makes
--  that prefix mean something.
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists "own folder" on storage.objects;
create policy "own folder" on storage.objects
    for all to authenticated
    using      (bucket_id = 'seismic' and (storage.foldername(name))[1] = auth.uid()::text)
    with check (bucket_id = 'seismic' and (storage.foldername(name))[1] = auth.uid()::text);
