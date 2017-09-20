local default_nginx_template = require "kong.templates.nginx"
local kong_nginx_template = require "kong.templates.nginx_kong"
local pl_template = require "pl.template"
local pl_stringx = require "pl.stringx"
local pl_tablex = require "pl.tablex"
local pl_utils = require "pl.utils"
local pl_file = require "pl.file"
local pl_path = require "pl.path"
local pl_dir = require "pl.dir"
local socket = require "socket"
local utils = require "kong.tools.utils"
local log = require "kong.cmd.utils.log"
local constants = require "kong.constants"
local meta = require "kong.meta"
local fmt = string.format

local function gen_default_ssl_cert(kong_config, pair_type)
  -- create SSL folder
  local ok, err = pl_dir.makepath(pl_path.join(kong_config.prefix, "ssl"))
  if not ok then
    return nil, err
  end

  local ssl_cert, ssl_cert_key, ssl_cert_csr
  if pair_type == "admin" then
    ssl_cert = kong_config.admin_ssl_cert_default
    ssl_cert_key = kong_config.admin_ssl_cert_key_default
    ssl_cert_csr = kong_config.admin_ssl_cert_csr_default

  elseif pair_type == "admin_gui" then
    ssl_cert = kong_config.admin_gui_ssl_cert_default
    ssl_cert_key = kong_config.admin_gui_ssl_cert_key_default
    ssl_cert_csr = kong_config.admin_gui_ssl_cert_csr_default

  elseif pair_type == "default" then
    ssl_cert = kong_config.ssl_cert_default
    ssl_cert_key = kong_config.ssl_cert_key_default
    ssl_cert_csr = kong_config.ssl_cert_csr_default

  else
    error("Invalid type " .. pair_type .. " in gen_default_ssl_cert")
  end

  if not pl_path.exists(ssl_cert) and not pl_path.exists(ssl_cert_key) then
    log.verbose("generating %s SSL certificate and key",
                pair_type)

    local passphrase = utils.random_string()
    local commands = {
      fmt("openssl genrsa -des3 -out %s -passout pass:%s 2048", ssl_cert_key, passphrase),
      fmt("openssl req -new -key %s -out %s -subj \"/C=US/ST=California/L=San Francisco/O=Kong/OU=IT Department/CN=localhost\" -passin pass:%s -sha256", ssl_cert_key, ssl_cert_csr, passphrase),
      fmt("cp %s %s.org", ssl_cert_key, ssl_cert_key),
      fmt("openssl rsa -in %s.org -out %s -passin pass:%s", ssl_cert_key, ssl_cert_key, passphrase),
      fmt("openssl x509 -req -in %s -signkey %s -out %s -sha256", ssl_cert_csr, ssl_cert_key, ssl_cert),
      fmt("rm %s", ssl_cert_csr),
      fmt("rm %s.org", ssl_cert_key)
    }
    for i = 1, #commands do
      local ok, _, _, stderr = pl_utils.executeex(commands[i])
      if not ok then
        return nil, "could not generate " .. pair_type .. " SSL certificate: " .. stderr
      end
    end
  else
    log.verbose("%s SSL certificate found at %s", pair_type, ssl_cert)
  end

  return true
end

local function get_ulimit()
  local ok, _, stdout, stderr = pl_utils.executeex "ulimit -n"
  if not ok then
    return nil, stderr
  end
  local sanitized_limit = pl_stringx.strip(stdout)
  if sanitized_limit:lower():match("unlimited") then
    return 65536
  else
    return tonumber(sanitized_limit)
  end
end

local function gather_system_infos(compile_env)
  local infos = {}

  local ulimit, err = get_ulimit()
  if not ulimit then
    return nil, err
  end

  infos.worker_rlimit = ulimit
  infos.worker_connections = math.min(16384, ulimit)

  return infos
end

