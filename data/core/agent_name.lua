-- An Agent Name, such as "brave-otter", is a function of its Terminal Session ID. Revival, Project moves and
-- Machines keep the ID, so they keep the name. Two sessions can get the same name; their IDs still differ.
local M = {}

local ADJECTIVES = {
  "able", "agile", "amber", "ample", "azure", "bold", "brave", "breezy", "bright", "brisk", "bubbly", "calm",
  "candid", "cheery", "chirpy", "clear", "clever", "cosmic", "cozy", "crisp", "cuddly", "curly", "dapper", "daring",
  "deft", "dreamy", "dusky", "eager", "early", "easy", "epic", "fair", "fancy", "fast", "feisty", "fiery", "fine",
  "floral", "fluffy", "frank", "free", "fresh", "frosty", "frugal", "funky", "gentle", "giddy", "glad", "golden",
  "grand", "happy", "hardy", "hazy", "hearty", "honest", "humble", "jazzy", "jolly", "jovial", "keen", "kind",
  "lively", "lofty", "loyal", "lucid", "lucky", "lunar", "mellow", "merry", "mighty", "minty", "misty", "modest",
  "mossy", "neat", "nifty", "nimble", "noble", "peppy", "perky", "placid", "plucky", "poised", "polar", "polite",
  "proud", "quick", "quiet", "quirky", "rapid", "ready", "rosy", "royal", "rugged", "rustic", "sage", "serene",
  "shiny", "silent", "silver", "simple", "sleek", "smart", "smooth", "snappy", "snowy", "social", "solar", "solid",
  "sonic", "spry", "spunky", "stable", "steady", "stoic", "sturdy", "sunlit", "sunny", "super", "swift", "tender",
  "tidy", "timely", "trusty", "upbeat", "urban", "velvet", "vivid", "warm", "wise", "witty", "woolly", "zesty",
}

local ANIMALS = {
  "alpaca", "badger", "bat", "bear", "beaver", "bee", "beetle", "bison", "boar", "bobcat", "camel", "cat", "cicada",
  "clam", "cobra", "condor", "cougar", "coyote", "crab", "crane", "crow", "deer", "dingo", "dodo", "donkey",
  "dove", "duck", "eagle", "eel", "egret", "elk", "emu", "falcon", "ferret", "finch", "fox", "frog", "gecko", "gerbil",
  "gibbon", "goat", "goose", "gopher", "grouse", "hare", "hawk", "heron", "hippo", "hornet", "horse", "hyena", "ibex",
  "ibis", "iguana", "impala", "jackal", "jaguar", "jay", "kiwi", "koala", "lark", "lemur", "lion", "llama", "lynx",
  "macaw", "magpie", "marten", "mink", "minnow", "mole", "moose", "moth", "mouse", "mule", "newt", "orca", "oriole",
  "osprey", "otter", "owl", "ox", "oyster", "panda", "parrot", "pigeon", "pony", "possum", "prawn", "puffin", "puma",
  "python", "quail", "rabbit", "raven", "rhino", "robin", "salmon", "seal", "shark", "sheep", "shrew", "shrimp",
  "skunk", "sloth", "snail", "squid", "stork", "swan", "tapir", "tern", "thrush", "tiger", "toad", "toucan", "trout",
  "tuna", "turtle", "urchin", "vole", "walrus", "wasp", "weasel", "whale", "wolf", "wombat", "wren", "yak", "zebra",
}

-- The Agent Name of a Terminal Session ID, or nil without an ID.
function M.for_terminal(id)
  if type(id) ~= "string" or id == "" then return nil end
  -- Terminal Session IDs are random, so a small hash spreads them evenly. The product stays below 2^53.
  local hash = 0
  for index = 1, #id do hash = (hash * 31 + id:byte(index)) % 2147483647 end
  local adjective = ADJECTIVES[hash % #ADJECTIVES + 1]
  return adjective .. "-" .. ANIMALS[math.floor(hash / #ADJECTIVES) % #ANIMALS + 1]
end

return M
