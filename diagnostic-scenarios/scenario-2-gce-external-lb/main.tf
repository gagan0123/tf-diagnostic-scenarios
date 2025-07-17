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

resource "random_id" "random" {
  byte_length = 4
}

resource "google_compute_instance" "test_vm" {
  name         = "test-lb-vm-${random_id.random.hex}"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["http-health-check"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
    }
  }

  network_interface {
    network = "default"
  }

  metadata = {
    "gce-container-declaration" = "spec:\n  containers:\n    - name: hello-app\n      image: gcr.io/google-samples/hello-app:1.0\n      stdin: false\n      tty: false\n  restartPolicy: Always"
  }
}

resource "google_compute_instance_group" "test_ig" {
  name      = "test-lb-ig-${random_id.random.hex}"
  zone      = var.zone
  instances = [google_compute_instance.test_vm.id]
  named_port {
    name = "http"
    port = "8080"
  }
}

resource "google_compute_health_check" "http_check" {
  name               = "test-lb-http-health-check-${random_id.random.hex}"
  http_health_check {
    port = "8080"
  }
}

resource "google_compute_backend_service" "backend" {
  name          = "test-lb-backend-service-${random_id.random.hex}"
  protocol      = "HTTP"
  port_name     = "http"
  health_checks = [google_compute_health_check.http_check.id]

  backend {
    group = google_compute_instance_group.test_ig.id
  }
}

resource "google_compute_url_map" "url_map" {
  name            = "test-lb-url-map-${random_id.random.hex}"
  default_service = google_compute_backend_service.backend.id
}

resource "google_compute_managed_ssl_certificate" "ssl_cert" {
  name    = "test-lb-ssl-cert-${random_id.random.hex}"
  managed {
    domains = [var.domain_name]
  }
}

resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "test-lb-https-proxy-${random_id.random.hex}"
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.ssl_cert.id]
}

resource "google_compute_global_address" "lb_ip" {
  name = "test-lb-static-ip-${random_id.random.hex}"
}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name       = "test-lb-forwarding-rule-${random_id.random.hex}"
  target     = google_compute_target_https_proxy.https_proxy.id
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "443"
}

resource "google_compute_firewall" "allow_health_check" {
  name    = "test-allow-lb-health-check-${random_id.random.hex}"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["http-health-check"]
}
