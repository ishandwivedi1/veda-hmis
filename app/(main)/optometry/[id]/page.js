import OptometryWorkspace from './optometry-workspace';

export default async function OptometryEntryPage({ params }) {
  const { id } = await params;
  return <OptometryWorkspace queueEntryId={id} />;
}

