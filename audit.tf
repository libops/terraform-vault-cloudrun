locals {
  audit_bucket_id = "${local.service_name}-audit"
  audit_sink_name = "${local.service_name}-audit"
  audit_log_filter = join(" AND ", [
    "resource.type=\"cloud_run_revision\"",
    "resource.labels.service_name=\"${local.service_name}\"",
    "LOG_ID(\"run.googleapis.com/stdout\")",
    "(jsonPayload.type=\"request\" OR jsonPayload.type=\"response\")",
  ])
  audit_sink_error_metric_filter = join(" AND ", [
    "resource.type = \"logging_sink\"",
    "metric.type = \"logging.googleapis.com/exports/error_count\"",
    "resource.label.name = \"${local.audit_sink_name}\"",
  ])
}

resource "google_logging_project_bucket_config" "vault_audit" {
  project         = var.project
  location        = var.audit_log_location
  bucket_id       = local.audit_bucket_id
  description     = "Protected, retained Vault API audit evidence. Values are HMACed by the Vault audit device before ingestion."
  retention_days  = var.audit_log_retention_days
  locked          = var.audit_log_bucket_locked
  deletion_policy = "PREVENT"
}

resource "google_logging_project_sink" "vault_audit" {
  project                = var.project
  name                   = local.audit_sink_name
  description            = "Route only structured Vault API audit records into the protected audit bucket."
  destination            = "logging.googleapis.com/projects/${var.project}/locations/${var.audit_log_location}/buckets/${local.audit_bucket_id}"
  filter                 = local.audit_log_filter
  disabled               = false
  unique_writer_identity = false
  deletion_policy        = "PREVENT"

  depends_on = [google_logging_project_bucket_config.vault_audit]
}

resource "google_logging_log_view" "vault_audit" {
  parent          = "projects/${var.project}"
  location        = var.audit_log_location
  bucket          = google_logging_project_bucket_config.vault_audit.bucket_id
  name            = "vault-audit"
  description     = "Least-privilege view of retained Vault API audit request and response records."
  filter          = "SOURCE(\"projects/${var.project}\") AND resource.type=\"cloud_run_revision\" AND LOG_ID(\"run.googleapis.com/stdout\")"
  deletion_policy = "PREVENT"
}

resource "google_logging_log_view_iam_member" "vault_audit" {
  for_each = var.audit_log_viewer_members

  parent   = "projects/${var.project}"
  location = var.audit_log_location
  bucket   = google_logging_project_bucket_config.vault_audit.bucket_id
  name     = google_logging_log_view.vault_audit.name
  role     = "roles/logging.viewAccessor"
  member   = each.value
}

resource "google_monitoring_alert_policy" "vault_audit_sink_error" {
  project               = var.project
  display_name          = "Vault audit sink routing failure"
  combiner              = "OR"
  enabled               = true
  severity              = "CRITICAL"
  notification_channels = sort(tolist(var.audit_alert_notification_channels))
  deletion_policy       = "PREVENT"

  conditions {
    display_name = "Vault audit sink emitted a routing error"

    condition_threshold {
      filter                  = local.audit_sink_error_metric_filter
      comparison              = "COMPARISON_GT"
      threshold_value         = 0
      duration                = "0s"
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close           = "86400s"
    notification_prompts = ["OPENED", "CLOSED"]

    notification_channel_strategy {
      notification_channel_names = sort(tolist(var.audit_alert_notification_channels))
      renotify_interval          = "1800s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Vault audit evidence routing failed"
    content   = <<-EOT
      Treat this as a security-evidence incident. Preserve the sink error and
      timeline, restore the exact `${local.audit_sink_name}` destination, then
      compare the retained audit bucket with the source Cloud Run stdout stream.
      Do not disable Vault auditing or enable raw audit values during recovery.
    EOT
  }
}
