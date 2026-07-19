'use server';

import { createClient } from '@/lib/supabase-server';

const MAX_SIZE = 10 * 1024 * 1024;
const ALLOWED_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/jpg'];

function sanitizeFileName(name) {
  return name.replace(/[^a-zA-Z0-9.\-_]/g, '_');
}

// entityType/entityId is a generic pointer (e.g. 'biometry_record' +
// biometry_records.id) so this same action serves every module that
// needs report/document uploads -- Investigation (M21) next.
export async function uploadAttachment(formData) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const file = formData.get('file');
  const entityType = formData.get('entityType');
  const entityId = formData.get('entityId');

  if (!file || typeof file === 'string') return { error: 'No file selected.' };
  if (!entityType || !entityId) return { error: 'Missing entity reference.' };
  if (file.size > MAX_SIZE) return { error: 'File exceeds the 10MB limit.' };
  if (!ALLOWED_TYPES.includes(file.type)) return { error: 'Only PDF, JPG, and PNG files are allowed.' };

  const timestamp = Date.now();
  const safeName = sanitizeFileName(file.name);
  const storagePath = `${entityType}/${entityId}/${timestamp}_${safeName}`;

  const { error: uploadError } = await supabase.storage.from('clinical-attachments').upload(storagePath, file, { contentType: file.type });
  if (uploadError) return { error: uploadError.message };

  const { error: dbError } = await supabase.from('clinical_attachments').insert({
    entity_type: entityType,
    entity_id: entityId,
    file_name: file.name,
    storage_path: storagePath,
    file_size: file.size,
    mime_type: file.type,
    uploaded_by: userData?.user?.id || null,
  });

  if (dbError) {
    // Don't leave an orphaned file with no metadata row if the DB
    // insert failed after the upload succeeded.
    await supabase.storage.from('clinical-attachments').remove([storagePath]);
    return { error: dbError.message };
  }

  return { success: true };
}

// Bucket is private -- each file gets a short-lived signed URL at fetch
// time so the browser can view/download without the bucket being public.
export async function getAttachments(entityType, entityId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('clinical_attachments')
    .select('*, profiles(full_name)')
    .eq('entity_type', entityType)
    .eq('entity_id', entityId)
    .order('uploaded_at', { ascending: false });

  if (error) return [];

  const withUrls = await Promise.all((data || []).map(async (a) => {
    const { data: signed } = await supabase.storage.from('clinical-attachments').createSignedUrl(a.storage_path, 3600);
    return { ...a, url: signed?.signedUrl || null };
  }));

  return withUrls;
}

export async function deleteAttachment(id, storagePath) {
  const supabase = await createClient();
  await supabase.storage.from('clinical-attachments').remove([storagePath]);
  const { error } = await supabase.from('clinical_attachments').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}
