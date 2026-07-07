import ConsultationForm from './consultation-form';

export default async function ConsultationPage({ params }) {
  const { id } = await params;
  return <ConsultationForm queueEntryId={id} />;
}

