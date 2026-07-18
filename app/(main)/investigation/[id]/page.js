import InvestigationWorkspace from './workspace';

export default async function InvestigationWorkspacePage({ params }) {
  const { id } = await params;
  return <InvestigationWorkspace orderId={id} />;
}
