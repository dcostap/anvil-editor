// Stands in for the preload of the Anvil whose Terminal Session started this Anvil.
// Like that preload in a Pi, it claims the Pi for its own Terminal Session.
process.env.ANVIL_TERMINAL_AGENT_OWNER = String(process.pid);
