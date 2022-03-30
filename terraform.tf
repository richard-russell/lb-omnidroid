terraform {
  cloud {
    organization = "richard-russell-org"

    workspaces {
      name = "aws-omnidroid"
    }
  }
}