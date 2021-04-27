local ffi = require("ffi")

local utils = require('telescope._extensions.bookmarks.utils')

local C = ffi.load('lz4')

-- https://github.com/lz4/lz4/blob/dev/lib/lz4.h#L231
ffi.cdef[[
int LZ4_decompress_safe_partial(
  const char* src,
  char* dst,
  int srcSize,
  int targetOutputSize,
  int dstCapacity
);
]]

local firefox = {}

---Path components to the Firefox profiles directory for the respective OS.
local profiles_path = {
  Darwin = {"Library", "Application Support", "Firefox", "Profiles"},
  Linux = {".mozilla", "firefox"},
  Windows_NT = {"AppData", "Roaming", "Mozilla", "Firefox", "Profiles"},
}

---Names to be excluded from the full bookmark name.
local exclude_names = {"menu", "toolbar"}

---Decompressor for files in Mozilla's "mozLz4" format. Firefox uses this file
---format to compress e.g., bookmark backups (*.jsonlz4).
---
---This file format is in fact just plain LZ4 data with a custom header
---(magic number [8 bytes] and uncompressed file size [4 bytes, little endian]).
---
---File format reference:
---https://hg.mozilla.org/mozilla-central/file/tip/toolkit/components/lz4/lz4.js
---@param filepath string
---@return string
local function decompress_file_content(filepath)
  local file = io.open(filepath, "r")
  if not file then
    error("File does not exist: " .. filepath)
  end

  local src = file:read("*a")
  file:close()
  local src_size = #src
  if src_size < 12 then
    error("Buffer is too short (no header) - Data: " .. src)
  end

  local header = string.sub(src, 1, 8)
  if header ~= "mozLz40\0" then
    error("Invalid header (no magic number) - Header: " .. header)
  end

  local expected_decompressed_size = string.byte(src, 9)
    + bit.lshift(string.byte(src, 10), 8)
    + bit.lshift(string.byte(src, 11), 16)
    + bit.lshift(string.byte(src, 12), 24)

  local output_buffer = ffi.new("char[?]", expected_decompressed_size)
  local actual_decompressed_size = C.LZ4_decompress_safe_partial(
    string.sub(src, 13),
    output_buffer,
    src_size - 12,
    expected_decompressed_size,
    expected_decompressed_size
  )

  if actual_decompressed_size < 0 then
    error("Failed to decompress the data for file: " .. filepath)
  end

  return ffi.string(output_buffer, actual_decompressed_size)
end

---Return the Firefox profile name.
---
---If the user has already provided the profile name, return that otherwise
---default to returning the "*.default-release" or "*.default" (former is
---preferred) for stable version and "*.dev-edition-default" for the developer
---edition.
---
---@param state table
---@param profile_path string
---@return string|nil
local function firefox_profile_name(state, profile_path)
  if state.firefox_profile_name then
    return state.firefox_profile_name
  end

  local dirs
  if state.os_name == "Windows_NT" then
    -- "/b": Only provide the directory/file name
    dirs = utils.get_os_command_output({"dir", "/b", profile_path})
  else
    dirs = utils.get_os_command_output({"ls", profile_path})
  end

  -- Default profile name pattern.
  -- For release edition, the name changed from 'default' to 'default-release'.
  -- https://blog.nightly.mozilla.org/2019/01/14/moving-to-a-profile-per-install-architecture/
  -- NOTE: Order matters (first match is chosen)
  local suffix_pattern = {"default%-release", "default"}
  if state.selected_browser == "firefox_dev" then
    suffix_pattern = {"dev%-edition%-default"}
  end

  local match = {}
  for _, dir in ipairs(dirs) do
    for _, pat in ipairs(suffix_pattern) do
      local matched = string.match(dir, ".*%." .. pat .. "$")
      if matched and matched ~= "" then
        table.insert(match, matched)
      end
    end
  end
  return match[1]
end

---Return the latest bookmark file in the given bookmark directory.
---@param state table
---@param bookmark_dir string
---@return string|nil
local function get_latest_bookmark_file(state, bookmark_dir)
  local files
  if state.os_name == "Windows_NT" then
    -- Sort the output by date/time, in reverse order.
    files = utils.get_os_command_output({"dir", "/b", "/o-d", bookmark_dir})
  else
    files = utils.get_os_command_output({"ls", "-t", bookmark_dir})
  end
  return files[1]
end

---Parse the bookmarks data in a table in the following form:
---{
---  {name = <bookmark name>, url = <bookmark url>},
---  ...,
---}
---@param data table
---@return table
local function parse_bookmarks_data(data)
  local items = {}

  local function insert_items(parent, bookmark)
    local name = ""
    if not vim.tbl_contains(exclude_names, bookmark.title) then
      name = parent ~= "" and parent .. "/" .. bookmark.title or bookmark.title
    end
    if bookmark.type == "text/x-moz-place-container" then
      local children = bookmark.children or {}
      for _, child in ipairs(children) do
        insert_items(name, child)
      end
    elseif bookmark.type == "text/x-moz-place" then
      table.insert(items, {name = name, url = bookmark.uri})
    end
  end

  insert_items("", data)
  return items
end

---Collect all the bookmarks for the Firefox browser.
---@param state table
---@return table
function firefox.collect_bookmarks(state)
  local sep = state.path_sep
  local components = profiles_path[state.os_name]
  local profile_path = state.os_home .. sep .. table.concat(components, sep)
  local profile_name = firefox_profile_name(state, profile_path)

  if not profile_name then
    error("No Firefox profile found at: " .. profile_path)
  end

  local bookmark_dir = profile_path .. sep .. profile_name .. sep .. "bookmarkbackups"
  local bookmark_file = get_latest_bookmark_file(state, bookmark_dir)

  if not bookmark_file then
    error("No Firefox bookmark file found at: " .. bookmark_dir)
  end

  bookmark_file = bookmark_dir .. state.path_sep .. bookmark_file
  local decompressed_data = decompress_file_content(bookmark_file)
  local json_output = vim.fn.json_decode(decompressed_data)
  return parse_bookmarks_data(json_output)
end

return firefox