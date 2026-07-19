import BiometryWorkspace from './workspace';

export default async function BiometryWorkspacePage({ params }) {
  const { id } = await params;
  return <BiometryWorkspace recordId={id} />;
}
