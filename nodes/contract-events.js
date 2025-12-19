const fs = require('fs');
const path = require('path');

const CONFIG_PATH = process.env.CONFIG_PATH || __dirname;

let block_height_update_timer = null;
let is_active = true;
let contract = null;
let provider = null;

// Function to get file path for storing the last processed block
function get_last_processed_block_file_path(contract_address) {
  return path.join(CONFIG_PATH, contract_address.toLowerCase() + '.last-processed-block');
}

// Function to read last processed block from file
function get_last_processed_block(contract_address) {
  try {
    const filePath = get_last_processed_block_file_path(contract_address);
    const blockHeight = fs.readFileSync(filePath).toString();
    return parseInt(blockHeight);
  } catch (err) {
    return 0;
  }
}

// Function to write last processed block to file
function write_last_processed_block(contract_address, blockHeight) {
  try {
    const filePath = get_last_processed_block_file_path(contract_address);
    fs.writeFileSync(filePath, blockHeight.toString());
  } catch (err) {
    console.error('Error writing last processed block to file:', err);
  }
}

// Retrieve past events from the LLM service contract
async function get_past_events(contract_instance, contract_address, on_contract_event_callback) {
  let start_block = get_last_processed_block(contract_address);
  const last_block = await provider.getBlockNumber();

  if (start_block == 0) {
    return;
  }

  console.log("Reading past events of contract", contract_address, "from block", start_block, "to", last_block);

  // EVM has limits on how many blocks we can query at once (typically 10000)
  const BLOCK_RANGE = 10000;

  while (start_block < last_block) {
    let end_block = start_block + BLOCK_RANGE;
    if (end_block > last_block) end_block = last_block;

    console.log("Fetching events from block", start_block, "to block", end_block);

    try {
      // Query all relevant events in this block range
      const newRequestEvents = await contract_instance.queryFilter(
        contract_instance.filters.NewRequest(),
        start_block,
        end_block
      );

      const nodeAddedEvents = await contract_instance.queryFilter(
        contract_instance.filters.NodeAdded(),
        start_block,
        end_block
      );

      const nodeRemovedEvents = await contract_instance.queryFilter(
        contract_instance.filters.NodeRemoved(),
        start_block,
        end_block
      );

      // Combine and sort all events by block number and log index
      const allEvents = [
        ...newRequestEvents.map(e => ({ ...e, eventName: 'new_request' })),
        ...nodeAddedEvents.map(e => ({ ...e, eventName: 'node_added' })),
        ...nodeRemovedEvents.map(e => ({ ...e, eventName: 'node_removed' }))
      ].sort((a, b) => {
        if (a.blockNumber !== b.blockNumber) {
          return a.blockNumber - b.blockNumber;
        }
        return a.logIndex - b.logIndex;
      });

      // Process each event
      for (const event of allEvents) {
        if (!is_active) return;

        // Convert to a format similar to Aergo events for compatibility
        const normalizedEvent = normalizeEvent(event);
        on_contract_event_callback(normalizedEvent, false);
      }

      if (!is_active) return;

    } catch (err) {
      console.error('Error fetching events from block range:', start_block, 'to', end_block, err);
    }

    start_block += BLOCK_RANGE;
  }

  // Update the last processed block
  write_last_processed_block(contract_address, last_block);
}

// Normalize EVM event to match the expected format
function normalizeEvent(event) {
  let args = [];

  if (event.eventName === 'new_request') {
    // NewRequest(uint256 indexed requestId, uint8 redundancy)
    args = [
      event.args.requestId.toString(),  // Convert BigInt to string
      Number(event.args.redundancy)
    ];
  } else if (event.eventName === 'node_added') {
    // NodeAdded(address indexed node)
    args = [event.args.node];
  } else if (event.eventName === 'node_removed') {
    // NodeRemoved(address indexed node)
    args = [event.args.node];
  }

  return {
    eventName: event.eventName,
    args: args,
    blockno: event.blockNumber,
    txIndex: event.transactionIndex,
    logIndex: event.logIndex,
    txHash: event.transactionHash
  };
}

// Subscribe to new events from the LLM service contract
async function subscribe_to_events(contract_instance, contract_address, on_contract_event_callback) {
  console.log("Subscribing to new events from contract", contract_address, "...");

  // Subscribe to NewRequest events
  contract_instance.on('NewRequest', (requestId, redundancy, event) => {
    if (!is_active) return;

    const normalizedEvent = {
      eventName: 'new_request',
      args: [requestId.toString(), Number(redundancy)],
      blockno: event.log.blockNumber,
      txHash: event.log.transactionHash
    };

    on_contract_event_callback(normalizedEvent, true);
    write_last_processed_block(contract_address, event.log.blockNumber);
  });

  // Subscribe to NodeAdded events
  contract_instance.on('NodeAdded', (node, event) => {
    if (!is_active) return;

    const normalizedEvent = {
      eventName: 'node_added',
      args: [node],
      blockno: event.log.blockNumber,
      txHash: event.log.transactionHash
    };

    on_contract_event_callback(normalizedEvent, true);
    write_last_processed_block(contract_address, event.log.blockNumber);
  });

  // Subscribe to NodeRemoved events
  contract_instance.on('NodeRemoved', (node, event) => {
    if (!is_active) return;

    const normalizedEvent = {
      eventName: 'node_removed',
      args: [node],
      blockno: event.log.blockNumber,
      txHash: event.log.transactionHash
    };

    on_contract_event_callback(normalizedEvent, true);
    write_last_processed_block(contract_address, event.log.blockNumber);
  });
}

// Update block height periodically
async function update_block_height(contract_address) {
  try {
    const blockNumber = await provider.getBlockNumber();
    console.log("Current block:", blockNumber);
    write_last_processed_block(contract_address, blockNumber);
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

