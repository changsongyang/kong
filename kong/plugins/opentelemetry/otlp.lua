local pb = require "pb"
local protoc = require "protoc"
local readfile = require "pl.utils".readfile
local new_tab = require "table.new"
local insert = table.insert


local function load_pb()
  local p = protoc.new()
  -- TODO: rel path
  local otlp_proto = assert(readfile("/kong/kong/plugins/opentelemetry/otlp.proto"))
  assert(p:load(otlp_proto))
end


local function to_otlp_span(span)
  assert(type(span) == "table", "invalid span")
  -- TODO: skip is_recording=true spans
  local o_span = {
    trace_id = span.trace_id,
    span_id = span.span_id,
    trace_state = "", -- TODO:
    -- If this is a root span, then this field must be empty. 
    parent_span_id = span.parent_span_id,
    name = span.name,
    kind = span.kind,
    start_time_unix_nano = span.start_timestamp_ms * 1000000,
    end_time_unix_nano = span.end_timestamp_ms * 1000000,
    -- attributes = {},
    -- dropped_attributes_count = {},
    -- events = {},
    -- dropped_events_count = 1,
    -- links = {},
    -- dropped_links_count = 1,
    status = span.status,
  }
  return o_span
end


-- new otlp export request
local function otlp_export_request(spans)
  local req = new_tab(0, 1)
  req.resource_spans = new_tab(1, 0)
  req.resource_spans[1] = {
    instrumentation_library_spans = new_tab(1, 0),
  }
  local lib_spans = {
    spans = new_tab(#spans, 0),
  }
  for _, span in ipairs(spans) do
    local otlp_span = assert(to_otlp_span(span))
    insert(lib_spans.spans, otlp_span)
  end

  req.resource_spans[1].instrumentation_library_spans[1] = lib_spans
  return req
end


-- input: otlp_export_request()
local function to_pb(data)
  return assert(pb.encode("ExportTraceServiceRequest", data))
end


return {
  load_pb = load_pb,
  to_otlp_span = to_otlp_span,
  otlp_export_request = otlp_export_request,
  to_pb = to_pb,
}