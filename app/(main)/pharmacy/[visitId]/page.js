import Workspace from './workspace';

export default async function PharmacyWorkspacePage({ params }) {
  const { visitId } = await params;
  return <Workspace visitId={visitId} />;
}
