local test = require "core.test"
local core = require "core"
local config = require "core.config"
local settings = require "plugins.settings"
local Button = require "widget.button"
local TextBox = require "widget.textbox"
local Toggle = require "widget.toggle"

local function find_child(view, class)
  local childs = view.childs
  if view.sections then
    childs = view.sections.panes[1].container.childs
  end
  for _, child in ipairs(childs) do
    if child:is(class) then return child end
  end
end

test.describe("settings", function()
  test.it("opens from a closing Command Palette", function()
    local command = require "core.command"
    settings.ui = nil

    test.ok(command.perform("fuzzy:open_commands"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.results = {{ kind = "command", command = "settings:open" }}
    picker.selected = 1
    picker.open_transition_complete = true
    local old_transitions = config.transitions
    local old_fuzzy_transition = config.disabled_transitions.fuzzy_searcher
    local old_fps = core.fps
    config.transitions = true
    config.disabled_transitions.fuzzy_searcher = false
    core.fps = 60
    picker:confirm(false)

    test.ok(settings.ui)
    test.equal(settings.ui.name, "Settings")
    test.ok(picker.closing)
    test.not_ok(picker.closed)

    picker.close_transition_started_at = system.get_time() - 1
    local ok, err = pcall(function() core.root_panel:update() end)
    config.transitions = old_transitions
    config.disabled_transitions.fuzzy_searcher = old_fuzzy_transition
    core.fps = old_fps
    test.ok(ok, err)

    settings.ui:hide()
  end)

  test.it("uses one theme picker instead of one command per theme", function()
    local command = require "core.command"
    test.ok(command.is_valid("core:select_theme"))
    test.not_ok(command.is_valid("theme:dark"))
  end)

  test.it("shows all themes before the user filters", function()
    local core = require "core"
    local command = require "core.command"
    local bar = core.global_prompt_bar
    bar:exit(true)

    test.ok(command.perform("core:select_theme"))
    test.equal(bar:get_text(), "")
    test.ok(#bar.suggestions > 1, "expected all installed themes")

    bar:exit(true)
  end)

  local old_test_settings
  local old_settings_config
  local old_settings_plugins
  local old_plugin_sections
  local old_test_settings_module

  test.before_each(function()
    old_test_settings = config.plugins.test_settings
    old_settings_config = settings.config
    old_settings_plugins = settings.plugins
    old_plugin_sections = settings.plugin_sections
    old_test_settings_module = package.preload["plugins.test_settings"]
    config.plugins.test_settings = {}
    settings.config = {}
    settings.plugins = {}
    settings.plugin_sections = {}
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.after_each(function()
    config.plugins.test_settings = old_test_settings
    settings.config = old_settings_config
    settings.plugins = old_settings_plugins
    settings.plugin_sections = old_plugin_sections
    package.preload["plugins.test_settings"] = old_test_settings_module
    os.remove(USERDIR .. "/user_settings.lua")
  end)

  test.it("shows standalone config views and persists prefixed values", function()
    local applied
    local view = settings.show_config("Generated Settings", {
      name = "Generated",
      path_prefix = "plugins.test_settings",
      {
        label = "Model",
        path = "model",
        type = settings.type.STRING,
        default = "default",
        get_value = function(value)
          return value .. "-view"
        end,
        set_value = function(value)
          return value .. "-saved"
        end,
        on_apply = function(value)
          applied = value
        end
      }
    })

    test.equal(view.sections, nil)

    local textbox = find_child(view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "default-view")

    textbox:on_change("custom")

    test.equal(config.plugins.test_settings.model, "custom-saved")
    test.equal(settings.config.plugins.test_settings.model, "custom-saved")
    test.equal(applied, "custom-saved")

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.model, "custom-saved")
  end)

  test.it("shows standalone config views with named sections", function()
    local view = settings.show_config("Sectioned Settings", {
      path_prefix = "plugins.test_settings",
      sections = {
        General = {
          {
            label = "Enabled",
            path = "enabled",
            type = settings.type.TOGGLE,
            default = false
          }
        }
      }
    })

    test.not_nil(view.sections)

    local toggle = find_child(view, Toggle)
    test.not_nil(toggle)
    toggle:on_change(true)

    test.equal(config.plugins.test_settings.enabled, true)
    test.equal(settings.config.plugins.test_settings.enabled, true)
  end)

  test.it("opens sub config views from settings options", function()
    local old_show_config = settings.show_config
    local opened_title
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_title = title
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "plugins.test_settings.project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    test.equal(button.label, "Open Preferences")

    button:on_click()
    settings.show_config = old_show_config

    test.equal(opened_title, "Project Preferences")
    test.not_nil(opened_view)

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Demo")

    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
  end)

  test.it("resolves sub config prefixes relative to plugin context", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    }, "test_settings")

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")
    test.equal(config.project, nil)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
  end)

  test.it("inherits plugin paths for sub config views without a prefix", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    }, "test_settings")

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Demo")

    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.name, "Website")
    test.equal(settings.config.plugins.test_settings.name, "Website")
    test.equal(config.name, nil)
  end)

  test.it("resolves sub config prefixes relative to parent prefixes", function()
    local old_show_config = settings.show_config
    local opened_view

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    textbox:on_change("Website")

    test.equal(config.plugins.test_settings.project.name, "Website")
    test.equal(settings.config.plugins.test_settings.project.name, "Website")
    test.equal(config.project, nil)

    local saved = dofile(USERDIR .. "/user_settings.lua")
    test.equal(saved.config.plugins.test_settings.project.name, "Website")
    test.equal(saved.config.project, nil)
  end)

  test.it("loads runtime sub config values into generated views", function()
    local old_show_config = settings.show_config
    local opened_view

    config.plugins.test_settings = {
      project = {
        name = "Website"
      }
    }

    settings.show_config = function(title, spec, context)
      opened_view = old_show_config(title, spec, context)
      return opened_view
    end

    local view = old_show_config("Parent Settings", {
      path_prefix = "plugins.test_settings",
      {
        label = "Open Preferences",
        title = "Project Preferences",
        type = settings.type.SUBCONFIG,
        spec = {
          path_prefix = "project",
          {
            label = "Project Name",
            path = "name",
            type = settings.type.STRING,
            default = "Demo"
          }
        }
      }
    })

    local button = find_child(view, Button)
    test.not_nil(button)
    button:on_click()
    settings.show_config = old_show_config

    local textbox = find_child(opened_view, TextBox)
    test.not_nil(textbox)
    test.equal(textbox:get_text(), "Website")
  end)

  test.it("merges saved plugin sub config values into global config", function()
    package.preload["plugins.test_settings"] = function()
      config.plugins.test_settings.config_spec = {
        name = "Test Settings",
        {
          label = "Open Preferences",
          title = "Project Preferences",
          type = settings.type.SUBCONFIG,
          spec = {
            path_prefix = "project",
            sections = {
              General = {
                {
                  label = "Project Name",
                  path = "name",
                  type = settings.type.STRING,
                  default = "Demo"
                }
              }
            }
          }
        }
      }
      return true
    end

    settings.config = {
      plugins = {
        test_settings = {
          project = {
            name = "Website"
          }
        }
      }
    }

    settings.ui:enable_plugin("test_settings")

    test.equal(config.plugins.test_settings.project.name, "Website")
  end)

end)
