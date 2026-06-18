local lsp = {}

lsp.json = require "core.lsp.json"
lsp.jsonrpc = require "core.lsp.jsonrpc"
lsp.transport = require "core.lsp.transport"
lsp.client = require "core.lsp.client"
lsp.process = require "core.lsp.process"
lsp.uri = require "core.lsp.uri"
lsp.position = require "core.lsp.position"
lsp.config = require "core.lsp.config"
lsp.documents = require "core.lsp.documents"
lsp.diagnostics = require "core.lsp.diagnostics"
lsp.provider = require "core.lsp.provider"
lsp.manager = require "core.lsp.manager"
lsp.completion = require "core.lsp.completion"

return lsp
