const fs = require('fs');
const path = require('path');

const CONFIG_PATH = process.env.CONFIG_PATH || __dirname;

let block_height_update_timer = null;
let is_active = true;
let contract = null;
let provider = null;

// Track last processed event to avoid duplicates (block + logIndex uniquely identifies an event)
let lastProcessedBlock = 0;
let lastProcessedLogIndex = -1;

// Function to get file path for storing the last processed block
function get_last_processed_block_file_path(contract_address) {
  return path.join(CONFIG_PATH, contract_address.toLowerCase() + '.last-processed-block');
}

// Function to read last processed event from file
function get_last_processed_event(contract_address) {
  try {
    const filePath = get_last_processed_block_file_path(contract_address);
    const content = fs.readFileSync(filePath, 'utf8');

    // Try to parse as JSON first (new format)
    try {
      const data = JSON.parse(content);
      return {
        block: data.block || 0,
        logIndex: data.logIndex !== undefined ? data.logIndex : -1
      };
    } catch {
      // Fall back to old format (just block number)
      const block = parseInt(content);
      return {
        block: isNaN(block) ? 0 : block,
        logIndex: -1  // Unknown, will re-process events from this block
      };
    }
  } catch (err) {
    return { block: 0, logIndex: -1 };
  }
}

// Function to write last processed event to file
function write_last_processed_event(contract_address, block, logIndex) {
  try {
    const filePath = get_last_processed_block_file_path(contract_address);
    const data = JSON.stringify({ block, logIndex });
    fs.writeFileSync(filePath, data);
  } catch (err) {
    console.error('Error writing last processed event to file:', err);
  }
}

// Retrieve past events from the contract (for catching up on missed events)
async function get_past_events(contract_instance, contract_address, on_contract_event_callback) {
  // Use the already-initialized lastProcessedBlock (set by initialize_event_handling)
  let start_block = lastProcessedBlock;
  const last_block = await provider.getBlockNumber();

  // If we've never processed events before, start from block 1 (skip genesis)
  if (start_block === 0) {
    start_block = 1;
  }

  // Don't query if we're already at the latest block
  if (start_block > last_block) {
    console.log(`Contract ${contract_address.slice(0,10)}... already up to date at block ${start_block}`);
    return;
  }

  console.log("Reading past events of contract", contract_address, "from block", start_block, "to", last_block);

  // EVM has limits on how many blocks we can query at once (typically 10000)
  const BLOCK_RANGE = 10000;

  while (start_block <= last_block) {
    let end_block = start_block + BLOCK_RANGE - 1;
    if (end_block > last_block) end_block = last_block;

    console.log("Fetching events from block", start_block, "to block", end_block);

    try {
      // Query all events at once using wildcard
      const events = await contract_instance.queryFilter('*', start_block, end_block);

      if (events.length > 0) {
        // Sort all events by block number and log index
        const allEvents = events.sort((a, b) => {
          if (a.blockNumber !== b.blockNumber) {
            return a.blockNumber - b.blockNumber;
          }
          return a.logIndex - b.logIndex;
        });

        // Process each event
        for (const event of allEvents) {
          if (!is_active) return;

          // Skip events we've already processed
          if (event.blockNumber < lastProcessedBlock ||
              (event.blockNumber === lastProcessedBlock && event.logIndex <= lastProcessedLogIndex)) {
            continue;
          }

          on_contract_event_callback(event, false);

          // Track the last processed event
          lastProcessedBlock = event.blockNumber;
          lastProcessedLogIndex = event.logIndex;
        }
      }

      if (!is_active) return;

    } catch (err) {
      console.error('Error fetching events from block range:', start_block, 'to', end_block, err);
    }

    start_block = end_block + 1;
  }

  // Update the last processed event (in memory and file)
  // If we processed events, lastProcessedBlock/logIndex are already set
  // If no events, we still need to update to last_block to mark that range as processed
  if (lastProcessedBlock < last_block) {
    lastProcessedBlock = last_block;
    lastProcessedLogIndex = Infinity;  // No events in this block, skip all from subscription
  }
  write_last_processed_event(contract_address, lastProcessedBlock, lastProcessedLogIndex);
}

