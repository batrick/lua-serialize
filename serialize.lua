-- serialize.lua -- Serialization system for Lua
-- Copyright (C) 2015  Patrick J. Donnelly (batrick@batbytes.com)
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local _EMPTY = {}

local assert = assert;
local error = error;
local getfenv = getfenv or function() return _EMPTY end;
local getmetatable = getmetatable;
local ipairs = ipairs;
local pairs = pairs;
local pcall = pcall;
local rawset = rawset;
local setmetatable = setmetatable;
local tostring = tostring;
local type = type;
local strdump = string.dump;
local huge = math.huge;

local debug = select(2, pcall(require, "debug")) or {}
local getupvalue = debug.getupvalue or function() return nil end;
local upvalueid = debug.upvalueid or function() return {} end;

local table = require "table"
local concat = table.concat;

module("serialize");

local core_objects;

local REVERSE_T = {};
local MAX_SIZE = {};
local SIZE = {};
local UPVALUES = {};

local function serialize_value(values, v, l)
  local tv = type(v);
  local serialized;
  if tv == "string" then
    serialized = ("%q"):format(v);
  elseif tv == "number" or tv == "boolean" then
    serialized = tostring(v);
  elseif tv == "table" then
    serialized = "\n"..l.." = {}";
    local s = {};
    local prefix = "\n"..l.."[";
    for vkey, vval in pairs(v) do
      s[#s+1] = prefix;
      s[#s+1] = values[vkey];
      s[#s+1] = "] = ";
      s[#s+1] = values[vval];
    end
    local mt = getmetatable(v);
    if mt then
      s[#s+1] = "\nsetmetatable(";
      s[#s+1] = l;
      s[#s+1] = ", ";
      s[#s+1] = values[mt];
      s[#s+1] = ")";
    end
    return serialized, concat(s);
  elseif core_objects[v] then
    serialized = core_objects[v];
  elseif tv == "function" then
    local b, dumped = pcall(strdump, v);
    if not b then -- unknown C function
      serialized = ("%q"):format(tostring(v));
    else
      serialized = ("\n"..l.." = loadstring(%q)"):format(dumped);
      if getupvalue(v, 1) ~= nil then
        local c = {"\n__close(", l};
        local s;
        for i = 1, huge do
          local name, val = getupvalue(v, i);
          if name == nil then
            break;
          end
          local vupv, upv;
          c[#c+1] = ", ";
          if upvalue then -- Is debug.upvalue available?
            upv = upvalueid(v, i);
            vupv = values[UPVALUES][upv];
          end
          if vupv then
            s = s or {};
            s[#s+1] = "\nupvaluejoin(";
            s[#s+1] = l;
            s[#s+1] = ", ";
            s[#s+1] = i;
            s[#s+1] = ", ";
            s[#s+1] = vupv[1];
            s[#s+1] = ", ";
            s[#s+1] = vupv[2];
            s[#s+1] = ")";
            c[#c+1] = "nil";
          else
            values[UPVALUES][upv] = {l, i};
            c[#c+1] = val == nil and "nil" or values[val];
          end
        end
        c[#c+1] = ")";
        if s then
          for _,v in ipairs(s) do
            c[#c+1] = v;
          end
        end
        local env = getfenv(v);
        if env then
          c[#c+1] = "\nsetfenv(";
          c[#c+1] = l;
          c[#c+1] = ", ";
          c[#c+1] = values[env];
          c[#c+1] = ")";
        end
        return serialized, concat(c);
      end
      return serialized;
    end
  else -- thread/unknown C function or userdata
    serialized = ("%q"):format(tostring(v));
  end
  return "\n"..l.." = "..serialized;
end

local values_m = {
  __index = function(t, k)
    if type(k) == "number" then
      if k ~= k then -- nan
        return "0/0";
      else
        t[k] = k;
      end
    else
      local r = t[REVERSE_T];
      local l = #r+1;
      r[l] = ""; -- placeholder
      t[k] = "t["..l.."]";
      local before, after = serialize_value(t, k, t[k]);
      r[l] = before;
      r[#r+1] = after;
    end
    return t[k];
  end,
  __newindex = function(t, k, v)
    t[SIZE] = t[SIZE] + 1;
    if t[SIZE] >= t[MAX_SIZE] then
      error("table has too many entries");
    else
      rawset(t, k, v);
    end
  end,
  __call = function(t, value)
    local v = t[value];
    local r = t[REVERSE_T];
    r[#r+1] = "\nreturn "..v.." end)()\n"
    return concat(r);
  end,
};

--
-- Call this when all modified _G functions are ready
--

local function get_library (lib, prefix, seen)
  seen[lib] = true;
  for k, v in pairs(lib) do
    if type(k) == "string" then
      local t = type(v);
      if t == "function" or t == "userdata" or t == "thread" then
        core_objects[v] = prefix..k;
      elseif t == "table" and not seen[v] then
        get_library(v, prefix..k..".", seen);
      else
      end
    end
  end
end

function loadlibs(_G)
  core_objects = {};
  get_library(_G, "", {});
end

--
-- function "dump"
-- parameters:
--     t = a table to serialize
--     max = max raw values that can be serialized
--

function dump (t, max)
  assert(type(t) == "table", "t must be a table");
  assert(type(max) == "number" or max == nil, "max must be a number");
  if core_objects == nil then
    loadlibs(getfenv(0));
  end
  local values = {
    -- Closure code and starting table t
    [REVERSE_T] = {[[
local select = select;
local loadstring = loadstring;
local setfenv = setfenv or function() end;
local setmetatable = setmetatable;
local setupvalue = debug.setupvalue;
local upvaluejoin = debug.upvaluejoin or function () end;
local function __close(f, ...)
  for i = 1, select("#", ...) do
    setupvalue(f, i, (select(i, ...)));
  end
end

return (function()

local t = {}]]},
    [MAX_SIZE] = max or 1e4, -- 10 000 default
    [SIZE] = 0,
    [UPVALUES] = {},
    [dump] = "serialize.dump", -- so it can't serialize itself
    [loadlibs] = "serialize.loadlibs",
    [1/0] = "1/0", -- math.huge (infinity)
  };
  setmetatable(values, values_m);

  return values(t);
end

return _M;
