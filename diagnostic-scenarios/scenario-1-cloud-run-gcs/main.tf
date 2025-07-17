terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

resource "google_project_service" "run_api" {
  project = var.project_id
  service = "run.googleapis.com"
  disable_on_destroy = false
}

resource "random_id" "random" {
  byte_length = 4
}

resource "google_storage_bucket" "test_bucket" {
  name     = "test-bucket-${random_id.random.hex}"
  location = var.region
}

resource "google_service_account" "test_sa" {
  account_id   = "test-cloud-run-sa-${random_id.random.hex}"
  display_name = "Test Cloud Run Service Account"
}

resource "google_storage_bucket_iam_member" "gcs_access" {
  bucket = google_storage_bucket.test_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.test_sa.email}"
}

resource "google_cloud_run_v2_service" "hello_world" {
  name     = "test-hello-world-service-${random_id.random.hex}"
  location = var.region

  template {
    service_account = google_service_account.test_sa.email

    volumes {
      name = "gcs-bucket"
      gcs {
        bucket = google_storage_bucket.test_bucket.name
        read_only = false
      }
    }

    containers {
      image = "gcr.io/cloudrun/hello"

      volume_mounts {
        name = "gcs-bucket"
        mount_path = "/mnt/bucket"
      }

      env {
        name  = "BUCKET_NAME"
        value = google_storage_bucket.test_bucket.name
      }
    }
  }

  depends_on = [
    google_storage_bucket_iam_member.gcs_access,
    google_project_service.run_api
  ]
}

data "google_iam_policy" "noauth" {
  binding {
    role    = "roles/run.invoker"
    members = ["allUsers"]
  }
}

resource "google_cloud_run_v2_service_iam_policy" "noauth" {
  project  = google_cloud_run_v2_service.hello_world.project
  location = google_cloud_run_v2_service.hello_world.location
  name     = google_cloud_run_v2_service.hello_world.name
  policy_data = data.google_iam_policy.noauth.policy_data
}
