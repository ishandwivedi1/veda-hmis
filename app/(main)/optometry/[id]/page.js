import OptometryForm from './optometry-form';

export default async function OptometryEntryPage({ params }) {
  const { id } = await params;
  return <OptometryForm queueEntryId={id} />;
}

