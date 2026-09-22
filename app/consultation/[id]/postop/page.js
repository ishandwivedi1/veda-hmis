import PostOpReviewForm from '../postop-review-form';

export default async function PostOpReviewPage({ params, searchParams }) {
  const { id } = await params;
  const { followupId } = await searchParams;
  return <PostOpReviewForm queueEntryId={id} followupId={followupId} />;
}
