import Workspace from './workspace';

export default async function OpdProcedurePatientPage({ params }) {
  const { patientId } = await params;
  return <Workspace patientId={patientId} />;
}
