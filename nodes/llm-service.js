const { ethers } = require('ethers');
const process = require('process');
const fs = require('fs');
const { initialize_event_handling } = require('./contract-events.js');
const { process_llm_request } = require('./llm-requests.js');
const { getContent, storeContent } = require('./storage.js');

// Contract ABI - only the functions/events we need
const CONTRACT_ABI = [
  // Events
  "event NewRequest(uint256 indexed requestId, uint8 redundancy)",
  "event Processed(uint256 indexed requestId, bool callbackSuccess)",
  "event ResultSubmitted(uint256 indexed requestId, address indexed node)",
  "event NodeAdded(address indexed node)",
  "event NodeRemoved(address indexed node)",

  // View functions
  "function getAuthorizedNodes() external view returns (address[] memory)",
  "function checkSubmission(uint256 requestId, address nodeAddress) external view returns (string memory)",
  "function getRequestInfo(uint256 requestId) external view returns (tuple(bytes32 platform, bytes32 model, bytes32 prompt, string input, uint8 redundancy, bool returnContentWithinResultTag, bool storeResultOffchain, address caller, string callback, bytes args))",

  // Mutating functions
  "function sendResult(uint256 requestId, string calldata result) external"
];

// Network configurations
const NETWORKS = {
  // Ethereum
  mainnet: {
    rpc: 'https://eth.llamarpc.com',
    contract: '--insert-contract-address-here--'
  },
  sepolia: {
    rpc: 'https://rpc.sepolia.org',
    contract: '--insert-contract-address-here--'
  },
  // Polygon
  polygon: {
    rpc: 'https://polygon-rpc.com',
    contract: '--insert-contract-address-here--'
  },
  mumbai: {
    rpc: 'https://rpc-mumbai.maticvigil.com',
    contract: '--insert-contract-address-here--'
  },
  // Arbitrum
  arbitrum: {
    rpc: 'https://arb1.arbitrum.io/rpc',
    contract: '--insert-contract-address-here--'
  },
  // Base
  base: {
    rpc: 'https://mainnet.base.org',
    contract: '--insert-contract-address-here--'
  },
  // HPP (High Performance Platform)
  'hpp-mainnet': {
    chainId: 190415,
    rpc: 'https://mainnet.hpp.io',
    wss: 'wss://mainnet.hpp.io',
    explorer: 'https://explorer.hpp.io/',
    contract: '--insert-contract-address-here--'
  },
  'hpp-sepolia': {
    chainId: 181228,
    rpc: 'https://sepolia.hpp.io',
    wss: 'wss://sepolia.hpp.io',
    explorer: 'https://sepolia-explorer.hpp.io/',
    contract: '0x671B37bA10efB54C8D4B3bc3297A9C5f99d66194'
  },
  // Local development
  local: {
    rpc: 'http://127.0.0.1:8545',
    contract: process.env.LLM_SERVICE_CONTRACT
  }
};

var provider;
var wallet;
var contract;
var contract_address;
var network_name;

// Node scheduling variables
var myNodeIndex = -1;         // This node's index in the authorized nodes list (0-based)
var numNodes = 0;             // Total number of authorized nodes
const BASE_WAIT_TIME = 60000; // Base wait time in milliseconds (60 seconds)

// Read the command line argument
const args = process.argv.slice(2);
if (args.length == 0 || !NETWORKS[args[0]]) {
  var path = require("path");
  var file = path.basename(process.argv[1]);
  console.log("Usage:");
  console.log("  node", file, "<network>");
  console.log("");
  console.log("Available networks:");
  Object.keys(NETWORKS).forEach(net => console.log("  -", net));
  process.exit(1);
}

network_name = args[0];
const networkConfig = NETWORKS[network_name];

if (network_name === 'local' && !networkConfig.contract) {
  console.error("Environment variable LLM_SERVICE_CONTRACT not set");
  process.exit(1);
}

contract_address = networkConfig.contract;
console.log(`Running on ${network_name} network`);
console.log(`Contract address: ${contract_address}`);

// Initialize provider
provider = new ethers.JsonRpcProvider(networkConfig.rpc);

// Read or generate an account for this node
try {
  const privateKeyHex = fs.readFileSync(__dirname + '/account-evm.data', 'utf8').trim();
  console.log('Reading account from file...');
  wallet = new ethers.Wallet(privateKeyHex, provider);
} catch (err) {
  if (err.code == 'ENOENT') {
    console.log('Generating new account...');
    wallet = ethers.Wallet.createRandom().connect(provider);
    fs.writeFileSync(__dirname + '/account-evm.data', wallet.privateKey);
  } else {
    console.error(err);
    process.exit(1);
  }
}

