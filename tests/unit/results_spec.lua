local assert = require("luassert")
local stub = require("luassert.stub")
local adapter = require("neotest-ctest")
local ctest = require("neotest-ctest.ctest")
local Tree = require("neotest.types").Tree
local it = require("nio").tests.it

adapter.setup({})

-- Stub the gtest XML parser with the given `Suite.Case -> result` table.
local function stub_results(cases)
  stub(ctest, "parse_results", function(_)
    return cases
  end)
end

describe("position.type == test", function()
  local spec, test_file, positions, tree

  before_each(function()
    test_file = "TEST_test.cpp"
    positions = {
      {
        id = ("%s::%s"):format(test_file, "Suite.First"),
        name = "Suite.First",
        path = test_file,
        range = { 4, 0, 4, 41 },
        type = "test",
      },
    }
    tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)
    spec = {
      context = {
        xml_path = "/tmp/fake.xml",
        node_ids = { ["Suite.First"] = test_file .. "::Suite.First" },
        framework = {
          parse_xml_errors = function(_)
            return {}
          end,
        },
      },
    }
  end)

  it("adapter.results should set status as 'passed' given a passing test", function()
    stub_results({ ["Suite.First"] = { status = "passed", time = 0, failures = {} } })
    local results = adapter.results(spec, nil, tree)
    assert.equals("passed", results[test_file .. "::Suite.First"].status)
  end)

  it("adapter.results should set status as 'failed' given a failing test", function()
    stub_results({ ["Suite.First"] = { status = "failed", time = 0, failures = { "boom" } } })
    local results = adapter.results(spec, nil, tree)
    assert.equals("failed", results[test_file .. "::Suite.First"].status)
  end)

  it("adapter.results should set status as 'skipped' given a skipped test", function()
    stub_results({ ["Suite.First"] = { status = "skipped", time = 0, failures = {} } })
    local results = adapter.results(spec, nil, tree)
    assert.equals("skipped", results[test_file .. "::Suite.First"].status)
  end)

  it("adapter.results should set status as 'skipped' given an unknown test", function()
    -- NOTE: Unknown as in not reported in the XML (e.g. not built / not run)
    stub_results({})
    local results = adapter.results(spec, nil, tree)
    assert.equals("skipped", results[test_file .. "::Suite.First"].status)
  end)
end)

