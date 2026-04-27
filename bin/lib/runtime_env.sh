require_sheaf_env() {
  local app_root="${1:?app root is required}"

  "$app_root/bin/env" check
}

sheaf_node_name() {
  if [ -n "${SHEAF_NODE_NAME:-}" ]; then
    printf '%s\n' "$SHEAF_NODE_NAME"
    return
  fi

  local node_base="${SHEAF_NODE_BASENAME:-sheaf}"
  local node_host="${SHEAF_NODE_HOST:-$(hostname -s)}"
  printf '%s@%s\n' "$node_base" "$node_host"
}

set_sheaf_elixir_node_args() {
  local node_name="${1:-$(sheaf_node_name)}"
  local node_base="${node_name%%@*}"

  if [[ "$node_name" == *@*.* ]]; then
    SHEAF_ELIXIR_NODE_FLAG="--name"
    SHEAF_ELIXIR_NODE_VALUE="$node_name"
  else
    SHEAF_ELIXIR_NODE_FLAG="--sname"
    SHEAF_ELIXIR_NODE_VALUE="$node_base"
  fi
}

sheaf_rpc_client_name() {
  local target_node="${1:-$(sheaf_node_name)}"
  local client_base="${2:-rpc_$$}"
  local target_host="${target_node#*@}"

  if [[ "$target_node" == *@*.* ]]; then
    printf '%s@%s\n' "$client_base" "$target_host"
  else
    printf '%s\n' "$client_base"
  fi
}

sheaf_cookie_args() {
  local cookie="${ERLANG_COOKIE:-}"

  if [ -z "$cookie" ] && [ -f "$HOME/.erlang.cookie" ]; then
    cookie="$(cat "$HOME/.erlang.cookie")"
  fi

  if [ -n "$cookie" ]; then
    printf '%s\n' "--cookie"
    printf '%s\n' "$cookie"
  fi
}
