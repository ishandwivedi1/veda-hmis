-- 053: WhatsApp Inbox -- see and answer patient replies.
--
-- Why (Ishan, 27 Sep / 5 Oct 2026): every WhatsApp the hospital sends goes
-- out through Meta's Cloud API on the family landline. Because that number
-- lives on the API, patient replies reach Meta's webhook and nowhere else --
-- nobody could see or answer them.
--
--  * whatsapp_messages: every message IN (patient -> hospital, written by
--    /api/whatsapp/webhook with the service key) and every free-text reply
--    OUT from the inbox screen. Template sends stay in whatsapp_logs exactly
--    as before; the thread view simply shows them alongside for context.
--  * ui_whatsapp_inbox: the inbox list in ONE call (read-only).
--  * whatsapp_open_thread: opening a chat in ONE call -- marks that number's
--    replies as read and returns the thread, templates sent to the number
--    and the matching patient(s).
--
-- Purely additive: new table, new functions, one new index on whatsapp_logs.

create table if not exists public.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  wa_message_id text unique,                 -- Meta's wamid (dedupes webhook retries)
  direction text not null check (direction in ('in', 'out')),
  mobile text not null,                      -- digits with country code, e.g. 919876543210
  contact_name text,                         -- the patient's WhatsApp profile name
  msg_type text not null default 'text',     -- text, image, audio, video, document, sticker, location, button, reaction ...
  body text,                                 -- text / caption / readable summary
  media_id text,                             -- Meta media id (opened via /api/whatsapp/media/[id])
  media_mime text,
  media_filename text,
  reply_to_wa_id text,                       -- the message this one replies to, if any
  status text,                               -- in: received | out: sent, delivered, read, failed
  error_message text,
  sent_by uuid references public.profiles(id),
  message_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  read_at timestamptz,                       -- when staff first opened an incoming message
  raw jsonb
);

create index if not exists idx_whatsapp_messages_mobile_time on public.whatsapp_messages (mobile, message_at desc);
create index if not exists idx_whatsapp_messages_time on public.whatsapp_messages (message_at desc);
create index if not exists idx_whatsapp_messages_unread on public.whatsapp_messages (mobile) where direction = 'in' and read_at is null;
create index if not exists idx_whatsapp_messages_sent_by on public.whatsapp_messages (sent_by);
create index if not exists idx_whatsapp_logs_mobile on public.whatsapp_logs (mobile_number, sent_at desc);

alter table public.whatsapp_messages enable row level security;
drop policy if exists whatsapp_messages_select on public.whatsapp_messages;
create policy whatsapp_messages_select on public.whatsapp_messages
  for select to authenticated using (true);
-- No insert/update policies on purpose: the webhook and the reply action
-- write with the service key; marking read goes through
-- whatsapp_open_thread below.

-- ── Inbox list (read-only) ────────────────────────────────────────────
create or replace function public.ui_whatsapp_inbox(p_search text default '', p_unread_only boolean default false)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with conv as (
    select mobile,
           max(message_at) as last_at,
           max(message_at) filter (where direction = 'in') as last_in_at,
           count(*) filter (where direction = 'in' and read_at is null) as unread
    from whatsapp_messages
    group by mobile
  ),
  rows as (
    select c.*,
           lm.direction as last_direction, lm.msg_type as last_type, lm.body as last_body,
           (select m2.contact_name from whatsapp_messages m2
             where m2.mobile = c.mobile and m2.contact_name is not null
             order by m2.message_at desc limit 1) as contact_name,
           coalesce((
             select jsonb_agg(jsonb_build_object('id', p.id, 'uhid', p.uhid, 'salutation', p.salutation,
                                                 'first_name', p.first_name, 'last_name', p.last_name)
                              order by p.created_at desc)
             from patients p where p.mobile = right(c.mobile, 10)
           ), '[]'::jsonb) as patients
    from conv c
    cross join lateral (
      select m.direction, m.msg_type, m.body from whatsapp_messages m
      where m.mobile = c.mobile order by m.message_at desc limit 1
    ) lm
  ),
  filtered as (
    select * from rows r
    where (not p_unread_only or r.unread > 0)
      and (
        coalesce(trim(p_search), '') = ''
        or r.mobile like '%' || regexp_replace(p_search, '\D', '', 'g') || '%' and regexp_replace(p_search, '\D', '', 'g') <> ''
        or r.contact_name ilike '%' || trim(p_search) || '%'
        or exists (
          select 1 from jsonb_array_elements(r.patients) e
          where (e->>'first_name') || ' ' || coalesce(e->>'last_name', '') ilike '%' || trim(p_search) || '%'
             or (e->>'uhid') ilike '%' || trim(p_search) || '%'
        )
      )
    order by r.last_at desc
    limit 300
  )
  select jsonb_build_object(
    'conversations', coalesce((select jsonb_agg(to_jsonb(f) order by f.last_at desc) from filtered f), '[]'::jsonb),
    'totalUnread', (select count(*) from whatsapp_messages where direction = 'in' and read_at is null),
    'now', now()
  );
$function$;

-- ── Open a chat: mark read + everything the thread needs, one call ─────
create or replace function public.whatsapp_open_thread(p_mobile text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'Not logged in';
  end if;

  update whatsapp_messages
     set read_at = now()
   where mobile = p_mobile and direction = 'in' and read_at is null;

  return jsonb_build_object(
    'mobile', p_mobile,
    'now', now(),
    'contactName', (select contact_name from whatsapp_messages
                     where mobile = p_mobile and contact_name is not null
                     order by message_at desc limit 1),
    'lastInboundAt', (select max(message_at) from whatsapp_messages
                       where mobile = p_mobile and direction = 'in'),
    'messages', coalesce((
      select jsonb_agg(x order by x.message_at)
      from (
        select m.id, m.wa_message_id, m.direction, m.msg_type, m.body, m.media_id, m.media_mime,
               m.media_filename, m.status, m.error_message, m.message_at, m.reply_to_wa_id,
               pr.full_name as sent_by_name
        from whatsapp_messages m
        left join profiles pr on pr.id = m.sent_by
        where m.mobile = p_mobile
        order by m.message_at desc
        limit 500
      ) x
    ), '[]'::jsonb),
    'templates', coalesce((
      select jsonb_agg(t order by t.sent_at)
      from (
        select l.id, l.template_name, l.sent_at, l.module, pr.full_name as sent_by_name
        from whatsapp_logs l
        left join profiles pr on pr.id = l.triggered_by
        where l.mobile_number = p_mobile and l.success
        order by l.sent_at desc
        limit 100
      ) t
    ), '[]'::jsonb),
    'patients', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'uhid', p.uhid, 'salutation', p.salutation,
                                          'first_name', p.first_name, 'last_name', p.last_name,
                                          'age', p.age, 'gender', p.gender)
                       order by p.created_at desc)
      from patients p where p.mobile = right(p_mobile, 10)
    ), '[]'::jsonb)
  );
end;
$function$;

revoke all on function public.whatsapp_open_thread(text) from public, anon;
grant execute on function public.whatsapp_open_thread(text) to authenticated;
revoke all on function public.ui_whatsapp_inbox(text, boolean) from public, anon;
grant execute on function public.ui_whatsapp_inbox(text, boolean) to authenticated;
