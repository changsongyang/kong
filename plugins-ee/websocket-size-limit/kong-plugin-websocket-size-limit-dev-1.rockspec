package = "kong-plugin-websocket-size-limit"
version = "dev-1"

source = {
  url = "https://github.com/Kong/kong-plugin-enterprise-websocket-size-limit",
}

supported_platforms = {"linux", "macosx"}
description = {
  summary = "WebSocket Message Validator for Kong Enterprise",
}

dependencies = {}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.websocket-size-limit.handler"] = "kong/plugins/websocket-size-limit/handler.lua",
    ["kong.plugins.websocket-size-limit.schema"]  = "kong/plugins/websocket-size-limit/schema.lua",
  }
}
