local lsp = {}

lsp.json = require "core.lsp.json"
lsp.jsonrpc = require "core.lsp.jsonrpc"
lsp.transport = require "core.lsp.transport"
lsp.client = require "core.lsp.client"
lsp.process = require "core.lsp.process"
lsp.uri = require "core.lsp.uri"
lsp.position = require "core.lsp.position"

return lsp
