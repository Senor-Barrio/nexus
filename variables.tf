variable "s3_bucket" {
  type    = string
  default = "websitedatanexus"
}
variable "iam_instance_profile" {
  type    = string
  default = "s3-nexus-readonly"
}

variable "server_port" {
  description = "The port for HTTP requests"
  default     = 80
}

variable "ssh_port" {
  default = 22
}

variable "instance_count" {
  description = "Number of EC2 instances"
  default     = 1
}