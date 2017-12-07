-- Copyright (C) Kong Inc.

local BasePlugin = require "kong.plugins.base_plugin"
local nifcloud_v4 = require "kong.plugins.nifcloud-script.v4"
local responses = require "kong.tools.responses"
local utils = require "kong.tools.utils"
local http = require "resty.http"
local cjson = require "cjson.safe"
local public_utils = require "kong.tools.public"

local tostring             = tostring
local ngx_req_read_body    = ngx.req.read_body
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_req_get_headers  = ngx.req.get_headers
local ngx_encode_base64    = ngx.encode_base64

local new_tab
do
  local ok
  ok, new_tab = pcall(require, "table.new")
  if not ok then
    new_tab = function(narr, nrec) return {} end
  end
end

local SSL_PORT = 443

local NifcloudScriptHandler = BasePlugin:extend()

function NifcloudScriptHandler:new()
  NifcloudScriptHandler.super.new(self, "nifcloud-script")
end

function NifcloudScriptHandler:access(conf)
  NifcloudScriptHandler.super.access(self)

  local upstream_body = new_tab(0, 6)

  ngx_req_read_body()

  local body_args = public_utils.get_body_args()
  upstream_body = utils.table_merge(ngx_req_get_uri_args(), body_args)

  local upstream_body_json, err = cjson.encode(upstream_body)
  if not upstream_body_json then
    ngx.log(ngx.ERR, "[nifcloud-script] could not JSON encode upstream body",
                     " to forward request values: ", err)
  end

  local host = "script.api.cloud.nifty.com"
  local path = "/2015-09-01"
  
  local port = conf.port or SSL_PORT
  
  local exec_js = string.gsub(ngx.var.request_uri,"/","")
  local  body_string = string.format("ScriptIdentifier=%s",exec_js)
  body_string = body_string .. "&Header=%7B%7D&Query=%7B%22name%22%3A%22merryChristmasAndHappyNewYear%21%21%22%7D&Method=POST&Body=%7B%7D"

  local opts = {
    region = conf.region,
    service = "SCRIPT",
    method = "POST",
    headers = {
      ["X-Amz-Target"] = "2015-09-01.ExecuteScript",
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Content-Length"] = upstream_body_json and tostring(#upstream_body_json),
    },
    -- body = upstream_body_json,
    body = body_string,
    path = path,
    host = host,
    port = port,
    access_key = conf.access_key,
    secret_key = conf.secret_key,
    query = conf.qualifier and "Qualifier=" .. conf.qualifier
  }

  local request, err = nifcloud_v4(opts)
  if err then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  -- Trigger request
  local client = http.new()
  client:set_timeout(conf.timeout)
  client:connect(host, port)
  local ok, err = client:ssl_handshake()
  if not ok then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  local res, err = client:request {
    method = "POST",
    path = request.url,
    body = request.body,
    headers = request.headers
  }
  if not res then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  local body = res:read_body()
  local headers = res.headers

  local ok, err = client:set_keepalive(conf.keepalive)
  if not ok then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  ngx.status = res.status

  -- Send response to client
  for k, v in pairs(headers) do
    ngx.header[k] = v
  end
  
  ngx.say(body)

  return ngx.exit(res.status)
end

NifcloudScriptHandler.PRIORITY = 749
NifcloudScriptHandler.VERSION = "0.1.0"

return NifcloudScriptHandler
