node_prefix "consul" {
  policy = "write"
}

node_prefix "vault" {
  policy = "write"
}

service_prefix "consul" {
  policy = "write"
}

service_prefix "" {
  policy = "read"
}
