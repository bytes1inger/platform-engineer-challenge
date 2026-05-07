variable "repository_name" {
  description = "Name of the ECR repository (e.g. acme/api-service)"
  type        = string
}

variable "image_tag_mutability" {
  description = "Whether image tags can be overwritten (MUTABLE or IMMUTABLE)"
  type        = string
  default     = "IMMUTABLE"
}

variable "scan_on_push" {
  description = "Enable basic vulnerability scanning on every image push"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
