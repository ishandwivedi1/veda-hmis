-- Login History
-- Every successful login gets a row here -- who, when, from what IP,
-- and an approximate location. Location comes from Vercel's own
-- geo headers (x-vercel-ip-*), which Vercel populates automatically
-- on every request based on the edge location that received it -- no
-- external geolocation API, no extra cost, no extra dependency.
-- Worth knowing: this is IP-based, so it's approximate (can be off by
-- a city or more, and a VPN/mobile network will show the VPN's or
-- carrier's location, not the person's actual location).
CREATE TABLE IF NOT EXISTS "public"."login_history" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "profile_id" uuid,
    "logged_in_at" timestamp with time zone DEFAULT now() NOT NULL,
    "ip_address" text,
    "city" text,
    "region" text,
    "country" text,
    "user_agent" text
);

ALTER TABLE "public"."login_history" OWNER TO "postgres";

ALTER TABLE ONLY "public"."login_history"
    ADD CONSTRAINT "login_history_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."login_history"
    ADD CONSTRAINT "login_history_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id");

CREATE INDEX "idx_login_history_profile_id" ON "public"."login_history" USING "btree" ("profile_id");
CREATE INDEX "idx_login_history_logged_in_at" ON "public"."login_history" USING "btree" ("logged_in_at");

ALTER TABLE "public"."login_history" ENABLE ROW LEVEL SECURITY;

-- Only Administrators can read this -- IP addresses and approximate
-- location are the kind of thing that shouldn't be casually browsable
-- by every staff login. Inserts happen via the admin (service-role)
-- client from recordLoginSuccess(), which bypasses RLS, so no INSERT
-- policy is needed for the app to work -- and no UPDATE/DELETE policy
-- exists at all, matching the append-only pattern already used for
-- visit_journey_events and master_data_audit_log.
CREATE POLICY "login_history_select_admin_only" ON "public"."login_history"
  FOR SELECT TO "authenticated"
  USING (EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.designation = 'Administrator'));

GRANT ALL ON TABLE "public"."login_history" TO "anon";
GRANT ALL ON TABLE "public"."login_history" TO "authenticated";
GRANT ALL ON TABLE "public"."login_history" TO "service_role";
