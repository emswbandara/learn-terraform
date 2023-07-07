variable "project_id" {
  description = "The project ID to host the cluster in"
  default     = "aqueous-vial-378010"
}

variable "sql_user_password" {
  description = "Password for the SQL user"
  default     = "postgres"
}

variable "email" {
  description = "Email Address for Alerts"
}

variable "ssh_key_path" {
  description = "Path for SSH private key in  your file system. This is needed for remote execution of the pgbench schema initialization in GCP."
}