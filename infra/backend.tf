terraform {
  backend "s3" {
    key          = "cloud/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