local function compile_conf(kong_config, conf_template)
  -- computed config properties for templating
  local compile_env = {
    _escape = ">",
    pairs = pairs,
    tostring = tostring
  }

  if kong_config.anonymous_reports and socket.dns.toip(constants.REPORTS.ADDRESS) then
    compile_env["syslog_reports"] = fmt("error_log syslog:server=%s:%d error;",
                                        constants.REPORTS.ADDRESS, constants.REPORTS.SYSLOG_PORT)
  end
  if kong_config.nginx_optimizations then
    local infos, err = gather_system_infos()
    if not infos then
      return nil, err
    end
    compile_env = pl_tablex.merge(compile_env, infos,  true) -- union
  end

  compile_env = pl_tablex.merge(compile_env, kong_config, true) -- union
  compile_env.dns_resolver = table.concat(compile_env.dns_resolver, " ")

  compile_env.http2 = kong_config.http2 and " http2" or ""
  compile_env.admin_http2 = kong_config.admin_http2 and " http2" or ""
  compile_env.proxy_protocol = kong_config.real_ip_header == "proxy_protocol" and " proxy_protocol" or ""

  local post_template = pl_template.substitute(conf_template, compile_env)
  return string.gsub(post_template, "(${%b{}})", function(w)
    local name = w:sub(4, -3)
    return compile_env[name:lower()] or ""
  end)
end

local function compile_kong_conf(kong_config)
  return compile_conf(kong_config, kong_nginx_template)
end

local function compile_nginx_conf(kong_config, template)
  template = template or default_nginx_template
  return compile_conf(kong_config, template)
end

local function prepare_admin(kong_config)
  local ADMIN_GUI_PATH = kong_config.prefix .. "/gui"

  -- if the gui directory does not exist, we needn't bother attempting
  -- to update a non-existant template. this occurs in development
  -- environments where the gui does not exist (it is bundled at build
  -- time), so this effectively serves to quiet useless warnings in kong-ee
  -- development
  if not pl_path.exists(ADMIN_GUI_PATH) then
    return
  end

  local compile_env = {
    ADMIN_API_PORT = tostring(kong_config.admin_port),
    ADMIN_API_SSL_PORT = tostring(kong_config.admin_ssl_port),
    RBAC_ENFORCED = tostring(kong_config.enforce_rbac),
    RBAC_HEADER = tostring(kong_config.rbac_auth_header),
  }

  local idx_filename = ADMIN_GUI_PATH .. "/index.html"
  local tp_filename  = ADMIN_GUI_PATH .. "/index.html.tp-" ..
                       meta._VERSION

  -- make the template if it doesn't exit
  if not pl_path.isfile(tp_filename) then
    if not pl_file.copy(idx_filename, tp_filename) then
      log.warn("Could not copy index to template")
    end
  end

  -- load the template, do our substitutions, and write it out
  local index = pl_file.read(tp_filename)

  if not index then
    log.warn("Could not read GUI index template")
    return
  end

  local _, err
  index, _, err = ngx.re.gsub(index, "{{(.*?)}}", function(m)
          return compile_env[m[1]] end)
  if err then
    log.warn("Error replacing templated values: " .. err)
  end

  pl_file.write(idx_filename, index)
end

