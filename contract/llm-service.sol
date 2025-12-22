// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.20;

/**
 * @title LLMService
 * @notice Oracle-style contract for requesting LLM services from authorized off-chain nodes.
 * @dev Users pay a fee to submit requests. Authorized nodes process and return results.
 *      Supports redundancy/quorum - multiple nodes can submit, and consensus triggers callback.
 */
contract LLMService {
    // ============================================================
    //                          TYPES
    // ============================================================

    struct Request {
        bytes32 platform;            // LLM platform (e.g., "openai", "anthropic")
        bytes32 model;               // Model name (e.g., "gpt-4", "claude-3")
        bytes32 prompt;              // SHA256 hash of prompt
        string input;                // JSON input string (serialized from original table)
        uint8 redundancy;            // Number of matching results required
        bool returnContentWithinResultTag; // Whether to extract content from within the <result> tag
        bool storeResultOffchain;    // Whether to store result off-chain and return the hash of the result
        address caller;              // Contract that made the request
        string callback;             // Callback function signature
        bytes args;                  // Encoded callback arguments
    }

    struct Submission {
        address node;
        bytes32 resultHash;          // Hash of the result for comparison
    }

    // ============================================================
    //                       STATE VARIABLES
    // ============================================================

    address public owner;
    address[] public authorizedNodes;
    mapping(address => bool) public isAuthorizedNode;

    // prices[platform][model] = price in wei
    mapping(bytes32 => mapping(bytes32 => uint256)) public prices;
    mapping(bytes32 => mapping(bytes32 => bool)) public priceExists;

    uint256 public lastRequestId;
    mapping(uint256 => Request) public requests;

    // Track submission count per request
    mapping(uint256 => uint256) public submissionCount;
    // submissions[requestId][index] = Submission
    mapping(uint256 => mapping(uint256 => Submission)) public submissions;
    // results[requestId][resultHash] = result
    mapping(uint256 => mapping(bytes32 => string)) public results;

    // ============================================================
    //                          EVENTS
    // ============================================================

    event NewRequest(uint256 indexed requestId, uint8 redundancy);
    event Processed(uint256 indexed requestId, bool callbackSuccess);
    event ResultSubmitted(uint256 indexed requestId, address indexed node);
    event NodeAdded(address indexed node);
    event NodeRemoved(address indexed node);
    event PriceUpdated(bytes32 platform, bytes32 model, uint256 price);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event NodeFunded(address indexed node, uint256 amount);

    // ============================================================
    //                         MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "LLMService: caller is not the owner");
        _;
    }

    modifier onlyAuthorizedNode() {
        require(isAuthorizedNode[msg.sender], "LLMService: not authorized");
        _;
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    constructor() {
        owner = msg.sender;
        lastRequestId = 0;
    }

    // ============================================================
    //                      OWNER FUNCTIONS
    // ============================================================

    /**
     * @notice Transfer ownership to a new address
     * @param newOwner The address of the new owner
     */
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "LLMService: new owner is zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ============================================================
    //                  AUTHORIZED NODES MANAGEMENT
    // ============================================================

    /**
     * @notice Add a new authorized node
     * @param nodeAddress The address to authorize
     */
    function addAuthorizedNode(address nodeAddress) external onlyOwner {
        require(nodeAddress != address(0), "LLMService: node is zero address");
        require(!isAuthorizedNode[nodeAddress], "LLMService: node already authorized");

        authorizedNodes.push(nodeAddress);
        isAuthorizedNode[nodeAddress] = true;
        emit NodeAdded(nodeAddress);
    }

    /**
     * @notice Remove an authorized node
     * @param nodeAddress The address to remove
     */
    function removeAuthorizedNode(address nodeAddress) external onlyOwner {
        require(isAuthorizedNode[nodeAddress], "LLMService: node not authorized");

        isAuthorizedNode[nodeAddress] = false;

        // Remove from array (swap with last and pop)
        uint256 len = authorizedNodes.length;
        for (uint256 i = 0; i < len; i++) {
            if (authorizedNodes[i] == nodeAddress) {
                if (i < len - 1) {
                    authorizedNodes[i] = authorizedNodes[len - 1];
                }
                authorizedNodes.pop();
                break;
            }
        }
        emit NodeRemoved(nodeAddress);
    }

    /**
     * @notice Get all authorized nodes
     * @return Array of authorized node addresses
     */
    function getAuthorizedNodes() external view returns (address[] memory) {
        return authorizedNodes;
    }

    /**
     * @notice Get the number of authorized nodes
     * @return Number of authorized nodes
     */
    function getAuthorizedNodesCount() external view returns (uint256) {
        return authorizedNodes.length;
    }

    // ============================================================
    //                      PRICE FUNCTIONS
    // ============================================================

    /**
     * @notice Set the price for a platform/model combination
     * @param platform The LLM platform name
     * @param model The model name
     * @param price The price in wei
     */
    function setPrice(bytes32 platform, bytes32 model, uint256 price) external onlyOwner {
        prices[platform][model] = price;
        priceExists[platform][model] = true;
        emit PriceUpdated(platform, model, price);
    }

    /**
     * @notice Get the price for a platform/model combination
     * @dev Falls back to default (bytes32(0), bytes32(0)) price if specific price not set
     * @param platform The LLM platform name
     * @param model The model name
     * @return The price in wei
     */
    function getPrice(bytes32 platform, bytes32 model) public view returns (uint256) {
        if (priceExists[platform][model]) {
            return prices[platform][model];
        }
        // Fallback to default price
        return prices[bytes32(0)][bytes32(0)];
    }

    /**
     * @notice Check if a price is configured for platform/model or default
     * @param platform The LLM platform name
     * @param model The model name
     * @return True if price is configured
     */
    function isPriceConfigured(bytes32 platform, bytes32 model) public view returns (bool) {
        return priceExists[platform][model] || priceExists[bytes32(0)][bytes32(0)];
    }

    // ============================================================
    //                      USER FUNCTIONS
    // ============================================================

    /**
     * @notice Submit a new LLM request
     * @param platform LLM platform name
     * @param model Model name
     * @param prompt SHA256 hash of the prompt
     * @param input JSON input string
     * @param callback Callback function signature (e.g., "handleResult(uint256,string)")
     * @param args Encoded callback arguments
     * @param redundancy Number of matching results required (minimum 1)
     * @param returnContentWithinResultTag Whether to extract content from result tag
     * @param storeResultOffchain Whether to store result off-chain
     * @return requestId The ID of the created request
     */
    function newRequest(
        bytes32 platform,
        bytes32 model,
        bytes32 prompt,
        string calldata input,
        uint8 redundancy,
        bool returnContentWithinResultTag,
        bool storeResultOffchain,
        string calldata callback,
        bytes calldata args
    ) external payable returns (uint256 requestId) {
        // Validate caller is a contract (service intended for contract-to-contract calls)
        require(msg.sender != tx.origin, "LLMService: service is for contracts only");

        // Validate redundancy
        require(redundancy >= 1, "LLMService: redundancy must be at least 1");
        require(redundancy <= authorizedNodes.length, "LLMService: redundancy exceeds available nodes");

        // Check price configuration and payment
        require(isPriceConfigured(platform, model), "LLMService: prices not configured");
        uint256 totalPrice = getPrice(platform, model);
        totalPrice = totalPrice * redundancy;
        require(msg.value >= totalPrice, "LLMService: insufficient payment");

        // Create request
        requestId = ++lastRequestId;

        requests[requestId] = Request({
            //payment: msg.value,
            platform: platform,
            model: model,
            prompt: prompt,
            input: input,
            redundancy: redundancy,
            returnContentWithinResultTag: returnContentWithinResultTag,
            storeResultOffchain: storeResultOffchain,
            caller: msg.sender,
            callback: callback,
            args: args
        });

        emit NewRequest(requestId, redundancy);

        // Refund excess payment
        if (msg.value > totalPrice) {
            (bool success, ) = msg.sender.call{value: msg.value - totalPrice}("");
            require(success, "LLMService: refund failed");
        }

        return requestId;
    }

    // ============================================================
    //                      NODE FUNCTIONS
    // ============================================================

    /**
     * @notice Get request information
     * @param requestId The request ID
     * @return The request struct
     */
    function getRequestInfo(uint256 requestId) external view returns (Request memory) {
        return requests[requestId];
    }

    /**
     * @notice Check if a node can submit for a request
     * @param requestId The request ID
     * @param nodeAddress The node address to check
     * @return status "OK", "request not found", "submitted", or "no consensus"
     */
    function checkSubmission(uint256 requestId, address nodeAddress) external view returns (string memory status) {
        require(isAuthorizedNode[nodeAddress], "LLMService: not authorized");

        if (requests[requestId].caller == address(0)) {
            return "request not found";
        }

        uint256 count = submissionCount[requestId];
        for (uint256 i = 0; i < count; i++) {
            if (submissions[requestId][i].node == nodeAddress) {
                return "submitted";
            }
        }

        // Check if all nodes have submitted (no consensus reached)
        if (count >= authorizedNodes.length) {
            return "no consensus";
        }

        return "OK";
    }

    /**
     * @notice Submit a result for a request (only authorized nodes)
     * @param requestId The request ID
     * @param result The result string
     */
    function sendResult(uint256 requestId, string calldata result) external onlyAuthorizedNode {
        Request storage request = requests[requestId];
        require(request.caller != address(0), "request not found");

        // If storeResultOffchain is true, the result is already a hash string
        bytes32 resultHash = request.storeResultOffchain
            ? bytes32(bytes(result))
            : keccak256(abi.encodePacked(result));

        // Get the number of submissions for this request
        uint256 count = submissionCount[requestId];

        // Check for previous submissions from this node
        for (uint256 i = 0; i < count; i++) {
            require(submissions[requestId][i].node != msg.sender, "already submitted");
        }

        // Count matching results
        uint256 numEqual = 1; // Include current submission
        for (uint256 i = 0; i < count; i++) {
            if (submissions[requestId][i].resultHash == resultHash) {
                numEqual++;
            }
        }

        // Check if we have enough matching results
        if (numEqual >= request.redundancy) {
            // Fire callback and clean up
            _fireCallback(requestId, request, result, count);
        } else {
            // Store the submission
            submissions[requestId][count] = Submission({
                node: msg.sender,
                resultHash: resultHash
            });
            submissionCount[requestId] = count + 1;

            // Store result on-chain only if not storing off-chain
            if (!request.storeResultOffchain && bytes(results[requestId][resultHash]).length == 0) {
                results[requestId][resultHash] = result;
            }

            emit ResultSubmitted(requestId, msg.sender);
        }
    }

    /**
     * @dev Fire callback and clean up request state
     * @param requestId The request ID
     * @param request The request struct
     * @param result The result string
     * @param submissionsToClear Number of submissions to clear
     */
    function _fireCallback(
        uint256 requestId,
        Request storage request,
        string memory result,
        uint256 submissionsToClear
    ) internal {
        address caller = request.caller;
        string memory callback = request.callback;
        bytes memory args = request.args;

        // Clear state BEFORE external call (reentrancy protection)
        delete requests[requestId];
        for (uint256 i = 0; i < submissionsToClear; i++) {
            bytes32 hash = submissions[requestId][i].resultHash;
            delete results[requestId][hash];
            delete submissions[requestId][i];
        }
        delete submissionCount[requestId];

        // Fire callback using low-level call
        // Encode: callback signature + requestId + result + original args
        bytes memory callData = abi.encodeWithSignature(
            string(abi.encodePacked(callback, "(uint256,string,bytes)")),
            requestId,
            result,
            args
        );

        // Call without checking success (like pcall in Lua)
        // solhint-disable-next-line avoid-low-level-calls
        (bool callbackSuccess, ) = caller.call(callData);

        emit Processed(requestId, callbackSuccess);
    }

    // ============================================================
    //                    UTILITY FUNCTIONS
    // ============================================================

    /**
     * @notice Withdraw collected fees
     * @param amount Amount to withdraw (0 for full balance)
     * @param recipient Recipient address (zero address defaults to owner)
     */
    function withdrawFees(uint256 amount, address payable recipient) external onlyOwner {
        if (amount == 0) {
            amount = address(this).balance;
        }
        if (recipient == address(0)) {
            recipient = payable(owner);
        }
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "LLMService: withdrawal failed");
    }

    /**
     * @notice Fund authorized nodes to reach a target balance
     * @param targetBalance The desired balance each node should have
     */
    function fundNodes(uint256 targetBalance) external onlyOwner {
        uint256 len = authorizedNodes.length;
        require(len > 0, "LLMService: no authorized nodes");

        for (uint256 i = 0; i < len; i++) {
            address node = authorizedNodes[i];
            uint256 currentBalance = node.balance;

            if (currentBalance < targetBalance) {
                uint256 amountToSend = targetBalance - currentBalance;
                require(address(this).balance >= amountToSend, "LLMService: insufficient contract balance");

                (bool success, ) = node.call{value: amountToSend}("");
                require(success, "LLMService: transfer to node failed");

                emit NodeFunded(node, amountToSend);
            }
        }
    }

    /**
     * @notice Receive function to accept ETH
     */
    receive() external payable {}

    /**
     * @notice Fallback function
     */
    fallback() external payable {}
}

