-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local singletons = require "kong.singletons"


local type = type


local invalidate_cache = function(self, entity, options)
  local consumer = entity.consumer
  if type(consumer) ~= "table" then
    return true
  end

  -- skip next lines in some tests where singletons is not available
  if not singletons.cache then
    return true
  end

  local cache_key = self:cache_key(consumer.id)

  if options and options.no_broadcast_crud_event then
    return singletons.cache:invalidate_local(cache_key)
  else
    return singletons.cache:invalidate(cache_key)
  end
end


local _ACLs = {}


function _ACLs:post_crud_event(operation, entity, options)
  local _, err, err_t = invalidate_cache(self, entity, options)
  if err then
    return nil, err, err_t
  end

  return self.super.post_crud_event(self, operation, entity, options)
end


return _ACLs