console.log('Account address:', wallet.address);

// Initialize contract instance
contract = new ethers.Contract(contract_address, CONTRACT_ABI, wallet);

// Helper function to sleep for a given number of milliseconds
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Fetch this node's index from the contract
async function fetch_node_index() {
  let nodes = await contract.getAuthorizedNodes();

  // Handle case where nodes is empty
  if (!nodes || nodes.length === 0) {
    nodes = [];
  }

  numNodes = nodes.length;

  if (nodes.length === 0) {
    myNodeIndex = -1;
    console.log("No authorized nodes found in contract yet");
    return false;
  }

  // Find this wallet's address in the nodes list (case-insensitive comparison)
  myNodeIndex = nodes.findIndex(addr =>
    addr.toLowerCase() === wallet.address.toLowerCase()
  );

  if (myNodeIndex === -1) {
    console.log("This node is not yet authorized in the contract");
    console.log("Waiting for authorization... Node address:", wallet.address);
    return false;
  }

  console.log(`Node authorized! Index: ${myNodeIndex} (out of ${numNodes} nodes)`);
  return true;
}

// Calculate wait time based on position in round-robin for this request
function calculate_wait_time(request_id, redundancy) {
  if (numNodes === 0) return 0;

  // Convert request_id to number if it's a BigInt
  const reqId = typeof request_id === 'bigint' ? Number(request_id) : parseInt(request_id);

  // Determine starting node for this request (round-robin)
  const startNode = reqId % numNodes;

  // Calculate this node's position relative to the start node
  const myPosition = (myNodeIndex - startNode + numNodes) % numNodes;

  // If within redundancy window, no wait needed
  if (myPosition < redundancy) {
    return 0;
  }

  // Otherwise, wait based on how far we are from the redundancy window
  return (myPosition - redundancy + 1) * BASE_WAIT_TIME;
}

// Check if a request is still pending (not yet processed)
async function is_request_pending(request_id) {
  const status = await contract.checkSubmission(request_id, wallet.address);
  return status === "OK";
}

// Resolve content from hash using local storage
function resolveContentFromHash(hash) {
  if (!hash || typeof hash !== 'string') {
    return null;
  }
  // If it's a valid SHA256 hash (64 hex chars), try to retrieve from storage
  if (/^[a-f0-9]{64}$/i.test(hash)) {
    const content = getContent(hash);
    // Convert Buffer to string if needed
    return Buffer.isBuffer(content) ? content.toString('utf8') : content;
  }
  // Otherwise return as-is (might be plain text)
  return hash;
}

// Parse config content in custom format:
// First line (optional): model: platform/model
// Remaining lines (or all lines if no model specified): prompt
function parseConfig(content) {
  if (!content || typeof content !== 'string') {
    return null;
  }

  const lines = content.split('\n');
  if (lines.length < 1) {
    return null;
  }

  const firstLine = lines[0].trim();

  // Check if first line starts with "model: "
  if (firstLine.startsWith('model: ')) {
    // Extract platform/model from first line
    const modelSpec = firstLine.substring(7).trim(); // Remove "model: " prefix
    const slashIndex = modelSpec.indexOf('/');

    if (slashIndex === -1) {
      console.error('Invalid config format: model line must be "model: platform/model"');
      return null;
    }

    const platform = modelSpec.substring(0, slashIndex).trim();
    const model = modelSpec.substring(slashIndex + 1).trim();

    if (!platform || !model) {
      console.error('Invalid config format: platform and model cannot be empty');
      return null;
    }

    // Remaining lines: prompt
    const prompt = lines.slice(1).join('\n');

    return { platform, model, prompt };
  } else {
    // No model specified, entire content is the prompt
    const prompt = content;
    return { platform: null, model: null, prompt };
  }
}

// Build the full prompt from config and user inputs
function buildPrompt(config, inputs) {
  let prompt = config.prompt || '';

  // inputs from Solidity is a JSON string, parse it
  let inputObj = {};
  if (inputs && typeof inputs === 'string' && inputs.length > 0) {
    try {
      inputObj = JSON.parse(inputs);
    } catch (e) {
      console.warn('Failed to parse input JSON:', e.message);
    }
  }

  // Replace placeholders in the prompt with resolved input values
  // Supports {{key}} style placeholders
  if (inputObj && typeof inputObj === 'object') {
    for (const [key, valueHash] of Object.entries(inputObj)) {
      const resolvedValue = resolveContentFromHash(valueHash);
      if (resolvedValue !== null) {
        // Replace {{key}} with the resolved value
        const placeholder = new RegExp(`\\{\\{\\s*${key}\\s*\\}\\}`, 'g');
        prompt = prompt.replace(placeholder, resolvedValue);
      }
    }
  }

  return prompt;
}

