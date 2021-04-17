-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"
local normalize = require("kong.tools.uri").normalize
local ipairs = ipairs


return {
  name         = "routes",
  primary_key  = { "id" },
  endpoint_key = "name",
  workspaceable = true,
  subschema_key = "protocols",

  fields = {
    { id             = typedefs.uuid, },
    { created_at     = typedefs.auto_timestamp_s },
    { updated_at     = typedefs.auto_timestamp_s },
    { name           = typedefs.name },
    { protocols      = { type     = "set",
                         len_min  = 1,
                         required = true,
                         elements = typedefs.protocol,
                         mutually_exclusive_subsets = {
                           { "http", "https" },
                           { "tcp", "tls" },
                           { "grpc", "grpcs" },
                         },
                         default = { "http", "https" }, -- TODO: different default depending on service's scheme
                       }, },
    { methods        = typedefs.methods },
    { hosts          = typedefs.hosts },
    { paths          = typedefs.paths },
    { headers        = typedefs.headers },
    { https_redirect_status_code = { type = "integer",
                                     one_of = { 426, 301, 302, 307, 308 },
                                     default = 426, required = true,
                                   }, },
    { regex_priority = { type = "integer", default = 0 }, },
    { strip_path     = { type = "boolean", default = true }, },
    { path_handling  = { type = "string", default = "v0", one_of = { "v0", "v1" }, }, },
    { preserve_host  = { type = "boolean", default = false }, },
    { snis = { type = "set",
               elements = typedefs.sni }, },
    { sources = typedefs.sources },
    { destinations = typedefs.destinations },
    { tags             = typedefs.tags },
    { service = { type = "foreign", reference = "services" }, },
  },

  entity_checks = {
    { conditional = { if_field = "protocols",
                      if_match = { elements = { type = "string", not_one_of = { "grpcs", "https", "tls" }}},
                      then_field = "snis",
                      then_match = { len_eq = 0 },
                      then_err = "'snis' can only be set when 'protocols' is 'grpcs', 'https' or 'tls'",
                    }},
                  },

  -- TODO: add migrations and remove this in 2.4.0
  transformations = {
    {
      input = { "paths" },
      on_read = function(paths)
        for i, uri in ipairs(paths) do
          paths[i] = normalize(paths[i], true)
        end

        return { paths = paths, }
      end,
    },
  },
}