// ============================================================
//                    CALLBACK INTERFACE
// ============================================================

/**
 * @title ILLMServiceCallback
 * @notice Interface that caller contracts should implement to receive LLM results
 */
interface ILLMServiceCallback {
    /**
     * @notice Called by LLMService when a request is processed
     * @param requestId The original request ID
     * @param result The LLM result string
     * @param args The original callback arguments
     */
    function handleLLMResult(uint256 requestId, string calldata result, bytes calldata args) external;
}

// ============================================================
//                    EXAMPLE CALLER CONTRACT
// ============================================================

/**
 * @title LLMServiceCaller
 * @notice Example contract demonstrating how to use the LLM service
 */
contract LLMServiceCaller is ILLMServiceCallback {
    ILLMService public llmService;

    mapping(uint256 => string) public results;

    event LLMRequestSent(uint256 indexed requestId);
    event LLMResultReceived(uint256 indexed requestId, string result);

    constructor(address _llmService) {
        llmService = ILLMService(_llmService);
    }

    /**
     * @notice Send a request to the LLM service
     */
    function askLLM(
        bytes32 platform,
        bytes32 model,
        bytes32 prompt,
        string calldata input
    ) external payable returns (uint256) {
        uint256 requestId = llmService.newRequest{value: msg.value}(
            platform,
            model,
            prompt,
            input,
            1,     // redundancy of 1
            true,  // return content within result tag
            false, // return the whole result to this contract
            "handleLLMResult",
            ""     // no extra args
        );

        emit LLMRequestSent(requestId);
        return requestId;
    }

    /**
     * @notice Callback function called by LLM service
     */
    function handleLLMResult(uint256 requestId, string calldata result, bytes calldata /* args */) external override {
        require(msg.sender == address(llmService), "LLMServiceCaller: unauthorized callback");
        results[requestId] = result;
        emit LLMResultReceived(requestId, result);
    }

    receive() external payable {}
}

// ============================================================
//                    SERVICE INTERFACE
// ============================================================

interface ILLMService {
    function newRequest(
        bytes32 platform,
        bytes32 model,
        bytes32 prompt,
        string calldata input,
        uint8 redundancy,
        bool returnContentWithinResultTag,
        bool storeResultOffchain,
        string calldata callback,
        bytes calldata args
    ) external payable returns (uint256);

    function getPrice(bytes32 platform, bytes32 model) external view returns (uint256);
}