// Extract content from within <result></result> tags
function extractResultContent(text) {
  if (!text || typeof text !== 'string') {
    return text;
  }

  // Find opening tag
  const openTag = '<result>';
  const closeTag = '</result>';

  const openTagStart = text.indexOf(openTag);
  if (openTagStart === -1) {
    console.warn('No <result> tag found in response, returning original text');
    return text;
  }

  // Content starts after the opening tag
  const contentStart = openTagStart + openTag.length;

  // Find closing tag (optional - LLM might forget it)
  const closeTagStart = text.indexOf(closeTag, contentStart);

  let content;
  if (closeTagStart === -1) {
    // No closing tag, take everything after opening tag
    content = text.substring(contentStart);
  } else {
    content = text.substring(contentStart, closeTagStart);
  }

  return content.trim();
}

// Convert bytes32 to hex string (for prompt hash)
function bytes32ToHex(bytes32) {
  if (typeof bytes32 === 'string') {
    return bytes32.startsWith('0x') ? bytes32.slice(2) : bytes32;
  }
  return bytes32;
}

// Convert bytes32 to string (removes null padding)
function bytes32ToString(bytes32) {
  if (typeof bytes32 !== 'string') {
    return '';
  }
  // Remove 0x prefix if present
  const hex = bytes32.startsWith('0x') ? bytes32.slice(2) : bytes32;
  // Convert hex to string, stopping at first null byte
  let result = '';
  for (let i = 0; i < hex.length; i += 2) {
    const byte = parseInt(hex.substr(i, 2), 16);
    if (byte === 0) break;
    result += String.fromCharCode(byte);
  }
  return result;
}

// Function to handle LLM request events
async function on_llm_request(event, is_new) {
  try {
    // Skip if this node is not authorized
    if (myNodeIndex === -1) {
      console.log("Ignoring request - this node is not authorized");
      return;
    }

    const request_id = event.args[0];
    const redundancy = event.args[1] || 1;
    console.log(`Received new LLM request with ID: ${request_id}, redundancy: ${redundancy}`);

    // Calculate wait time based on round-robin position
    const waitTime = calculate_wait_time(request_id, redundancy);
    const reqId = typeof request_id === 'bigint' ? Number(request_id) : parseInt(request_id);
    const startNode = reqId % numNodes;
    const myPosition = (myNodeIndex - startNode + numNodes) % numNodes;

    console.log(`My position for request ${request_id}: ${myPosition}, wait time: ${waitTime}ms`);

    // Wait if we're not in the immediate execution group
    if (waitTime > 0) {
      console.log(`Waiting ${waitTime}ms before processing request ${request_id}...`);
      await sleep(waitTime);

      // After waiting, check if request is still pending
      const stillPending = await is_request_pending(request_id);
      if (!stillPending) {
        console.log(`Request ${request_id} already processed, skipping`);
        return;
      }
      console.log(`Request ${request_id} still pending, processing now`);
    }

    // Query the contract to get request details
    const request_info = await contract.getRequestInfo(request_id);
    console.log("Request details:", request_info);

    // caller is at index 7 in the struct
    if (!request_info || request_info[7] === ethers.ZeroAddress) {
      console.error(`No details found for request ID: ${request_id}`);
      return;
    }

    // Extract fields from the tuple (Solidity struct)
    // The struct order: platform, model, prompt, input, redundancy, returnContentWithinResultTag, storeResultOffchain, caller, callback, args
    const platform_from_request = bytes32ToString(request_info[0]);
    const model_from_request = bytes32ToString(request_info[1]);
    const promptHash = bytes32ToHex(request_info[2]);
    const input = request_info[3];
    const req_redundancy = request_info[4];
    const returnContentWithinResultTag = request_info[5];
    const storeResultOffchain = request_info[6];
    const caller = request_info[7];
    const callback = request_info[8];
    const callbackArgs = request_info[9];

    // Retrieve config from storage using the prompt hash
    // Config format: first line is platform/model, rest is the prompt
    const configBuffer = getContent(promptHash);

    if (!configBuffer) {
      console.error(`Config not found in storage for hash: ${promptHash}`);
      return;
    }

    // Convert Buffer to string if needed
    const configContent = Buffer.isBuffer(configBuffer) ? configBuffer.toString('utf8') : configBuffer;
    const config = parseConfig(configContent);
    if (!config) {
      console.error(`Invalid config format for hash: ${promptHash}`);
      return;
    }

    console.log("Retrieved config:", { platform: config.platform, model: config.model, promptLength: config.prompt.length });

    // Get platform and model from config, or fall back to request_info
    let platform = config.platform;
    let model = config.model;

    if (!platform || !model) {
      // Try to get from request_info
      platform = platform || platform_from_request;
      model = model || model_from_request;

      if (!platform || !model) {
        console.error(`Invalid config: missing platform or model in both config and request_info`);
        return;
      }

      console.log("Using platform/model from request_info:", { platform, model });
    }

    // Build the prompt from config and resolve input hashes
    const prompt = buildPrompt(config, input);
    console.log("Built prompt:", prompt.substring(0, 200) + (prompt.length > 200 ? '...' : ''));

    // Process the LLM request
    process_llm_request(platform, model, prompt)
      .then(async result => {
        console.log(`Got result for request ${request_id}:`, result);

        // Extract content from <result> tags if flag is set
        if (returnContentWithinResultTag) {
          result = extractResultContent(result);
          console.log(`Extracted result content: ${result}`);
        }

        // Store result off-chain and return hash if flag is set
        if (storeResultOffchain) {
          const hash = storeContent(result);
          console.log(`Stored result off-chain, hash: ${hash}`);
          result = hash;
        }

        // Final check before submitting (in case another node beat us)
        const stillPending = await is_request_pending(request_id);
        if (!stillPending) {
          console.log(`Request ${request_id} was processed while we were computing, skipping submission`);
          return;
        }

        submit_result(request_id, result);
      })
      .catch(error => {
        console.error(`Error processing LLM request ${request_id}:`, error);
      });
  } catch (error) {
    console.error("Error handling LLM request:", error);
  }
}

