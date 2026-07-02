local config = require("neotest-ctest.config")
local lib = require("neotest.lib")
local nio = require("nio")
local logger = require("neotest.logging")

local ctest = {}

-- Cache of `Suite.Case -> { executable, cwd }` maps, keyed by CTest test
-- directory. Invalidated whenever the set of test binaries or their mtimes
-- change, so we don't relaunch every binary with --gtest_list_tests on each run.
local binary_map_cache = {}

function ctest:run(args)
  local cmd = { unpack(config.cmd), "--test-dir", self._test_dir, unpack(args) }
  local _, result = lib.process.run(cmd, { stdout = true, stderr = true })

  return result.stdout
end

function ctest:new(cwd)
  local scandir = require("plenary.scandir")

  local ctest_roots = scandir.scan_dir(cwd, {
    respect_gitignore = false,
    depth = 3, -- NOTE: support multi-config projects
    search_pattern = "CTestTestfile.cmake",
    silent = true,
  })

  local test_dir = next(ctest_roots) and lib.files.parent(ctest_roots[1]) or nil

  if not test_dir then
    error("Failed to locate CTest test directory")
  end

  local version = self:run({ "--version" })

  if not version then
    error("Failed to determine CTest version")
  end

  local major, minor, _ = string.match(version, "(%d+)%.(%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  if not ((major > 3) or (major >= 3 and minor >= 21)) then
    error("CTest version 3.21+ is required")
  end

  local session = {
    _test_dir = test_dir,
  }
  setmetatable(session, self)
  self.__index = self
  return session
end

-- Enumerate the test binaries registered with CTest. In this project each whole
-- gtest executable is registered as a single CTest test (not one test per case),
-- so this yields the binaries we later probe with --gtest_list_tests.
function ctest:testcases()
  local testcases = {}

  local output = self:run({ "--show-only=json-v1" })

  if output then
    output = string.gsub(output, "[\n\r]", "")
    local decoded = vim.json.decode(output)

    for index, test in ipairs(decoded.tests) do
      local cmd = test.command or {}

      local cwd
      for _, prop in ipairs(test.properties or {}) do
        if prop.name == "WORKING_DIRECTORY" then
          cwd = prop.value
          break
        end
      end

      testcases[test.name] = {
        index = index,
        executable = cmd[1],
        args = vim.list_slice(cmd, 2),
        cwd = cwd,
      }
    end
  else
    logger.error("neotest-ctest: failed to enumerate tests via 'ctest --show-only=json-v1'")
  end

  return testcases
end

-- Build a signature of the set of binaries + their mtimes, used to invalidate
-- the binary map cache when tests are rebuilt.
local function binaries_signature(binaries)
  local parts = {}
  for _, binary in ipairs(binaries) do
    local stat = vim.loop.fs_stat(binary.executable)
    local mtime = stat and stat.mtime and stat.mtime.sec or 0
    table.insert(parts, binary.executable .. ":" .. mtime)
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

-- Build a `Suite.Case -> { executable, cwd }` map by probing each registered
-- test binary with `--gtest_list_tests`. Results are cached per test directory.
function ctest:test_binary_map()
  local testcases = self:testcases()

  -- Collect the unique set of binaries (a binary hosts many test cases).
  local seen = {}
  local binaries = {}
  for _, testcase in pairs(testcases) do
    if testcase.executable and not seen[testcase.executable] then
      seen[testcase.executable] = true
      table.insert(binaries, { executable = testcase.executable, cwd = testcase.cwd })
    end
  end

  local signature = binaries_signature(binaries)
  local cached = binary_map_cache[self._test_dir]
  if cached and cached.signature == signature then
    return cached.map
  end

  local gtest = require("neotest-ctest.framework.gtest")

  -- Probe all binaries concurrently.
  local jobs = {}
  for _, binary in ipairs(binaries) do
    table.insert(jobs, function()
      local _, result = lib.process.run(
        { binary.executable, "--gtest_list_tests" },
        { stdout = true, stderr = true }
      )
      return { binary = binary, output = result and result.stdout or "" }
    end)
  end

  local outputs = nio.gather(jobs)

  local map = {}
  for _, entry in ipairs(outputs) do
    local names = gtest.parse_list_tests(entry.output)
    for _, name in ipairs(names) do
      if map[name] then
        if map[name].executable ~= entry.binary.executable then
          logger.warn(
            string.format(
              "neotest-ctest: gtest test '%s' found in multiple binaries; keeping '%s'",
              name,
              map[name].executable
            )
          )
        end
      else
        map[name] = { executable = entry.binary.executable, cwd = entry.binary.cwd }
      end
    end
  end

  binary_map_cache[self._test_dir] = { signature = signature, map = map }
  return map
end

-- Parse a gtest XML report (--gtest_output=xml:<path>) into a
-- `Suite.Case -> { status, time, failures }` table. `status` is one of
-- "passed" | "failed" | "skipped"; `failures` is a list of raw failure texts.
function ctest.parse_results(xml_path)
  if not xml_path then
    return {}
  end

  local ok, data = pcall(lib.files.read, xml_path)
  if not ok or not data then
    return {}
  end

  local parsed = lib.xml.parse(data)
  local root = parsed and parsed.testsuites
  if not root then
    return {}
  end

  local suites = root.testsuite
  if not suites then
    return {}
  end
  -- A single <testsuite> is decoded as a table with an _attr field rather than
  -- a list; normalize to a list.
  if suites._attr then
    suites = { suites }
  end

  local results = {}

  for _, suite in ipairs(suites) do
    local cases = suite.testcase
    if cases then
      if cases._attr then
        cases = { cases }
      end

      for _, case in ipairs(cases) do
        local attr = case._attr
        local key = attr.classname .. "." .. attr.name

        -- Collect failure texts. gtest emits one <failure> element per failed
        -- assertion; a single failure is decoded as { "<cdata>", _attr = ... },
        -- multiple as a list of such tables.
        local failure_texts = {}
        local failures = case.failure
        if failures then
          if failures._attr then
            table.insert(failure_texts, failures[1])
          else
            for _, failure in ipairs(failures) do
              table.insert(failure_texts, failure[1])
            end
          end
        end

        local status
        if #failure_texts > 0 then
          status = "failed"
        elseif attr.status == "run" and attr.result == "completed" then
          status = "passed"
        else
          -- notrun / suppressed / disabled
          status = "skipped"
        end

        results[key] = {
          status = status,
          time = tonumber(attr.time) or 0,
          failures = failure_texts,
        }
      end
    end
  end

  return results
end

return ctest
