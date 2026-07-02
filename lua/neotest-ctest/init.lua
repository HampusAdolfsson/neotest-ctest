local config = require("neotest-ctest.config")
local logger = require("neotest.logging")
local nio = require("nio")

---@type neotest.Adapter
local adapter = { name = "neotest-ctest" }

-- A parameterized suite is discovered as a `namespace` node named
-- "<Suite>.<Test>", while gtest instantiates cases as
-- "<Prefix>/<Suite>.<Test>/<index>". This returns the substring we use to
-- recognize (and filter) the instantiated cases that belong to such a suite.
local function param_suite_infix(namespace_name)
  return "/" .. namespace_name .. "/"
end

-- Find a binary map entry for a parameterized suite namespace, i.e. any
-- ground-truth case that was instantiated from it. Returns nil for ordinary
-- (non-parameterized) namespaces.
local function resolve_param_suite(binary_map, namespace_name)
  local infix = param_suite_infix(namespace_name)
  for gtest_name, entry in pairs(binary_map) do
    if gtest_name:find(infix, 1, true) then
      return entry
    end
  end
  return nil
end

adapter.setup = function(user_config)
  config.setup(user_config)
  return adapter
end

function adapter.root(dir)
  return config.root(dir)
end

function adapter.filter_dir(name, rel_path, root)
  return config.filter_dir(name, rel_path, root)
end

function adapter.is_test_file(file_path)
  return config.is_test_file(file_path)
end

function adapter.discover_positions(path)
  local framework = require("neotest-ctest.framework").detect(path)
  if not framework then
    logger.error("Failed to detect test framework for file: " .. path)
    return
  end

  return framework.parse_positions(path)
end

---@param args neotest.RunArgs
function adapter.build_spec(args)
  local tree = args and args.tree
  if not tree then
    return
  end

  local supported_types = { "test", "namespace", "file" }
  local position = tree:data()
  if not vim.tbl_contains(supported_types, position.type) then
    return
  end

  local cwd = vim.loop.cwd()
  local root = adapter.root(position.path) or cwd

  -- The CMake build tree (where CTest lives) may sit outside the source root.
  local ctest_dir = config.ctest_dir
  if type(ctest_dir) == "function" then
    ctest_dir = ctest_dir(root)
  end
  local ctest = require("neotest-ctest.ctest"):new(ctest_dir or root)
  local framework = require("neotest-ctest.framework").detect(position.path)

  -- Map every discovered gtest case to the binary that hosts it.
  local binary_map = ctest:test_binary_map()

  -- Collect the selected tree's runnable (test) nodes.
  local test_nodes = {}
  for _, node in tree:iter() do
    if node.type == "test" then
      table.insert(test_nodes, node)
    end
  end

  -- DAP strategy: launch the test binary directly under the debugger.
  -- Only supported for a single selected test with dap_adapter configured.
  if args.strategy == "dap" then
    local dap_adapter = config.dap_adapter
    if not dap_adapter then
      vim.notify(
        "neotest-ctest: DAP debugging requested but 'dap_adapter' is not configured. "
          .. "Set dap_adapter = 'codelldb' (or 'cppdbg') in the adapter setup.",
        vim.log.levels.ERROR
      )
      return nil
    end

    if #test_nodes ~= 1 then
      vim.notify("neotest-ctest: DAP debugging supports a single test only.", vim.log.levels.ERROR)
      return nil
    end

    local node = test_nodes[1]
    local entry = binary_map[node.name]
    if not entry then
      vim.notify(
        string.format("neotest-ctest: no gtest binary found for '%s'.", node.name),
        vim.log.levels.ERROR
      )
      return nil
    end

    return {
      cwd = entry.cwd,
      strategy = {
        type = dap_adapter,
        request = "launch",
        name = "Debug gtest",
        program = entry.executable,
        args = { "--gtest_filter=" .. node.name },
        cwd = entry.cwd,
        stopAtEntry = false,
      },
      context = {
        framework = framework,
        node_ids = { [node.name] = node.id },
      },
    }
  end

  -- Group the selected cases by hosting binary. Each binary becomes one RunSpec
  -- invoked with a combined --gtest_filter.
  --
  -- `filters` are the gtest_filter patterns; `node_ids` maps ground-truth
  -- `Suite.Case` names back to position ids (used for exact per-case results).
  local groups = {}
  local function ensure_group(entry)
    local group = groups[entry.executable]
    if not group then
      group = { executable = entry.executable, cwd = entry.cwd, filters = {}, node_ids = {} }
      groups[entry.executable] = group
    end
    return group
  end

  -- First, handle parameterized suites (namespace nodes). Because the plugin's
  -- discovered parameter names only approximate gtest's real instantiated names,
  -- we run the whole suite by a wildcard filter and match results back by
  -- ground truth rather than by the approximated per-parameter node names.
  local param_suites = {}
  for _, node in tree:iter() do
    if node.type == "namespace" then
      local entry = resolve_param_suite(binary_map, node.name)
      if entry then
        local group = ensure_group(entry)
        table.insert(group.filters, "*" .. node.name .. "/*")
        param_suites[node.name] = true
      end
    end
  end

  -- Then handle ordinary test cases by exact ground-truth name.
  for _, node in ipairs(test_nodes) do
    local entry = binary_map[node.name]
    if entry then
      local group = ensure_group(entry)
      table.insert(group.filters, node.name)
      group.node_ids[node.name] = node.id
    else
      -- Silently ignore parameter nodes already covered by a suite filter.
      local covered = false
      for suite_name in pairs(param_suites) do
        if node.name:find(param_suite_infix(suite_name), 1, true) then
          covered = true
          break
        end
      end
      if not covered then
        logger.warn(
          string.format(
            "neotest-ctest: no gtest binary found for '%s' (marked as skipped)",
            node.name
          )
        )
      end
    end
  end

  local extra_args = vim.list_extend(vim.deepcopy(config.extra_args or {}), args.extra_args or {})

  local specs = {}
  for _, group in pairs(groups) do
    local xml_path = nio.fn.tempname()
    local command = {
      group.executable,
      "--gtest_filter=" .. table.concat(group.filters, ":"),
      "--gtest_output=xml:" .. xml_path,
    }
    vim.list_extend(command, extra_args)

    table.insert(specs, {
      command = command,
      cwd = group.cwd,
      context = {
        xml_path = xml_path,
        framework = framework,
        node_ids = group.node_ids,
      },
    })
  end

  -- Nothing resolved to a binary (e.g. tests not built yet). Emit a single
  -- no-op spec so results() still runs and marks the selection as skipped,
  -- instead of neotest falling back to re-running each position individually.
  if #specs == 0 then
    specs = {
      {
        command = { "true" },
        context = { xml_path = nil, framework = framework, node_ids = {} },
      },
    }
  end

  return specs
