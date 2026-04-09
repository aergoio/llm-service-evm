const fs = require('fs');
const path = require('path');

const CONFIG_PATH = process.env.CONFIG_PATH || __dirname;

// JSON.stringify drops Infinity (becomes null), which broke logIndex comparisons on restart.
const MAX_PROCESSED_LOG_INDEX = Number.MAX_SAFE_INTEGER;

function normalizeStoredLogIndex(v) {
  if (v === null || v === undefined) return MAX_PROCESSED_LOG_INDEX;
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  return -1;
}

/** Ethers v6 `queryFilter` EventLog uses `index`; `logIndex` is often undefined. */
function eventLogIndex(event) {
  const li = event.logIndex ?? event.index;
  return typeof li === 'number' && Number.isFinite(li) ? li : 0;
}

let gap_fill_timer = null;
let is_active = true;
let contract = null;
let provider = null;
let watched_contract_address = null;
let on_event_callback = null;

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
      const rawLi = 'logIndex' in data ? data.logIndex : -1;
      return {
        block: data.block || 0,
        logIndex: normalizeStoredLogIndex(rawLi)
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

// Find the block at which a contract was deployed using binary search on eth_getCode
async function find_contract_deployment_block(contract_address) {
  let low = 0;
  let high = await provider.getBlockNumber();

  // Verify the contract exists at the current block
  const code = await provider.getCode(contract_address, high);
  if (code === '0x') {
    console.log(`No contract found at ${contract_address}`);
    return 0;
  }

  while (low < high) {
    const mid = Math.floor((low + high) / 2);
    const code = await provider.getCode(contract_address, mid);
    if (code === '0x') {
      low = mid + 1;
    } else {
      high = mid;
    }
  }

  console.log(`Contract ${contract_address.slice(0,10)}... deployed at block ${low}`);
  return low;
}

// Retrieve past events from the contract (for catching up on missed events)
async function get_past_events(contract_instance, contract_address, on_contract_event_callback) {
  // Use the already-initialized lastProcessedBlock (set by initialize_event_handling)
  let start_block = lastProcessedBlock;
  const last_block = await provider.getBlockNumber();

  // If we've never processed events before, start from the contract's deployment block
  if (start_block === 0) {
    start_block = await find_contract_deployment_block(contract_address);
    if (start_block === 0) return;
  }

  // Don't query if we're already at the latest block
  if (start_block > last_block) {
    console.log(`Contract ${contract_address.slice(0,10)}... already up to date at block ${start_block}`);
    return;
  }

  console.log("Reading past events of contract", contract_address, "from block", start_block, "to", last_block);

  // EVM has limits on how many blocks we can query at once (typically 10000)
  const BLOCK_RANGE = 10000;

  let scanCompleted = true;
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
          return eventLogIndex(a) - eventLogIndex(b);
        });

        // Process each event
        for (const event of allEvents) {
          if (!is_active) return;

          const idx = eventLogIndex(event);
          // Skip events we've already processed
          if (event.blockNumber < lastProcessedBlock ||
              (event.blockNumber === lastProcessedBlock && idx <= lastProcessedLogIndex)) {
            continue;
          }

          // Normalize like subscription path: same shape as handle_subscription_event (ethers v6 EventLog)
          const eventName = event.fragment?.name || event.eventName;
          if (!eventName) {
            continue;
          }
          const normalizedEvent = {
            eventName,
            args: event.args,
            blockNumber: event.blockNumber,
            index: idx,
            transactionHash: event.transactionHash
          };

          on_contract_event_callback(normalizedEvent, false);

          // Track the last processed event
          lastProcessedBlock = event.blockNumber;
          lastProcessedLogIndex = idx;
        }
      }

      if (!is_active) return;

    } catch (err) {
      console.error('Error fetching events from block range:', start_block, 'to', end_block, err);
      scanCompleted = false;
      break;
    }

    start_block = end_block + 1;
  }

  // Only advance tail watermark after a full successful scan; otherwise we would skip logs in failed ranges.
  if (scanCompleted && lastProcessedBlock < last_block) {
    lastProcessedBlock = last_block;
    lastProcessedLogIndex = MAX_PROCESSED_LOG_INDEX;
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

  const targetAddress = (await contract_instance.getAddress()).toLowerCase();

  try {
    await contract_instance.on('*', (...cbArgs) => {
      const payload = cbArgs[cbArgs.length - 1];
      const rawLog = payload?.log;
      if (!rawLog) return;

      if (rawLog.address.toLowerCase() !== targetAddress) {
        return;
      }

      const eventName = payload.eventName ?? payload.fragment?.name;
      if (!eventName) {
        return;
      }

      const decodedEvent = {
        eventName,
        args: payload.args,
        blockNumber: rawLog.blockNumber,
        index: rawLog.index,
        transactionHash: rawLog.transactionHash
      };

      handle_subscription_event(decodedEvent, contract_address, on_contract_event_callback);
    });
  } catch (err) {
    console.error('Failed to subscribe to contract events (wildcard):', err.message);
    throw err;
  }

  console.log("Subscribed to all events for contract", contract_address);
}

// Periodic gap-fill: re-runs getLogs from last checkpoint to head (catches missed WS deliveries).
async function periodic_gap_fill() {
  if (!is_active || !contract || !on_event_callback || !watched_contract_address || lastProcessedBlock === 0) {
    gap_fill_timer = setTimeout(periodic_gap_fill, 3 * 60 * 1000);
    return;
  }
  try {
    await get_past_events(contract, watched_contract_address, on_event_callback);
  } catch (err) {
    console.error('Gap-fill error:', err);
  }

  gap_fill_timer = setTimeout(periodic_gap_fill, 3 * 60 * 1000);
}

async function terminate_event_handling() {
  console.log("Terminating event handling...");
  is_active = false;

  if (gap_fill_timer) {
    clearTimeout(gap_fill_timer);
    gap_fill_timer = null;
  }

  if (contract) {
    contract.removeAllListeners();
  }
}

async function initialize_event_handling(provider_instance, contract_instance, contract_address, on_contract_event_callback) {
  // Store references
  provider = provider_instance;
  contract = contract_instance;
  watched_contract_address = contract_address;
  on_event_callback = on_contract_event_callback;

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

  if (!gap_fill_timer) {
    gap_fill_timer = setTimeout(periodic_gap_fill, 3 * 60 * 1000);
  }
}

module.exports = {
  initialize_event_handling,
  terminate_event_handling
};
