# Vault audit evidence

This module routes Vault API audit request and response records from the Vault
Cloud Run runtime into a dedicated Cloud Logging bucket. It does not route the
proxy, initializer, or ordinary Vault server logs into that bucket.

## Evidence boundary

The initializer owns the audit-device boundary. It accepts `cloudrun/` only
when Vault reports all of these exact options:

- file device writing to `stdout`;
- JSON format;
- `log_raw=false` so Vault HMAC-SHA256 protects sensitive string values;
- `hmac_accessor=true` so token accessors are HMACed too; and
- `elide_list_responses=true` so large list bodies do not become bulk evidence.

The Terraform sink selects only `request` and `response` JSON records from the
Vault runtime's Cloud Run stdout log. `audit_log_location` is an explicit
customer/Legal decision rather than an inference from the runtime region. The
dedicated bucket retains records for at least 365 days and has a Terraform
deletion policy of `PREVENT`. Setting
`audit_log_bucket_locked=true` also makes its retention policy irreversible;
do that only after a named business owner and qualified Legal reviewer approve
the exact retention obligation.

Vault HMAC protects most sensitive strings, not every possible JSON value.
Clients must send sensitive data as strings. Do not mark Vault fields as
non-HMACed, enable raw audit values, or treat this log as safe for broad access.

## Identity and path matrix

| Identity | Path or resource | Authority |
|---|---|---|
| Vault runtime | Cloud Run stdout | Writes structured audit records; no Logging administration |
| Project Log Router | Dedicated Vault audit bucket in the same project | Routes only the exact sink filter; same-project log-bucket sinks need no writer grant |
| `audit_log_viewer_members` | `vault-audit` view in the dedicated bucket | `roles/logging.viewAccessor` on that view only |
| Terraform operator | Bucket, sink, view, view IAM, alert policy | Creates and reconciles the declared audit controls |
| `audit_alert_notification_channels` | Existing Monitoring notification channels | Receives critical sink-error incidents |

Project, folder, and organization IAM can grant broader access than the view
binding. Include those inherited grants in every access review.

## Access review

At least quarterly and after any administrator change:

1. Export `audit_log_viewer_members` from the applied configuration.
2. Export effective access to the bucket and view, including inherited project,
   folder, and organization roles.
3. Match each principal to a current job need and named approver.
4. Remove unjustified grants, record exceptions with an owner and expiry, and
   attach the before/after exports to the restricted access-review record.
5. Have an approved reviewer query the `vault-audit` view and have an ordinary
   project user demonstrate denial. Do not paste returned records into tickets
   or chat.

Source tests prove the declared view IAM is narrow and reject an empty or
project-wide viewer configuration. They are not evidence of effective cloud
IAM; retain the dated export and positive/negative hosted test.

## Sink-error response and drill

Cloud Logging reports failed exports through the
`logging.googleapis.com/exports/error_count` system metric and emits a
`logging.googleapis.com/sink_error` diagnostic log. The module pages on any
error-count delta for the exact sink, repeats the notification while it remains
open, and requires at least one existing notification channel.

When it fires:

1. Acknowledge the incident and preserve the sink-error entry and timestamps.
2. Compare the applied bucket, sink destination, filter, location, retention,
   and lock state with Terraform. Do not disable Vault auditing or enable raw
   values to restore service.
3. Restore the declared sink and emit a non-secret canary Vault request.
4. Confirm its paired request and response records appear through the
   `vault-audit` view, then close the alert.
5. Determine whether the source Cloud Run stdout stream retained records from
   the gap. Preserve a gap statement even when source records remain available;
   do not claim they were durably routed when they were not.
6. Route security-event classification and evidence integrity to Security;
   route retention, preservation, and notification decisions to Legal.

Exercise this only in an approved synthetic project. Create a reversible sink
destination failure, make a non-secret canary request, verify paging, restore
the Terraform configuration, and attach the alert, timeline, source query, view
query, and recovery result. Never fault a customer or production sink without
explicit change authority.

## Release evidence

A complete production record contains:

- the applied Terraform commit and plan;
- the exact Vault Init image promotion that enforces the protected options;
- bucket retention/lock state and sink filter exports;
- notification-channel delivery proof;
- a dated effective-access review with a positive and negative query;
- the most recent authorized outage drill; and
- any retention approval or exception with named human owners.

Passing source tests establishes the configuration contract only. It is not a
substitute for the applied exports, access review, alert delivery, or outage
drill.