describe("position.type == namespace", function()
  local spec, test_file, namespace, positions, tree

  before_each(function()
    test_file = "TEST_test.cpp"
    namespace = "namespace"
    positions = {
      {
        id = test_file .. "::" .. namespace,
        name = namespace,
        path = test_file,
        range = { 2, 0, 7, 1 },
        type = "namespace",
      },
      {
        {
          id = test_file .. "::" .. namespace .. "::" .. "Suite.First",
          name = "Suite.First",
          path = test_file,
          range = { 4, 0, 4, 41 },
          type = "test",
        },
      },
      {
        {
          id = test_file .. "::" .. namespace .. "::" .. "Suite.Second",
          name = "Suite.Second",
          path = test_file,
          range = { 5, 0, 5, 41 },
          type = "test",
        },
      },
    }
    tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)
    spec = {
      context = {
        xml_path = "/tmp/fake.xml",
        node_ids = {},
        framework = {
          parse_xml_errors = function(_)
            return {}
          end,
        },
      },
    }
  end)

  it("adapter.results should set status as 'passed' given passing tests", function()
    stub_results({
      ["Suite.First"] = { status = "passed", time = 0, failures = {} },
      ["Suite.Second"] = { status = "passed", time = 0, failures = {} },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("passed", results[test_file .. "::" .. namespace].status)
  end)

  it("adapter.results should set status as 'failed' for one or more failing tests", function()
    stub_results({
      ["Suite.First"] = { status = "passed", time = 0, failures = {} },
      ["Suite.Second"] = { status = "failed", time = 0, failures = { "boom" } },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("failed", results[test_file .. "::" .. namespace].status)
  end)

  it("adapter.results should set status as 'skipped' when all tests are skipped", function()
    stub_results({
      ["Suite.First"] = { status = "skipped", time = 0, failures = {} },
      ["Suite.Second"] = { status = "skipped", time = 0, failures = {} },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("skipped", results[test_file .. "::" .. namespace].status)
  end)
end)

describe("parameterized suite (namespace)", function()
  local spec, test_file, tree

  before_each(function()
    test_file = "TEST_P_test.cpp"
    local positions = {
      {
        id = test_file .. "::ParameterizedBool.Test",
        name = "ParameterizedBool.Test",
        path = test_file,
        range = { 4, 0, 4, 64 },
        type = "namespace",
      },
      {
        {
          -- Approximated per-parameter name that does NOT match ground truth.
          id = test_file .. "::ParameterizedBool.Test::GoogleTest/ParameterizedBool.Test/true",
          name = "GoogleTest/ParameterizedBool.Test/true",
          path = test_file,
          range = { 4, 0, 4, 64 },
          type = "test",
        },
      },
    }
    tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)
    spec = {
      context = {
        xml_path = "/tmp/fake.xml",
        node_ids = {},
        framework = { parse_xml_errors = function(_) return {} end },
      },
    }
  end)

  it("derives suite status from ground-truth instantiated cases", function()
    -- gtest reports index-based names, not the approximated /true /false.
    stub_results({
      ["GoogleTest/ParameterizedBool.Test/0"] = { status = "passed", time = 0, failures = {} },
      ["GoogleTest/ParameterizedBool.Test/1"] = { status = "failed", time = 0, failures = { "boom" } },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("failed", results[test_file .. "::ParameterizedBool.Test"].status)
  end)

  it("reports suite as passed when all instantiated cases pass", function()
    stub_results({
      ["GoogleTest/ParameterizedBool.Test/0"] = { status = "passed", time = 0, failures = {} },
      ["GoogleTest/ParameterizedBool.Test/1"] = { status = "passed", time = 0, failures = {} },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("passed", results[test_file .. "::ParameterizedBool.Test"].status)
  end)
end)

describe("position.type == file", function()
  local spec, test_file, positions, tree, namespace

  before_each(function()
    test_file = "TEST_test.cpp"
    namespace = "namespace"
    positions = {
      {
        id = test_file,
        name = test_file,
        path = test_file,
        range = { 0, 0, 24, 0 },
        type = "file",
      },
      {
        {
          id = test_file .. "::" .. namespace,
          name = namespace,
          path = test_file,
          range = { 2, 0, 6, 1 },
          type = "namespace",
        },
        {
          {
            id = test_file .. "::" .. namespace .. "::" .. "Suite.First",
            name = "Suite.First",
            path = test_file,
            range = { 4, 0, 4, 41 },
            type = "test",
          },
        },
      },
      {
        {
          id = test_file .. "::" .. "Suite.Second",
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
    spec = {
      context = {
        xml_path = "/tmp/fake.xml",
        node_ids = {},
        framework = {
          parse_xml_errors = function(_)
            return {}
          end,
        },
      },
    }
  end)

  it("adapter.results should set status as 'passed' given passing tests", function()
    stub_results({
      ["Suite.First"] = { status = "passed", time = 0, failures = {} },
      ["Suite.Second"] = { status = "passed", time = 0, failures = {} },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("passed", results[test_file].status)
  end)

  it("adapter.results should set status as 'failed' for one or more failing tests", function()
    stub_results({
      ["Suite.First"] = { status = "failed", time = 0, failures = { "boom" } },
      ["Suite.Second"] = { status = "passed", time = 0, failures = {} },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("failed", results[test_file].status)
  end)

  it("adapter.results should set status as 'skipped' when all tests are skipped", function()
    stub_results({
      ["Suite.First"] = { status = "skipped", time = 0, failures = {} },
      ["Suite.Second"] = { status = "skipped", time = 0, failures = {} },
    })
    local results = adapter.results(spec, nil, tree)
    assert.equals("skipped", results[test_file].status)
  end)

  describe("contains a namespace with passing tests and a failing non-namespaced test", function()
    it("adapter.results should set namespace status as passed and file status as failed", function()
      stub_results({
        ["Suite.First"] = { status = "passed", time = 0, failures = {} },
        ["Suite.Second"] = { status = "failed", time = 0, failures = { "boom" } },
      })
      local results = adapter.results(spec, nil, tree)
      assert.equals("failed", results[test_file].status)
      assert.equals("passed", results[test_file .. "::" .. namespace].status)
    end)
  end)
end)
