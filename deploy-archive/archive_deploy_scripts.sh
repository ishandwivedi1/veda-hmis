#!/bin/bash
set -e

# Repo cleanup: moves 191 historical one-off .sh deploy/test/fix
# scripts from the repo root into deploy-archive/ -- nothing deleted,
# just moved out of the way. Confirmed nothing in the app,
# package.json, or CI references any of these files by path.
# Run this from your veda-hmis repo root in Codespaces.

mkdir -p deploy-archive

cat > deploy-archive/README.md << 'READMEEOF'
# Deploy Archive

This folder holds one-off .sh deploy and test scripts generated during
past development sessions. Each was run once in Codespaces to apply a
specific change (schema migration, file write, or standalone test) and
isn't meant to be re-run -- they're kept here purely as a historical
record, out of the repo root to keep it navigable.

Safe to delete entirely if you don't need the history; nothing in the
running app depends on these files.
READMEEOF

[ -f "add_biometry_billing_trigger.sh" ] && mv "add_biometry_billing_trigger.sh" deploy-archive/ || true
[ -f "add_biometry_dedicated_section.sh" ] && mv "add_biometry_dedicated_section.sh" deploy-archive/ || true
[ -f "add_biometry_optional_counselling.sh" ] && mv "add_biometry_optional_counselling.sh" deploy-archive/ || true
[ -f "add_biometry_remove_unbilled.sh" ] && mv "add_biometry_remove_unbilled.sh" deploy-archive/ || true
[ -f "add_completed_consultation_view.sh" ] && mv "add_completed_consultation_view.sh" deploy-archive/ || true
[ -f "add_counselling_dashboard.sh" ] && mv "add_counselling_dashboard.sh" deploy-archive/ || true
[ -f "add_decision_package_locking.sh" ] && mv "add_decision_package_locking.sh" deploy-archive/ || true
[ -f "add_dilation_to_counselling.sh" ] && mv "add_dilation_to_counselling.sh" deploy-archive/ || true
[ -f "add_doctor_dashboard_widgets.sh" ] && mv "add_doctor_dashboard_widgets.sh" deploy-archive/ || true
[ -f "add_followup_consultation_template.sh" ] && mv "add_followup_consultation_template.sh" deploy-archive/ || true
[ -f "add_investigation_billing_widget.sh" ] && mv "add_investigation_billing_widget.sh" deploy-archive/ || true
[ -f "add_investigation_findings_in_consultation.sh" ] && mv "add_investigation_findings_in_consultation.sh" deploy-archive/ || true
[ -f "add_investigation_history_comparison_reports.sh" ] && mv "add_investigation_history_comparison_reports.sh" deploy-archive/ || true
[ -f "add_investigation_history_date_sort.sh" ] && mv "add_investigation_history_date_sort.sh" deploy-archive/ || true
[ -f "add_investigation_package_ordering.sh" ] && mv "add_investigation_package_ordering.sh" deploy-archive/ || true
[ -f "add_investigation_queue_payment_status.sh" ] && mv "add_investigation_queue_payment_status.sh" deploy-archive/ || true
[ -f "add_investigation_readonly_view.sh" ] && mv "add_investigation_readonly_view.sh" deploy-archive/ || true
[ -f "add_investigation_tab_bar.sh" ] && mv "add_investigation_tab_bar.sh" deploy-archive/ || true
[ -f "add_medical_fitness_module.sh" ] && mv "add_medical_fitness_module.sh" deploy-archive/ || true
[ -f "add_medical_fitness_tabs.sh" ] && mv "add_medical_fitness_tabs.sh" deploy-archive/ || true
[ -f "add_ot_assign_surgeon.sh" ] && mv "add_ot_assign_surgeon.sh" deploy-archive/ || true
[ -f "add_ot_checkin_gate.sh" ] && mv "add_ot_checkin_gate.sh" deploy-archive/ || true
[ -f "add_ot_handover_recovery.sh" ] && mv "add_ot_handover_recovery.sh" deploy-archive/ || true
[ -f "add_ot_package_visibility.sh" ] && mv "add_ot_package_visibility.sh" deploy-archive/ || true
[ -f "add_package_taxonomy_ui.sh" ] && mv "add_package_taxonomy_ui.sh" deploy-archive/ || true
[ -f "add_pharmacy_billing_widget.sh" ] && mv "add_pharmacy_billing_widget.sh" deploy-archive/ || true
[ -f "add_procedures_dropdown.sh" ] && mv "add_procedures_dropdown.sh" deploy-archive/ || true
[ -f "add_surgery_advised_stage.sh" ] && mv "add_surgery_advised_stage.sh" deploy-archive/ || true
[ -f "add_surgery_tab_and_dropdown.sh" ] && mv "add_surgery_tab_and_dropdown.sh" deploy-archive/ || true
[ -f "add_surgical_consumables_master.sh" ] && mv "add_surgical_consumables_master.sh" deploy-archive/ || true
[ -f "add_timeline_clinical_record_link.sh" ] && mv "add_timeline_clinical_record_link.sh" deploy-archive/ || true
[ -f "add_visit_edit_cancel.sh" ] && mv "add_visit_edit_cancel.sh" deploy-archive/ || true
[ -f "add_visit_type_routing.sh" ] && mv "add_visit_type_routing.sh" deploy-archive/ || true
[ -f "build_ot_intraop_module.sh" ] && mv "build_ot_intraop_module.sh" deploy-archive/ || true
[ -f "build_ot_recovery_module.sh" ] && mv "build_ot_recovery_module.sh" deploy-archive/ || true
[ -f "build_ot_scheduling_module.sh" ] && mv "build_ot_scheduling_module.sh" deploy-archive/ || true
[ -f "consolidate_consultation_sidebar.sh" ] && mv "consolidate_consultation_sidebar.sh" deploy-archive/ || true
[ -f "consolidate_medical_fitness_spa.sh" ] && mv "consolidate_medical_fitness_spa.sh" deploy-archive/ || true
[ -f "consultation_facelift.sh" ] && mv "consultation_facelift.sh" deploy-archive/ || true
[ -f "dark_sidebar_frozen_layout.sh" ] && mv "dark_sidebar_frozen_layout.sh" deploy-archive/ || true
[ -f "deploy_additional_and_biometry.sh" ] && mv "deploy_additional_and_biometry.sh" deploy-archive/ || true
[ -f "deploy_advance_settlement.sh" ] && mv "deploy_advance_settlement.sh" deploy-archive/ || true
[ -f "deploy_attachments_biometry.sh" ] && mv "deploy_attachments_biometry.sh" deploy-archive/ || true
[ -f "deploy_bigger_print_logo.sh" ] && mv "deploy_bigger_print_logo.sh" deploy-archive/ || true
[ -f "deploy_billing_dashboard.sh" ] && mv "deploy_billing_dashboard.sh" deploy-archive/ || true
[ -f "deploy_billing_dashboard_cleanup.sh" ] && mv "deploy_billing_dashboard_cleanup.sh" deploy-archive/ || true
[ -f "deploy_billing_dashboard_v2.sh" ] && mv "deploy_billing_dashboard_v2.sh" deploy-archive/ || true
[ -f "deploy_billing_print_and_redirect.sh" ] && mv "deploy_billing_print_and_redirect.sh" deploy-archive/ || true
[ -f "deploy_biometry_duplicate_fix.sh" ] && mv "deploy_biometry_duplicate_fix.sh" deploy-archive/ || true
[ -f "deploy_biometry_multi_device_readings.sh" ] && mv "deploy_biometry_multi_device_readings.sh" deploy-archive/ || true
[ -f "deploy_biometry_remove_procedure.sh" ] && mv "deploy_biometry_remove_procedure.sh" deploy-archive/ || true
[ -f "deploy_biometry_report_fixes.sh" ] && mv "deploy_biometry_report_fixes.sh" deploy-archive/ || true
[ -f "deploy_brand_vs_generic_fix.sh" ] && mv "deploy_brand_vs_generic_fix.sh" deploy-archive/ || true
[ -f "deploy_case_sheet_exam_redesign.sh" ] && mv "deploy_case_sheet_exam_redesign.sh" deploy-archive/ || true
[ -f "deploy_case_sheet_polish.sh" ] && mv "deploy_case_sheet_polish.sh" deploy-archive/ || true
[ -f "deploy_case_sheet_refraction_match.sh" ] && mv "deploy_case_sheet_refraction_match.sh" deploy-archive/ || true
[ -f "deploy_consent_form_optional.sh" ] && mv "deploy_consent_form_optional.sh" deploy-archive/ || true
[ -f "deploy_consolidated_pharmacy_billing.sh" ] && mv "deploy_consolidated_pharmacy_billing.sh" deploy-archive/ || true
[ -f "deploy_counselling_widget_sidebar.sh" ] && mv "deploy_counselling_widget_sidebar.sh" deploy-archive/ || true
[ -f "deploy_diagnosis_plan_cleanup.sh" ] && mv "deploy_diagnosis_plan_cleanup.sh" deploy-archive/ || true
[ -f "deploy_discharge_investigation_templates.sh" ] && mv "deploy_discharge_investigation_templates.sh" deploy-archive/ || true
[ -f "deploy_discharge_investigation_templates_fixed.sh" ] && mv "deploy_discharge_investigation_templates_fixed.sh" deploy-archive/ || true
[ -f "deploy_doctor_optometry_merge.sh" ] && mv "deploy_doctor_optometry_merge.sh" deploy-archive/ || true
[ -f "deploy_examination_autosave_confirm.sh" ] && mv "deploy_examination_autosave_confirm.sh" deploy-archive/ || true
[ -f "deploy_examination_overhaul.sh" ] && mv "deploy_examination_overhaul.sh" deploy-archive/ || true
[ -f "deploy_examination_stage_visuals.sh" ] && mv "deploy_examination_stage_visuals.sh" deploy-archive/ || true
[ -f "deploy_examination_two_stage.sh" ] && mv "deploy_examination_two_stage.sh" deploy-archive/ || true
[ -f "deploy_eye_derive_surgery.sh" ] && mv "deploy_eye_derive_surgery.sh" deploy-archive/ || true
[ -f "deploy_fix_invoice_purpose.sh" ] && mv "deploy_fix_invoice_purpose.sh" deploy-archive/ || true
[ -f "deploy_fix_surgery_bill_package_mismatch.sh" ] && mv "deploy_fix_surgery_bill_package_mismatch.sh" deploy-archive/ || true
[ -f "deploy_glasses_prescription_print.sh" ] && mv "deploy_glasses_prescription_print.sh" deploy-archive/ || true
[ -f "deploy_gonio_and_eye_naming.sh" ] && mv "deploy_gonio_and_eye_naming.sh" deploy-archive/ || true
[ -f "deploy_history_in_optometry.sh" ] && mv "deploy_history_in_optometry.sh" deploy-archive/ || true
[ -f "deploy_implant_iol_dropdown.sh" ] && mv "deploy_implant_iol_dropdown.sh" deploy-archive/ || true
[ -f "deploy_implant_legacy_data_fix.sh" ] && mv "deploy_implant_legacy_data_fix.sh" deploy-archive/ || true
[ -f "deploy_implant_verification_redesign.sh" ] && mv "deploy_implant_verification_redesign.sh" deploy-archive/ || true
[ -f "deploy_investigation_dashboard_widget.sh" ] && mv "deploy_investigation_dashboard_widget.sh" deploy-archive/ || true
[ -f "deploy_investigation_upload.sh" ] && mv "deploy_investigation_upload.sh" deploy-archive/ || true
[ -f "deploy_ist_time_and_compulsory_day_open.sh" ] && mv "deploy_ist_time_and_compulsory_day_open.sh" deploy-archive/ || true
[ -f "deploy_live_patient_search.sh" ] && mv "deploy_live_patient_search.sh" deploy-archive/ || true
[ -f "deploy_live_patient_search111.sh" ] && mv "deploy_live_patient_search111.sh" deploy-archive/ || true
[ -f "deploy_login_double_click_fix.sh" ] && mv "deploy_login_double_click_fix.sh" deploy-archive/ || true
[ -f "deploy_login_hang_fix.sh" ] && mv "deploy_login_hang_fix.sh" deploy-archive/ || true
[ -f "deploy_m23_calculation_approval_history.sh" ] && mv "deploy_m23_calculation_approval_history.sh" deploy-archive/ || true
[ -f "deploy_merge_ot_into_counselling.sh" ] && mv "deploy_merge_ot_into_counselling.sh" deploy-archive/ || true
[ -f "deploy_nav_and_login_redirect.sh" ] && mv "deploy_nav_and_login_redirect.sh" deploy-archive/ || true
[ -f "deploy_opd_case_sheet_full.sh" ] && mv "deploy_opd_case_sheet_full.sh" deploy-archive/ || true
[ -f "deploy_opd_surgery_bill_changes.sh" ] && mv "deploy_opd_surgery_bill_changes.sh" deploy-archive/ || true
[ -f "deploy_optometry_autosave_va_width.sh" ] && mv "deploy_optometry_autosave_va_width.sh" deploy-archive/ || true
[ -f "deploy_ot_billing_gate.sh" ] && mv "deploy_ot_billing_gate.sh" deploy-archive/ || true
[ -f "deploy_ot_schedule_module.sh" ] && mv "deploy_ot_schedule_module.sh" deploy-archive/ || true
[ -f "deploy_package_breakup_inline.sh" ] && mv "deploy_package_breakup_inline.sh" deploy-archive/ || true
[ -f "deploy_package_breakup_optional.sh" ] && mv "deploy_package_breakup_optional.sh" deploy-archive/ || true
[ -f "deploy_patient_edit_create_visit.sh" ] && mv "deploy_patient_edit_create_visit.sh" deploy-archive/ || true
[ -f "deploy_patient_history_masters.sh" ] && mv "deploy_patient_history_masters.sh" deploy-archive/ || true
[ -f "deploy_pharmacy_consolidation_fix.sh" ] && mv "deploy_pharmacy_consolidation_fix.sh" deploy-archive/ || true
[ -f "deploy_pharmacy_print_only_consolidation.sh" ] && mv "deploy_pharmacy_print_only_consolidation.sh" deploy-archive/ || true
[ -f "deploy_plan_reorder_plus_biometry_fix.sh" ] && mv "deploy_plan_reorder_plus_biometry_fix.sh" deploy-archive/ || true
[ -f "deploy_plan_tab_reorder.sh" ] && mv "deploy_plan_tab_reorder.sh" deploy-archive/ || true
[ -f "deploy_postop_turned_up_today.sh" ] && mv "deploy_postop_turned_up_today.sh" deploy-archive/ || true
[ -f "deploy_print_pagination.sh" ] && mv "deploy_print_pagination.sh" deploy-archive/ || true
[ -f "deploy_print_popups.sh" ] && mv "deploy_print_popups.sh" deploy-archive/ || true
[ -f "deploy_refraction_redesign.sh" ] && mv "deploy_refraction_redesign.sh" deploy-archive/ || true
[ -f "deploy_sidebar_cleanup.sh" ] && mv "deploy_sidebar_cleanup.sh" deploy-archive/ || true
[ -f "deploy_sidebar_heading_fix.sh" ] && mv "deploy_sidebar_heading_fix.sh" deploy-archive/ || true
[ -f "deploy_sorting_options.sh" ] && mv "deploy_sorting_options.sh" deploy-archive/ || true
[ -f "deploy_standardize_designations.sh" ] && mv "deploy_standardize_designations.sh" deploy-archive/ || true
[ -f "deploy_sticky_tabs_and_package_breakup.sh" ] && mv "deploy_sticky_tabs_and_package_breakup.sh" deploy-archive/ || true
[ -f "deploy_surgery_billing_redesign.sh" ] && mv "deploy_surgery_billing_redesign.sh" deploy-archive/ || true
[ -f "deploy_suspense_fixes.sh" ] && mv "deploy_suspense_fixes.sh" deploy-archive/ || true
[ -f "deploy_three_fixes.sh" ] && mv "deploy_three_fixes.sh" deploy-archive/ || true
[ -f "deploy_username_admin_edit.sh" ] && mv "deploy_username_admin_edit.sh" deploy-archive/ || true
[ -f "deploy_va_dropdown_table.sh" ] && mv "deploy_va_dropdown_table.sh" deploy-archive/ || true
[ -f "deploy_va_dropdown_updates.sh" ] && mv "deploy_va_dropdown_updates.sh" deploy-archive/ || true
[ -f "deploy_visit_type_badges_and_review_gate.sh" ] && mv "deploy_visit_type_badges_and_review_gate.sh" deploy-archive/ || true
[ -f "doctor_dashboard_facelift.sh" ] && mv "doctor_dashboard_facelift.sh" deploy-archive/ || true
[ -f "editable_followup_schedule.sh" ] && mv "editable_followup_schedule.sh" deploy-archive/ || true
[ -f "fix_biometry_add_pattern_and_dual_send.sh" ] && mv "fix_biometry_add_pattern_and_dual_send.sh" deploy-archive/ || true
[ -f "fix_biometry_button_state.sh" ] && mv "fix_biometry_button_state.sh" deploy-archive/ || true
[ -f "fix_biometry_indigo_both_eyes_stay_page.sh" ] && mv "fix_biometry_indigo_both_eyes_stay_page.sh" deploy-archive/ || true
[ -f "fix_biometry_name_confusion.sh" ] && mv "fix_biometry_name_confusion.sh" deploy-archive/ || true
[ -f "fix_clinical_master_codes.sh" ] && mv "fix_clinical_master_codes.sh" deploy-archive/ || true
[ -f "fix_combined_restore_and_reported.sh" ] && mv "fix_combined_restore_and_reported.sh" deploy-archive/ || true
[ -f "fix_completed_consultation_lookup.sh" ] && mv "fix_completed_consultation_lookup.sh" deploy-archive/ || true
[ -f "fix_context_sidebar_investigations_timeline.sh" ] && mv "fix_context_sidebar_investigations_timeline.sh" deploy-archive/ || true
[ -f "fix_counselling_and_iol_checkin.sh" ] && mv "fix_counselling_and_iol_checkin.sh" deploy-archive/ || true
[ -f "fix_counselling_module.sh" ] && mv "fix_counselling_module.sh" deploy-archive/ || true
[ -f "fix_doctor_intermediate_queue_biometry.sh" ] && mv "fix_doctor_intermediate_queue_biometry.sh" deploy-archive/ || true
[ -f "fix_duplicate_surgical_cases.sh" ] && mv "fix_duplicate_surgical_cases.sh" deploy-archive/ || true
[ -f "fix_encounters_column_name.sh" ] && mv "fix_encounters_column_name.sh" deploy-archive/ || true
[ -f "fix_followup_detection.sh" ] && mv "fix_followup_detection.sh" deploy-archive/ || true
[ -f "fix_full_bundle.sh" ] && mv "fix_full_bundle.sh" deploy-archive/ || true
[ -f "fix_investigation_click_actual.sh" ] && mv "fix_investigation_click_actual.sh" deploy-archive/ || true
[ -f "fix_investigation_start_and_popups.sh" ] && mv "fix_investigation_start_and_popups.sh" deploy-archive/ || true
[ -f "fix_iop_data_loss.sh" ] && mv "fix_iop_data_loss.sh" deploy-archive/ || true
[ -f "fix_mark_for_surgery_display.sh" ] && mv "fix_mark_for_surgery_display.sh" deploy-archive/ || true
[ -f "fix_master_data_use_server.sh" ] && mv "fix_master_data_use_server.sh" deploy-archive/ || true
[ -f "fix_missing_cyan_css.sh" ] && mv "fix_missing_cyan_css.sh" deploy-archive/ || true
[ -f "fix_missing_exports_after_ot_merge.sh" ] && mv "fix_missing_exports_after_ot_merge.sh" deploy-archive/ || true
[ -f "fix_ot_complete_reschedule.sh" ] && mv "fix_ot_complete_reschedule.sh" deploy-archive/ || true
[ -f "fix_ot_merge_full_restore.sh" ] && mv "fix_ot_merge_full_restore.sh" deploy-archive/ || true
[ -f "fix_ot_queue_refresh.sh" ] && mv "fix_ot_queue_refresh.sh" deploy-archive/ || true
[ -f "fix_ot_shared_bottom_bar.sh" ] && mv "fix_ot_shared_bottom_bar.sh" deploy-archive/ || true
[ -f "fix_package_billing.sh" ] && mv "fix_package_billing.sh" deploy-archive/ || true
[ -f "fix_packages_surgery_link.sh" ] && mv "fix_packages_surgery_link.sh" deploy-archive/ || true
[ -f "fix_payments_billing_stale_state.sh" ] && mv "fix_payments_billing_stale_state.sh" deploy-archive/ || true
[ -f "fix_postop_future_date_check.sh" ] && mv "fix_postop_future_date_check.sh" deploy-archive/ || true
[ -f "fix_postop_notes_and_attachments.sh" ] && mv "fix_postop_notes_and_attachments.sh" deploy-archive/ || true
[ -f "fix_postop_optometry_routing.sh" ] && mv "fix_postop_optometry_routing.sh" deploy-archive/ || true
[ -f "fix_postop_review_existing_visit.sh" ] && mv "fix_postop_review_existing_visit.sh" deploy-archive/ || true
[ -f "fix_recovery_discharge_date_and_meds.sh" ] && mv "fix_recovery_discharge_date_and_meds.sh" deploy-archive/ || true
[ -f "fix_recovery_discharge_items_bug.sh" ] && mv "fix_recovery_discharge_items_bug.sh" deploy-archive/ || true
[ -f "fix_recovery_final_button.sh" ] && mv "fix_recovery_final_button.sh" deploy-archive/ || true
[ -f "fix_send_for_biometry.sh" ] && mv "fix_send_for_biometry.sh" deploy-archive/ || true
[ -f "fix_sticky_header_and_preop.sh" ] && mv "fix_sticky_header_and_preop.sh" deploy-archive/ || true
[ -f "fix_surgery_common_code.sh" ] && mv "fix_surgery_common_code.sh" deploy-archive/ || true
[ -f "fix_surgery_service_dropdown.sh" ] && mv "fix_surgery_service_dropdown.sh" deploy-archive/ || true
[ -f "fix_timeline_and_call_direct.sh" ] && mv "fix_timeline_and_call_direct.sh" deploy-archive/ || true
[ -f "fix_uniform_clinical_codes.sh" ] && mv "fix_uniform_clinical_codes.sh" deploy-archive/ || true
[ -f "fix_visits_profiles_ambiguity_v2.sh" ] && mv "fix_visits_profiles_ambiguity_v2.sh" deploy-archive/ || true
[ -f "fix_walk_in_visit_ambiguity.sh" ] && mv "fix_walk_in_visit_ambiguity.sh" deploy-archive/ || true
[ -f "fix_widget_position_and_stale_invoice_state.sh" ] && mv "fix_widget_position_and_stale_invoice_state.sh" deploy-archive/ || true
[ -f "floating_error_alerts.sh" ] && mv "floating_error_alerts.sh" deploy-archive/ || true
[ -f "merge_biometry_into_investigation.sh" ] && mv "merge_biometry_into_investigation.sh" deploy-archive/ || true
[ -f "merge_postop_episode_followup.sh" ] && mv "merge_postop_episode_followup.sh" deploy-archive/ || true
[ -f "merge_surgery_complete_fix_savedraft.sh" ] && mv "merge_surgery_complete_fix_savedraft.sh" deploy-archive/ || true
[ -f "move_consultation_out_of_shell.sh" ] && mv "move_consultation_out_of_shell.sh" deploy-archive/ || true
[ -f "new_window_and_minor_procedures.sh" ] && mv "new_window_and_minor_procedures.sh" deploy-archive/ || true
[ -f "opd_case_sheet_and_invoice_print_button.sh" ] && mv "opd_case_sheet_and_invoice_print_button.sh" deploy-archive/ || true
[ -f "print_templates_system_invoice.sh" ] && mv "print_templates_system_invoice.sh" deploy-archive/ || true
[ -f "print_templates_v2_opd_surgery.sh" ] && mv "print_templates_v2_opd_surgery.sh" deploy-archive/ || true
[ -f "receipt_and_advance_receipt_templates.sh" ] && mv "receipt_and_advance_receipt_templates.sh" deploy-archive/ || true
[ -f "redesign_medical_fitness_dashboard_timeline.sh" ] && mv "redesign_medical_fitness_dashboard_timeline.sh" deploy-archive/ || true
[ -f "redesign_ot_intraop_summary.sh" ] && mv "redesign_ot_intraop_summary.sh" deploy-archive/ || true
[ -f "refine_biometry_and_diagnosis_notes.sh" ] && mv "refine_biometry_and_diagnosis_notes.sh" deploy-archive/ || true
[ -f "remodel_consultation_context_sidebar.sh" ] && mv "remodel_consultation_context_sidebar.sh" deploy-archive/ || true
[ -f "remove_biometry_from_consultation.sh" ] && mv "remove_biometry_from_consultation.sh" deploy-archive/ || true
[ -f "remove_package_billing_tab.sh" ] && mv "remove_package_billing_tab.sh" deploy-archive/ || true
[ -f "restructure_counselling_sections.sh" ] && mv "restructure_counselling_sections.sh" deploy-archive/ || true
[ -f "restructure_doctor_dashboard_spa.sh" ] && mv "restructure_doctor_dashboard_spa.sh" deploy-archive/ || true
[ -f "restructure_ot_intraop_spa.sh" ] && mv "restructure_ot_intraop_spa.sh" deploy-archive/ || true
[ -f "setup_counselling_module.sh" ] && mv "setup_counselling_module.sh" deploy-archive/ || true
[ -f "simplify_counselling_medical_fitness_only.sh" ] && mv "simplify_counselling_medical_fitness_only.sh" deploy-archive/ || true
[ -f "simplify_postop_review.sh" ] && mv "simplify_postop_review.sh" deploy-archive/ || true
[ -f "split_ot_intraop_tabs.sh" ] && mv "split_ot_intraop_tabs.sh" deploy-archive/ || true
[ -f "split_recovery_postop_modules.sh" ] && mv "split_recovery_postop_modules.sh" deploy-archive/ || true
[ -f "test-advance-whatsapp.sh" ] && mv "test-advance-whatsapp.sh" deploy-archive/ || true
[ -f "test-visit-whatsapp.sh" ] && mv "test-visit-whatsapp.sh" deploy-archive/ || true
[ -f "test-whatsapp.sh" ] && mv "test-whatsapp.sh" deploy-archive/ || true
[ -f "ui_polish_design_refresh.sh" ] && mv "ui_polish_design_refresh.sh" deploy-archive/ || true
[ -f "verify_surgery_type_dropdown.sh" ] && mv "verify_surgery_type_dropdown.sh" deploy-archive/ || true

echo "Archived $(ls deploy-archive/*.sh 2>/dev/null | wc -l) scripts. Remaining .sh in root: $(ls *.sh 2>/dev/null | wc -l)"

git add -A
git commit -m "Archive 191 historical one-off deploy/fix/test scripts into deploy-archive/"
git push

echo "Done."