end

local function prepare_results(tree, testcases, framework, output, node_ids)
  local node = tree:data()
  local results = {}

  if node.type == "file" or node.type == "namespace" then
    local passed = 0
    local failed = 0
    for _, child in pairs(tree:children()) do
      local r = prepare_results(child, testcases, framework, output, node_ids)
      for n, v in pairs(r) do
        results[n] = v
        if v.status == "passed" then
          passed = passed + 1
        elseif v.status == "failed" then
          failed = failed + 1
        end
      end
    end

    -- Parameterized suites: the approximated per-parameter child names may not
    -- match gtest's real instantiated names, so derive the suite's status from
    -- the ground-truth results of every instantiated case that belongs to it.
    if node.type == "namespace" then
      local infix = "/" .. node.name .. "/"
      local gt_passed, gt_failed, gt_any = 0, 0, false
      for key, testcase in pairs(testcases) do
        if key:find(infix, 1, true) then
          gt_any = true
          if testcase.status == "passed" then
            gt_passed = gt_passed + 1
          elseif testcase.status == "failed" then
            gt_failed = gt_failed + 1
          end
        end
      end
      if gt_any then
        passed, failed = gt_passed, gt_failed
      end
    end

    local status = failed > 0 and "failed" or passed > 0 and "passed" or "skipped"
    results[node.id] = { status = status, output = output }
  elseif node.type == "test" then
    local testcase = testcases[node.name]

    if not testcase then
      -- Either not run by this spec, or not known to any binary.
      if node_ids and node_ids[node.name] then
        logger.warn(
          string.format("neotest-ctest: no result reported for '%s' (marked as skipped)", node.name)
        )
      end
      results[node.id] = { status = "skipped" }
    elseif testcase.status == "passed" then
      results[node.id] = {
        status = "passed",
        short = ("Passed in %.6f seconds"):format(testcase.time),
        output = output,
      }
    elseif testcase.status == "failed" then
      local failure_text = table.concat(testcase.failures, "\n")

      local errors = {}
      if framework and framework.parse_xml_errors then
        errors = framework.parse_xml_errors(testcase.failures)

        -- NOTE: Neotest expects 0-based lines.
        for _, error in pairs(errors) do
          if error.line then
            error.line = error.line - 1
          end
        end
      end

      results[node.id] = {
        status = "failed",
        short = failure_text,
        output = output,
        errors = errors,
      }
    else
      results[node.id] = { status = "skipped", output = output }
    end
  end

  return results
end

function adapter.results(spec, process_result, tree)
  local context = spec.context
  local ctest = require("neotest-ctest.ctest")
  local testcases = ctest.parse_results(context.xml_path)
  local output = process_result and process_result.output
  return prepare_results(tree, testcases, context.framework, output, context.node_ids)
end

return adapter
