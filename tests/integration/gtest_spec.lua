local assert = require("luassert")
local nio = require("nio")
local it = nio.tests.it
local before_each = nio.tests.before_each
local utils = require("tests.integration.utils")

describe("with TEST macro", function()
  local state, test_file

  before_each(function()
    state = utils.setup()
    test_file = state.example_root .. "/gtest/TEST_test.cpp"
  end)

  it("run single test", function()
    local id = utils.make_neotest_id(test_file, { name = "GoogleTest.Ok" })

    state.neotest.run.run(id)

    local results = state.client:get_results(state.adapter_id)

    assert.equals("passed", results[id].status)
  end)

  it("run multiple tests", function()
    local id = utils.make_neotest_id(test_file)
    local test_ok_id = utils.make_neotest_id(test_file, { name = "GoogleTest.Ok" })
    local test_fail_id = utils.make_neotest_id(test_file, { name = "GoogleTest.Fail" })

    state.neotest.run.run(id)

    local results = state.client:get_results(state.adapter_id)

    assert.equals("failed", results[id].status)
    assert.equals("passed", results[test_ok_id].status)
    assert.equals("failed", results[test_fail_id].status)
  end)
end)

describe("with TEST_F macro", function()
  local state, test_file

  before_each(function()
    state = utils.setup()
    test_file = state.example_root .. "/gtest/TEST_F_test.cpp"
  end)

  it("run single test", function()
    local id = utils.make_neotest_id(test_file, { name = "GoogleTest.Ok" })

    state.neotest.run.run(id)

    local results = state.client:get_results(state.adapter_id)

    assert.equals("passed", results[id].status)
  end)

  it("run multiple tests", function()
    local id = utils.make_neotest_id(test_file)
    local test_ok_id = utils.make_neotest_id(test_file, { name = "GoogleTest.Ok" })
    local test_fail_id = utils.make_neotest_id(test_file, { name = "GoogleTest.Fail" })

    state.neotest.run.run(id)

    local results = state.client:get_results(state.adapter_id)

    assert.equals("failed", results[id].status)
    assert.equals("passed", results[test_ok_id].status)
    assert.equals("failed", results[test_fail_id].status)
  end)
end)

describe("with TEST_P macro", function()
  local state, test_file

  before_each(function()
    state = utils.setup()
    test_file = state.example_root .. "/gtest/TEST_P_test.cpp"
  end)

  -- NOTE: The runner drives the test binary directly and matches results by
  -- gtest's real instantiated names. Because the plugin's discovered parameter
  -- names only approximate those, per-parameter node status is only reliable
  -- for generators whose approximation equals gtest's index-based names
  -- (Range/Values). Parameterized *suite* status is always derived from ground
  -- truth, so we assert on the namespace (suite) node.

  describe("Bool parameter generator", function()
    it("suite fails when any parameter fails", function()
      local id = utils.make_neotest_id(test_file, { name = "ParameterizedBool.Test" })

      state.neotest.run.run(id)

      local results = state.client:get_results(state.adapter_id)

      assert.equals("failed", results[id].status)
    end)
  end)

  describe("Range parameter generator", function()
    it("suite fails and per-parameter results match ground truth", function()
      local id = utils.make_neotest_id(test_file, { name = "ParameterizedRange.Test" })
      local zero_id = utils.make_neotest_id(
        test_file,
        { namespace = "ParameterizedRange.Test", name = "GoogleTest/ParameterizedRange.Test/0" }
      )
      local one_id = utils.make_neotest_id(
        test_file,
        { namespace = "ParameterizedRange.Test", name = "GoogleTest/ParameterizedRange.Test/1" }
      )

      state.neotest.run.run(id)

      local results = state.client:get_results(state.adapter_id)

      assert.equals("failed", results[id].status)
      assert.equals("passed", results[zero_id].status)
      assert.equals("failed", results[one_id].status)
    end)
  end)

  describe("Values parameter generator", function()
    it("suite fails and per-parameter results match ground truth", function()
      local id = utils.make_neotest_id(test_file, { name = "ParameterizedValues.Test" })
      local zero_id = utils.make_neotest_id(
        test_file,
        { namespace = "ParameterizedValues.Test", name = "GoogleTest/ParameterizedValues.Test/0" }
      )
      local one_id = utils.make_neotest_id(
        test_file,
        { namespace = "ParameterizedValues.Test", name = "GoogleTest/ParameterizedValues.Test/1" }
      )

      state.neotest.run.run(id)

      local results = state.client:get_results(state.adapter_id)

      assert.equals("failed", results[id].status)
      assert.equals("passed", results[zero_id].status)
      assert.equals("failed", results[one_id].status)
    end)
  end)

  it("run whole file with parameterized suites", function()
    local id = utils.make_neotest_id(test_file)

    state.neotest.run.run(id)

    local results = state.client:get_results(state.adapter_id)

    assert.equals("failed", results[id].status)
  end)
end)