// Handle a decoded subscription event
function handle_subscription_event(decodedEvent, contract_address, on_contract_event_callback) {
  if (!is_active) return;
  if (!decodedEvent) return;

  const blockNumber = decodedEvent.blockNumber;
  const logIndex = decodedEvent.index ?? 0;

  // Skip events we've already processed (check both block and log index)
  if (blockNumber < lastProcessedBlock ||
      (blockNumber === lastProcessedBlock && logIndex <= lastProcessedLogIndex)) {
    return;
  }

  // Pass to the main event handler
  on_contract_event_callback(decodedEvent, true);

  lastProcessedBlock = blockNumber;
  lastProcessedLogIndex = logIndex;
  write_last_processed_event(contract_address, blockNumber, logIndex);
}

// Subscribe to new events from the contract
async function subscribe_to_events(contract_instance, contract_address, on_contract_event_callback) {
  console.log("Subscribing to events from contract", contract_address, "...");

  // Get the contract address we're subscribing to
  const targetAddress = await contract_instance.getAddress();

  // Use wildcard to listen to all events from this contract
  contract_instance.on("*", (event) => {
    const rawLog = event.log;
    if (!rawLog) return;

    // Filter - only process events from our contract
    if (rawLog.address.toLowerCase() !== targetAddress.toLowerCase()) {
      return;
    }

    // Decode the log using the contract's interface
    try {
      const parsed = contract_instance.interface.parseLog({
        topics: rawLog.topics,
        data: rawLog.data
      });

      if (parsed) {
        const decodedEvent = {
          eventName: parsed.name,
          args: parsed.args,
          blockNumber: rawLog.blockNumber,
          index: rawLog.index,
          transactionHash: rawLog.transactionHash
        };

        handle_subscription_event(decodedEvent, contract_address, on_contract_event_callback);
      }
    } catch (err) {
      // Silently ignore parse errors - event might be from an inherited contract
    }
  });

  console.log("Subscribed to all events for contract", contract_address);
}

// Update block height periodically
async function update_block_height(contract_address) {
  try {
    const blockNumber = await provider.getBlockNumber();
    console.log("Current block:", blockNumber);
    // Update to current block with Infinity logIndex (no events to process)
    // Only update if we haven't processed a more recent event in the meantime
    if (lastProcessedBlock < blockNumber) {
      lastProcessedBlock = blockNumber;
      lastProcessedLogIndex = Infinity;
      write_last_processed_event(contract_address, blockNumber, Infinity);
    }
  } catch (err) {
    console.error('Error updating block height:', err);
  }

  block_height_update_timer = setTimeout(() => {
    update_block_height(contract_address);
  }, 180 * 1000);  // 3 minutes
}

async function terminate_event_handling() {
  console.log("Terminating event handling...");
  is_active = false;

  if (block_height_update_timer) {
    clearTimeout(block_height_update_timer);
  }

  if (contract) {
    contract.removeAllListeners();
  }
}

async function initialize_event_handling(provider_instance, contract_instance, contract_address, on_contract_event_callback) {
  // Store references
  provider = provider_instance;
  contract = contract_instance;

  if (typeof on_contract_event_callback !== 'function') {
    throw new Error('on_contract_event_callback must be a function');
  }

  // Debug: Check provider type
  const providerType = provider_instance.constructor.name;
  console.log(`Provider type: ${providerType}`);

  // Wait for provider to be ready (important for WebSocket)
  try {
    await provider_instance.ready;
    console.log("Provider is ready");
  } catch (e) {
    // Some providers don't have ready, that's OK
  }

  // Initialize from file
  const lastEvent = get_last_processed_event(contract_address);
  lastProcessedBlock = lastEvent.block;
  lastProcessedLogIndex = lastEvent.logIndex;
  console.log(`Initialized contract ${contract_address.slice(0,10)}... from block ${lastProcessedBlock}`);

  // Get past events to process any missed events
  await get_past_events(contract_instance, contract_address, on_contract_event_callback);

  // Subscribe to new events
  await subscribe_to_events(contract_instance, contract_address, on_contract_event_callback);

  // Start periodic block height updates
  update_block_height(contract_address);
}

module.exports = {
  initialize_event_handling,
  terminate_event_handling
};
