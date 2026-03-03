terraform {
  required_version = ">= 1.5.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.78"
    }
  }
}

provider "digitalocean" {
  # Token is read from the DIGITALOCEAN_TOKEN environment variable
}
