terraform {
  backend "s3" {
    bucket         = "tf-state-l00187927"
    key            = "global/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
