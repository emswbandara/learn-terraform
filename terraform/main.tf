terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "4.53.1"
    }
  }
}
provider "google" {
  project = "${var.project_id}"
  region  = "europe-west4"
  zone    = "europe-west4-c"
}

resource "google_sql_database_instance" "primary" {
  name             = "primary-instance"
  region           = "europe-west4"
  database_version = "POSTGRES_12"

  settings {
    tier              = "db-f1-micro"
    availability_type = "REGIONAL"
    disk_size         = "100"
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled    = true
      private_network = "projects/${var.project_id}/global/networks/default"
    }
    location_preference {
      zone = "europe-west4-c"
    }
    database_flags {
      name  = "enable_performance_metrics"
      value = "on"
    }
  }
}

resource "google_sql_user" "main" {
  depends_on = [
    google_sql_database_instance.primary
  ]
  name     = "main"
  instance = google_sql_database_instance.primary.name
  password = var.sql_user_password
}

resource "google_sql_database" "main" {
  depends_on = [
    google_sql_user.main
  ]
  name     = "main"
  instance = google_sql_database_instance.primary.name
}

# Initialize database with pgbench schema.
resource "null_resource" "postgresql_init" {
  depends_on = [
    google_sql_database_instance.primary,
    google_sql_database.main,
    google_sql_user.main
  ]

  provisioner "remote-exec" {
    inline = [
      "pgbench --initialize"
      # "PGPASSWORD='${google_sql_user.main.password}' psql -h '${google_sql_database_instance.primary.ip_address}' -U '${google_sql_user.main.name}' -d '${google_sql_database.main.name}' -f /usr/share/postgresql/12/contrib/pgbench.sql"
    ]

    connection {
      type        = "ssh"
      host        = google_sql_database_instance.primary.ip_address
      user        = "postgres"
      private_key = file("${var.ssh_key_path}")
    }
  }
}

resource "google_sql_database_instance" "standby" {
  name                 = "standby-instance"
  master_instance_name = "${var.project_id}:${google_sql_database_instance.primary.name}"
  region               = "europe-west4"
  database_version     = "POSTGRES_12"

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = "100"
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled    = true
      private_network = "projects/${var.project_id}/global/networks/default"
    }
    location_preference {
      zone = "europe-west4-c"
    }
  }
}

# Create GCP bucket to store the backups.
resource "google_storage_bucket" "backup" {
  name     = "${var.project_id}:${google_sql_database_instance.standby.name}-backup"
  project  = var.project_id
  location = "EU"
  force_destroy = true
}

# Allow the stand-by instance access to the bucket
resource "google_storage_bucket_iam_member" "db_service_account-roles_storage-objectAdmin" {
  bucket = "${google_storage_bucket.backup.name}"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_sql_database_instance.standby.service_account_email_address}"
}

# Cron job for backup and upload.
resource "google_cloud_scheduler_job" "backup_cron" {
  name = "backup_cron_job"

  schedule = "0 2 * * *"
  time_zone = "Europe/Paris"

  http_target {
    uri = "https://www.googleapis.com/sql/v1beta4/projects/${var.project_id}/instances/${google_sql_database_instance.standby.name}/export"
    http_method = "POST"
    body = jsonencode({
      exportContext = {
        database = google_sql_database.main.name,
        uri = "gs://${google_storage_bucket.backup.name}/${google_sql_database_instance.standby.name}-backup-${timestamp()}.gz",
        fileType = "SQL",
        kind = "sql#exportContext",
        offload = true
      }
    })
  }
}

resource "google_monitoring_alert_policy" "usage_alert_policy" {
  display_name = "Usage Alert Policy"
  combiner     = "OR"
  conditions {
    display_name = "Disk Usage"
    condition_threshold {
      filter      = "metric.type=\"cloudsql.googleapis.com/database/disk/bytes_used\" resource.type=\"cloudsql_database\" resource.label.\"database_id\"=\"${google_sql_database_instance.primary.name}\""
      duration    = "60s"
      comparison  = "COMPARISON_GT"
      threshold_value = 0.85
      trigger {
        count = 1
      }
    }
  }
  conditions {
    display_name = "CPU Usage"
    condition_threshold {
      filter      = "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" resource.type=\"cloudsql_database\" resource.label.\"database_id\"=\"${google_sql_database_instance.primary.name}\""
      duration    = "60s"
      comparison  = "COMPARISON_GT"
      threshold_value = 0.9
      trigger {
        count = 1
      }
    }
  }

  notification_channels = ["${google_monitoring_notification_channel.email_alert_channel.id}"]
}

resource "google_monitoring_notification_channel" "email_alert_channel" {
  type     = "email"
  labels   = {
    email_address = var.email
  }
}