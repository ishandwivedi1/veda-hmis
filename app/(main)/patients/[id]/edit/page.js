import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase-server';
import EditForm from './edit-form';

export default async function EditPatientPage({ params }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: patient } = await supabase.from('patients').select('*').eq('id', id).single();

  if (!patient) notFound();

  return <EditForm patient={patient} />;
}
