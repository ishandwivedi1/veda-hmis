--
-- PostgreSQL database dump
--

\restrict sk284P48KwdtBn6MH18jfedRqE0GAteHSzQER1ztpCPXGI4sAK7jjeujK9Hipoc

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.10 (Ubuntu 17.10-1.pgdg24.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: -
--

INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, invited_at, confirmation_token, confirmation_sent_at, recovery_token, recovery_sent_at, email_change_token_new, email_change, email_change_sent_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, created_at, updated_at, phone, phone_confirmed_at, phone_change, phone_change_token, phone_change_sent_at, email_change_token_current, email_change_confirm_status, banned_until, reauthentication_token, reauthentication_sent_at, is_sso_user, deleted_at, is_anonymous) VALUES ('00000000-0000-0000-0000-000000000000', '9303188c-8d2f-40a1-b1c8-b8218098de5f', 'authenticated', 'authenticated', 'ishandwivedi1@gmail.com', '$2a$10$OPbB6d/WZLBu3HpCD1N3beATJj7A8zL7D4LCTlNJSEMv7SrTrQlMm', '2026-07-06 17:35:35.667255+00', NULL, '', NULL, '', NULL, '', '', NULL, '2026-07-25 17:44:38.763897+00', '{"provider": "email", "providers": ["email"]}', '{"email_verified": true}', NULL, '2026-07-06 17:35:35.639685+00', '2026-07-25 17:44:38.766109+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false);
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, invited_at, confirmation_token, confirmation_sent_at, recovery_token, recovery_sent_at, email_change_token_new, email_change, email_change_sent_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, created_at, updated_at, phone, phone_confirmed_at, phone_change, phone_change_token, phone_change_sent_at, email_change_token_current, email_change_confirm_status, banned_until, reauthentication_token, reauthentication_sent_at, is_sso_user, deleted_at, is_anonymous) VALUES ('00000000-0000-0000-0000-000000000000', 'e97fc3b7-118e-44a8-af45-5f34f746cdea', 'authenticated', 'authenticated', 'nishabachkheti@gmail.com', '$2a$10$aL4djDR4rGL6OEueNCazOOzfe8YdVbvRJ7l1RwRpq.NqcuOSNU7vW', '2026-07-08 23:49:13.825752+00', NULL, '', NULL, '', NULL, '', '', NULL, '2026-07-25 17:08:03.181269+00', '{"provider": "email", "providers": ["email"]}', '{"full_name": "nisha bachkheti", "department": "", "designation": "ophthalmologist", "email_verified": true}', NULL, '2026-07-08 23:49:13.797109+00', '2026-07-27 07:39:02.516461+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false);


--
-- Data for Name: identities; Type: TABLE DATA; Schema: auth; Owner: -
--

INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at, id) VALUES ('9303188c-8d2f-40a1-b1c8-b8218098de5f', '9303188c-8d2f-40a1-b1c8-b8218098de5f', '{"sub": "9303188c-8d2f-40a1-b1c8-b8218098de5f", "email": "ishandwivedi1@gmail.com", "email_verified": false, "phone_verified": false}', 'email', '2026-07-06 17:35:35.661623+00', '2026-07-06 17:35:35.661715+00', '2026-07-06 17:35:35.661715+00', '3df3757b-c6c5-481b-8992-b10d0928985f');
INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at, id) VALUES ('e97fc3b7-118e-44a8-af45-5f34f746cdea', 'e97fc3b7-118e-44a8-af45-5f34f746cdea', '{"sub": "e97fc3b7-118e-44a8-af45-5f34f746cdea", "email": "nishabachkheti@gmail.com", "email_verified": false, "phone_verified": false}', 'email', '2026-07-08 23:49:13.821679+00', '2026-07-08 23:49:13.821734+00', '2026-07-08 23:49:13.821734+00', '248a1e29-8f91-4b8b-9e44-0d23049cc7d3');


--
-- PostgreSQL database dump complete
--

\unrestrict sk284P48KwdtBn6MH18jfedRqE0GAteHSzQER1ztpCPXGI4sAK7jjeujK9Hipoc

