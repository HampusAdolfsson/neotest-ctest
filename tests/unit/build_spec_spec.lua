local assert = require("luassert")
local stub = require("luassert.stub")
local adapter = require("neotest-ctest")
local ctest = require("neotest-ctest.ctest")
local framework = require("neotest-ctest.framework")
local Tree = require("neotest.types").Tree
local it = require("nio").tests.it

adapter.setup({})

describe("adapter.build_spec", function()
  local tree, test_file

  before_each(function()
    test_file = "TEST_test.cpp"
    local positions = {
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 24, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::Suite.First",
          name = "Suite.First",
          path = test_file,
          range = { 4, 0, 4, 41 },
          type = "test",
        },
      },
      {
        {
          id = test_file .. "::Suite.Second",
          name = "Suite.Second",
          path = test_file,
          range = { 8, 0, 11, 1 },
          type = "test",
        },
      },
    }
    tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)

    -- A fake gtest framework module is enough for spec building.
    stub(framework, "detect", function(_)
      return { parse_xml_errors = function(_) return {} end }
    end)
  end)

  it("emits one spec per hosting binary with a combined --gtest_filter", function()
    stub(ctest, "new", function(_, _)
      return {
        test_binary_map = function(_)
          return {
            ["Suite.First"] = { executable = "/bin/FirstTests", cwd = "/bin" },
            ["Suite.Second"] = { executable = "/bin/SecondTests", cwd = "/bin" },
          }
        end,
      }
    end)

    local specs = adapter.build_spec({ tree = tree })

    assert.equals(2, #specs)

    -- Index specs by executable for stable assertions.
    local by_exe = {}
    for _, spec in ipairs(specs) do
      by_exe[spec.command[1]] = spec
    end

    assert.equals("--gtest_filter=Suite.First", by_exe["/bin/FirstTests"].command[2])
    assert.equals("--gtest_filter=Suite.Second", by_exe["/bin/SecondTests"].command[2])
    assert.equals("/bin", by_exe["/bin/FirstTests"].cwd)
    assert.is_true(by_exe["/bin/FirstTests"].command[3]:find("--gtest_output=xml:") ~= nil)
  end)

  it("groups multiple cases hosted by the same binary into one spec", function()
    stub(ctest, "new", function(_, _)
      return {
        test_binary_map = function(_)
          return {
            ["Suite.First"] = { executable = "/bin/AllTests", cwd = "/bin" },
            ["Suite.Second"] = { executable = "/bin/AllTests", cwd = "/bin" },
          }
        end,
      }
    end)

    local specs = adapter.build_spec({ tree = tree })

    assert.equals(1, #specs)
    local filter = specs[1].command[2]
    assert.is_true(filter:find("Suite.First", 1, true) ~= nil)
    assert.is_true(filter:find("Suite.Second", 1, true) ~= nil)
  end)

  it("filters a parameterized suite by wildcard on its namespace", function()
    local positions = {
      {
        id = "TEST_P_test.cpp",
        name = "TEST_P_test.cpp",
        path = "TEST_P_test.cpp",
        range = { 0, 0, 24, 0 },
        type = "file",
      },
      {
        {
          id = "TEST_P_test.cpp::ParameterizedBool.Test",
          name = "ParameterizedBool.Test",
          path = "TEST_P_test.cpp",
          range = { 4, 0, 4, 64 },
          type = "namespace",
        },
        {
          {
            id = "TEST_P_test.cpp::ParameterizedBool.Test::GoogleTest/ParameterizedBool.Test/true",
            name = "GoogleTest/ParameterizedBool.Test/true",
            path = "TEST_P_test.cpp",
            type = "test",
          },
        },
      },
    }
    local ptree = Tree.from_list(positions, function(pos)
      return pos.id
    end)

    stub(ctest, "new", function(_, _)
      return {
        test_binary_map = function(_)
          return {
            -- gtest's real (index-based) instantiated names
            ["GoogleTest/ParameterizedBool.Test/0"] = { executable = "/bin/ParamTests", cwd = "/bin" },
            ["GoogleTest/ParameterizedBool.Test/1"] = { executable = "/bin/ParamTests", cwd = "/bin" },
          }
        end,
      }
    end)

    local specs = adapter.build_spec({ tree = ptree })

    assert.equals(1, #specs)
    assert.equals("--gtest_filter=*ParameterizedBool.Test/*", specs[1].command[2])
  end)

  it("emits a no-op spec when nothing resolves to a binary", function()
    stub(ctest, "new", function(_, _)
      return {
        test_binary_map = function(_)
          return {}
        end,
      }
    end)

    local specs = adapter.build_spec({ tree = tree })

    assert.equals(1, #specs)
    assert.are.same({ "true" }, specs[1].command)
    assert.is_nil(specs[1].context.xml_path)
  end)
end)
