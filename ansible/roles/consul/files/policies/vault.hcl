node_prefix "consul" {
  policy = "write"
}

node_prefix "vault" {
  policy = "write"
}

service_prefix "consul" {
  policy = "write"
}

service "vault" {
  policy = "write"
}

service_prefix "" {
  policy = "read"
}

key_prefix "vault/" {
  policy = "write"
}

agent_prefix "" {
  policy = "write"
}

session_prefix "" {
  policy = "write"
}
