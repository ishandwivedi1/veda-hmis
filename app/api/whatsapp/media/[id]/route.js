// Opens a photo / voice note / document a patient sent on WhatsApp
// (WhatsApp Inbox, migration 053). Logged-in staff only, and only media
// ids that actually belong to a saved message -- never a general proxy
// to Meta's API.

import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase-server';
import { fetchWhatsAppMedia } from '@/lib/whatsappInbox';

export const dynamic = 'force-dynamic';

export async function GET(request, { params }) {
  const { id } = await params;
  const supabase = await createClient();
  // RLS lets only logged-in staff read whatsapp_messages, so this is the
  // login check and the "is this one of ours" check in one.
  const { data: row } = await supabase
    .from('whatsapp_messages')
    .select('media_mime, media_filename')
    .eq('media_id', id)
    .limit(1)
    .maybeSingle();
  if (!row) return new NextResponse('Not found', { status: 404 });

  const media = await fetchWhatsAppMedia(id);
  if (media.error) return new NextResponse(media.error, { status: 502 });

  const filename = (row.media_filename || `whatsapp-${id}`).replace(/["\r\n]/g, '');
  return new NextResponse(media.buffer, {
    status: 200,
    headers: {
      'content-type': row.media_mime || media.mime,
      'content-disposition': `inline; filename="${filename}"`,
      'cache-control': 'private, max-age=3600',
    },
  });
}
