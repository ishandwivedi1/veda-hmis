import Workspace from './workspace';

export default async function SurgicalJourneyCasePage({ params }) {
  const { id } = await params;
  return <Workspace caseId={id} />;
}