local function prepare_prefix(kong_config, nginx_custom_template_path)
  log.verbose("preparing nginx prefix directory at %s", kong_config.prefix)

  if not pl_path.exists(kong_config.prefix) then
    log("prefix directory %s not found, trying to create it", kong_config.prefix)
    local ok, err = pl_dir.makepath(kong_config.prefix)
    if not ok then
      return nil, err
    end
  elseif not pl_path.isdir(kong_config.prefix) then
    return nil, kong_config.prefix .. " is not a directory"
  end

  -- create directories in prefix
  for _, dir in ipairs {"logs", "pids"} do
    local ok, err = pl_dir.makepath(pl_path.join(kong_config.prefix, dir))
    if not ok then
      return nil, err
    end
  end

  -- create log files in case they don't already exist
  if not pl_path.exists(kong_config.nginx_err_logs) then
    local ok, err = pl_file.write(kong_config.nginx_err_logs, "")
    if not ok then
      return nil, err
    end
  end
  if not pl_path.exists(kong_config.nginx_acc_logs) then
    local ok, err = pl_file.write(kong_config.nginx_acc_logs, "")
    if not ok then
      return nil, err
    end
  end
  if not pl_path.exists(kong_config.nginx_admin_acc_logs) then
    local ok, err = pl_file.write(kong_config.nginx_admin_acc_logs, "")
    if not ok then
      return nil, err
    end
  end

  -- generate default SSL certs if needed
  if kong_config.ssl and not kong_config.ssl_cert and not kong_config.ssl_cert_key then
    log.verbose("SSL enabled, no custom certificate set: using default certificate")
    local ok, err = gen_default_ssl_cert(kong_config, "default")
    if not ok then
      return nil, err
    end
    kong_config.ssl_cert = kong_config.ssl_cert_default
    kong_config.ssl_cert_key = kong_config.ssl_cert_key_default
  end
  if kong_config.admin_ssl and not kong_config.admin_ssl_cert and not kong_config.admin_ssl_cert_key then
    log.verbose("Admin SSL enabled, no custom certificate set: using default certificate")
    local ok, err = gen_default_ssl_cert(kong_config, "admin")
    if not ok then
      return nil, err
    end
    kong_config.admin_ssl_cert = kong_config.admin_ssl_cert_default
    kong_config.admin_ssl_cert_key = kong_config.admin_ssl_cert_key_default
  end
  if kong_config.admin_gui_ssl and not kong_config.admin_gui_ssl_cert and
    not kong_config.admin_gui_ssl_cert_key
  then

    log.verbose("Admin GUI SSL enabled, no custom certificate set: " ..
                "using default certificate")
    local ok, err = gen_default_ssl_cert(kong_config, "admin_gui")
    if not ok then
      return nil, err
    end
    kong_config.admin_gui_ssl_cert = kong_config.admin_gui_ssl_cert_default
    kong_config.admin_gui_ssl_cert_key = kong_config.admin_gui_ssl_cert_key_default
  end


  -- check ulimit
  local ulimit, err = get_ulimit()
  if not ulimit then return nil, err
  elseif ulimit < 4096 then
    log.warn([[ulimit is currently set to "%d". For better performance set it]] ..
             [[ to at least "4096" using "ulimit -n"]], ulimit)
  end

  -- compile Nginx configurations
  local nginx_template
  if nginx_custom_template_path then
    if not pl_path.exists(nginx_custom_template_path) then
      return nil, "no such file: " .. nginx_custom_template_path
    end
    nginx_template = pl_file.read(nginx_custom_template_path)
  end

  -- write NGINX conf
  local nginx_conf, err = compile_nginx_conf(kong_config, nginx_template)
  if not nginx_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_conf, nginx_conf)

  -- write Kong's NGINX conf
  local nginx_kong_conf, err = compile_kong_conf(kong_config)
  if not nginx_kong_conf then
    return nil, err
  end
  pl_file.write(kong_config.nginx_kong_conf, nginx_kong_conf)

  -- write kong.conf in prefix (for workers and CLI)
  local buf = {
    "# *************************",
    "# * DO NOT EDIT THIS FILE *",
    "# *************************",
    "# This configuration file is auto-generated. If you want to modify",
    "# the Kong configuration please edit/create the original `kong.conf`",
    "# file. Any modifications made here will be lost.",
    "# Start Kong with `--vv` to show where it is looking for that file.",
    "",
  }

  for k, v in pairs(kong_config) do
    if type(v) == "table" then
      v = table.concat(v, ",")
    end
    if v ~= "" then
      buf[#buf+1] = k .. " = " .. tostring(v)
    end
  end

  pl_file.write(kong_config.kong_env, table.concat(buf, "\n"))

  -- ... yeah this sucks. thanks fwrite.
  local ok, _, _, err = pl_utils.executeex("chmod 640 " .. kong_config.kong_env)
  if not ok then
    log.warn("Unable to set kong env permissions: ", err)
  end

  -- prep the admin gui html based on our config env
  prepare_admin(kong_config)

  return true
end

return {
  prepare_prefix = prepare_prefix,
  compile_kong_conf = compile_kong_conf,
  compile_nginx_conf = compile_nginx_conf,
  gen_default_ssl_cert = gen_default_ssl_cert,
  prepare_admin = prepare_admin,
}