// Handle node_added and node_removed events to update state
async function on_node_list_changed(event) {
  console.log(`Node list changed (${event.eventName}), refreshing...`);
  await fetch_node_index();
}

// Function to handle contract events
function on_contract_event(event, is_new) {
  console.log("Received contract event:", event.eventName);

  if (event.eventName === "new_request") {
    on_llm_request(event, is_new);
  } else if (event.eventName === "node_added" || event.eventName === "node_removed") {
    on_node_list_changed(event);
  }
}

// Send the result to the LLM Service smart-contract
async function submit_result(request_id, result) {
  console.log("Sending transaction with result:", result);

  try {
    // Estimate gas for the transaction
    const gasEstimate = await contract.sendResult.estimateGas(request_id, result);

    // Add 20% buffer to gas estimate
    const gasLimit = gasEstimate * 120n / 100n;

    // Send the transaction
    const tx = await contract.sendResult(request_id, result, {
      gasLimit: gasLimit
    });

    console.log("Transaction sent:", tx.hash);

    // Wait for confirmation
    const receipt = await tx.wait();

    console.log("Transaction receipt:", {
      hash: receipt.hash,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed.toString(),
      status: receipt.status
    });

    if (receipt.status === 1) {
      console.log("Successfully submitted result");
    } else {
      console.log("Failed to submit result (transaction reverted)");
    }
    return true;
  } catch (error) {
    console.error("Error submitting result:", error);
    return false;
  }
}

// Initialize and start the LLM service
async function initialize() {
  try {
    // Verify connection to the network
    const network = await provider.getNetwork();
    console.log(`Connected to network: ${network.name} (chainId: ${network.chainId})`);

    // Check account balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`Account balance: ${ethers.formatEther(balance)} ETH`);

    if (balance === 0n) {
      console.warn("Warning: Account has zero balance. You may need to fund it to submit transactions.");
    }

    // Fetch this node's index from the contract (may not be authorized yet)
    await fetch_node_index();

    // Initialize contract event handling (listens for new_request, node_added, node_removed)
    await initialize_event_handling(provider, contract, contract_address, on_contract_event);

    console.log("LLM service initialized and listening for events");
    if (myNodeIndex === -1) {
      console.log("Waiting for this node to be authorized...");
      console.log("Node address:", wallet.address);
    }
  } catch (error) {
    console.error("Initialization error:", error);
    process.exit(1);
  }
}

// Start the LLM service
initialize();
