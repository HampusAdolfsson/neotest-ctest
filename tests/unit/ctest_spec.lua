local assert = require("luassert")
local stub = require("luassert.stub")
local ctest = require("neotest-ctest.ctest")
local it = require("nio").tests.it

describe("ctest:new", function()
  local cwd = "/path/to/project"
  local scandir = require("plenary.scandir")
  local lib = require("neotest.lib")

  it("should return valid object when successful", function()
    stub(scandir, "scan_dir", function(_, _)
      return { cwd .. "/CTestTestfiles.cmake" }
    end)
    stub(lib.files, "parent", function(_)
      return cwd
    end)
    stub(ctest, "run", function(_)
      return "3.21.0"
    end)

    local ctest_object = ctest:new(cwd)
    assert.equals(cwd, ctest_object._test_dir)
  end)

  it("should throw error if no test directory found", function()
    stub(scandir, "scan_dir", function(_, _)
      return {}
    end)
    assert.has_error(function()
      ctest:new("/path/to/project")
    end, "Failed to locate CTest test directory")
  end)

  it("should throw error if ctest version is less than 3.21", function()
    stub(scandir, "scan_dir", function(_, _)
      return { cwd .. "/CTestTestfiles.cmake" }
    end)
    stub(ctest, "run", function(_)
      return "3.20.0"
    end)
    assert.has_error(function()
      ctest:new("/path/to/project")
    end, "CTest version 3.21+ is required")
  end)
end)

describe("ctest:testcases", function()
  it("should parse binaries with executable, args and working directory", function()
    stub(ctest, "run", function(_)
      -- NOTE: See: ctest --show-only=json-v1
      -- Each whole test binary is registered as one CTest test in this project.
      return vim.json.encode({
        ["tests"] = {
          {
            ["name"] = "FirstTests",
            ["command"] = { "/bin/FirstTests", "--gtest_output=xml:/tmp/first.xml" },
            ["properties"] = {
              { ["name"] = "WORKING_DIRECTORY", ["value"] = "/bin" },
            },
          },
          {
            ["name"] = "SecondTests",
            ["command"] = { "/bin/SecondTests" },
          },
        },
      })
    end)

    local actual_testcases = ctest:testcases()
    local expected_testcases = {
      ["FirstTests"] = {
        index = 1,
        executable = "/bin/FirstTests",
        args = { "--gtest_output=xml:/tmp/first.xml" },
        cwd = "/bin",
      },
      ["SecondTests"] = {
        index = 2,
        executable = "/bin/SecondTests",
        args = {},
        cwd = nil,
      },
    }

    assert.are.same(expected_testcases, actual_testcases)
  end)
end)

describe("ctest:test_binary_map", function()
  local lib = require("neotest.lib")

  it("maps each Suite.Case to its hosting binary", function()
    stub(ctest, "testcases", function(_)
      return {
        ["FirstTests"] = { index = 1, executable = "/bin/FirstTests", args = {}, cwd = "/bin" },
      }
    end)

    stub(lib.process, "run", function(cmd)
      assert.equals("/bin/FirstTests", cmd[1])
      assert.equals("--gtest_list_tests", cmd[2])
      return 0,
        {
          stdout = table.concat({
            "Running main() from gmock_main.cc",
            "SuiteA.",
            "  Case1",
            "  Case2",
            "SuiteB.",
            "  Case1",
          }, "\n"),
        }
    end)

    local session = { _test_dir = "/unique/test/dir/for/map" }
    setmetatable(session, ctest)
    ctest.__index = ctest

    local map = session:test_binary_map()

    assert.are.same({ executable = "/bin/FirstTests", cwd = "/bin" }, map["SuiteA.Case1"])
    assert.are.same({ executable = "/bin/FirstTests", cwd = "/bin" }, map["SuiteA.Case2"])
    assert.are.same({ executable = "/bin/FirstTests", cwd = "/bin" }, map["SuiteB.Case1"])
  end)
end)

describe("ctest.parse_results", function()
  local lib = require("neotest.lib")

  it("parses passed, failed and skipped cases from gtest XML", function()
    stub(lib.files, "read", function(_)
      return [==[<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="3" failures="1" disabled="1" errors="0" time="0.5" name="AllTests">
  <testsuite name="Suite" tests="3" failures="1" disabled="1" skipped="0" errors="0" time="0.5">
    <testcase name="Ok" status="run" result="completed" time="0.1" classname="Suite" />
    <testcase name="Fail" status="run" result="completed" time="0.2" classname="Suite">
      <failure message="msg" type=""><![CDATA[/path/x.cpp:12: Failure
Value of: false]]></failure>
    </testcase>
    <testcase name="DISABLED_Skip" status="notrun" result="suppressed" time="0" classname="Suite" />
  </testsuite>
</testsuites>]==]
    end)

    local results = ctest.parse_results("/tmp/fake.xml")

    assert.equals("passed", results["Suite.Ok"].status)
    assert.equals("failed", results["Suite.Fail"].status)
    assert.equals("skipped", results["Suite.DISABLED_Skip"].status)
    assert.equals(1, #results["Suite.Fail"].failures)
    assert.is_true(results["Suite.Fail"].failures[1]:find("Failure") ~= nil)
  end)

  it("returns empty table when the XML file is missing", function()
    assert.are.same({}, ctest.parse_results(nil))
  end)
end)
