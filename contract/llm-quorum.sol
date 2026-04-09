// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.20;

import {ILLMService, IERC20, RequestArgs} from "./llm-service.sol";

/**
 * @title LLMQuorum
 * @notice Contract for requesting LLM services with consensus across multiple different models.
 * @dev Instead of checking consensus between different nodes running the same model
 *      (like LLMService), this contract sends the same request to multiple different
 *      models and checks consensus between their responses.
 *      It delegates the actual LLM processing to the LLMService contract.
 *
 *      Payment:
 *      - approve + newRequest (transferFrom), or
 *      - token.transferAndCall(quorum, amount, abi.encode(QuorumRequestArgs)) → onTokenTransfer
 */
contract LLMQuorum {
    // ============================================================
    //                          TYPES
    // ============================================================

    struct ModelInfo {
        bytes32 platform;  // e.g., "openai", "anthropic", "google"
        bytes32 model;     // e.g., "gpt-4", "claude-3", "gemini-pro"
    }

    /**
     * @notice Arguments for newRequest and ERC-20 transferAndCall payloads
     * @dev Field semantics match the previous per-parameter docs on newRequest (pre-struct API).
     */
    struct QuorumRequestArgs {
        /// @notice SHA256 hash of the prompt
        bytes32 prompt;
        /// @notice JSON input string
        string input;
        /// @notice Array of models to query
        ModelInfo[] models;
        /// @notice Number of matching results required (0 = majority)
        uint8 quorumThreshold;
        /// @notice Number of node confirmations per model
        uint8 redundancy;
        /// @notice Whether to extract content from result tag
        bool returnContentWithinResultTag;
        /// @notice Whether to store result off-chain
        bool storeResultOffchain;
        /// @notice Callback function signature
        string callback;
        /// @notice Encoded callback arguments
        bytes args;
    }

    struct QuorumRequest {
        address caller;           // Contract that made the request
        string callback;          // Callback function signature
        bytes args;               // Original callback arguments
        uint8 quorumThreshold;    // Number of matching results required
        uint8 resultsReceived;    // Number of results received so far
        bool storeResultOffchain; // Whether result is stored off-chain (result is already a hash)
    }

    // ============================================================
    //                       STATE VARIABLES
    // ============================================================

    address public owner;
    ILLMService public llmService;

    uint256 public lastRequestId;
    mapping(uint256 => QuorumRequest) public requests;

    // requestId -> index -> result hash
    mapping(uint256 => mapping(uint256 => bytes32)) public resultHashes;

    // requestId -> resultHash -> result string (store one result per unique hash)
    mapping(uint256 => mapping(bytes32 => string)) public resultsByHash;

    // requestId -> resultHash -> count of matching results
    mapping(uint256 => mapping(bytes32 => uint256)) public resultCounts;

    // ============================================================
    //                          EVENTS
    // ============================================================

    event NewQuorumRequest(uint256 indexed requestId, uint8 numModels, uint8 quorumThreshold);
    event QuorumReached(uint256 indexed requestId, bool callbackSuccess);
    event SubResultReceived(uint256 indexed requestId, uint256 subRequestId);
    event LLMServiceUpdated(address indexed newService);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ============================================================
    //                         MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "LLMQuorum: caller is not the owner");
        _;
    }

    modifier onlyLLMService() {
        require(msg.sender == address(llmService), "LLMQuorum: only LLM service can call");
        _;
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    constructor(address _llmService) {
        owner = msg.sender;
        lastRequestId = 0;
        if (_llmService != address(0)) {
            llmService = ILLMService(_llmService);
        }
    }

    // ============================================================
    //                      OWNER FUNCTIONS
    // ============================================================

    /**
     * @notice Transfer ownership to a new address
     * @param newOwner The address of the new owner
     */
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "LLMQuorum: new owner is zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @notice Set the LLM service contract address
     * @param serviceAddress The address of the LLM service contract
     */
    function setLLMService(address serviceAddress) external onlyOwner {
        require(serviceAddress != address(0), "LLMQuorum: service is zero address");
        llmService = ILLMService(serviceAddress);
        emit LLMServiceUpdated(serviceAddress);
    }

    /**
     * @notice Get the LLM service contract address
     * @return The address of the LLM service contract
     */
    function getLLMService() external view returns (address) {
        return address(llmService);
    }

    // ============================================================
    //                      PRICE FUNCTIONS
    // ============================================================

    /**
     * @notice Get total price for a list of models in `token` smallest units
     * @param models Array of ModelInfo structs
     * @param redundancy Number of node confirmations per model (default 1)
     * @param token Payment token (must be accepted on LLMService with non-zero ratio)
     */
    function getPrice(
        ModelInfo[] calldata models,
        uint8 redundancy,
        address token
    ) external view returns (uint256 totalPrice) {
        require(address(llmService) != address(0), "LLMQuorum: service not configured");
        require(models.length >= 1, "LLMQuorum: at least one model required");

        if (redundancy == 0) redundancy = 1;

        for (uint256 i = 0; i < models.length; i++) {
            (uint256 modelPrice, uint8 psi) = llmService.getPriceInToken(models[i].platform, models[i].model, token);
            require(psi == 0, "LLMQuorum: token not accepted or price not configured");
            totalPrice += modelPrice * redundancy;
        }

        return totalPrice;
    }

    // ============================================================
    //                      USER FUNCTIONS
    // ============================================================

    /**
     * @notice Callback for ERC-20 transferAndCall (e.g. ERC-677 / Arbitrum-style)
     * @dev msg.sender must be the payment token. Tokens are already in this contract; `from` is the logical caller (must be a contract).
     *      `data` must be abi.encode(QuorumRequestArgs).
     */
     function onTokenTransfer(address from, uint256 amount, bytes calldata data) external {
        address token = msg.sender;
        QuorumRequestArgs memory req = abi.decode(data, (QuorumRequestArgs));
        _newQuorumRequest(from, token, amount, req);
    }

    /**
     * @notice Submit a new quorum request across multiple models (approve + transferFrom)
     * @param q Request payload (same as abi.decode in onTokenTransfer)
     * @param token ERC-20 held by msg.sender (approved to this contract)
     * @param amount Amount pulled from caller (must be >= total; excess not refunded)
     */
    function newRequest(
        QuorumRequestArgs calldata requestArgs,
        address token,
        uint256 amount
    ) external returns (uint256 requestId) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "LLMQuorum: transfer failed");
        QuorumRequestArgs memory req = requestArgs;
        return _newQuorumRequest(msg.sender, token, amount, req);
    }

    /**
     * @notice ABI payload for transferAndCall (`data` in onTokenTransfer)
     * @dev Same field order and types as QuorumRequestArgs / abi.decode in onTokenTransfer
     */
    function encodeQuorumRequest(
        bytes32 prompt,
        string calldata input,
        ModelInfo[] calldata models,
        uint8 quorumThreshold,
        uint8 redundancy,
        bool returnContentWithinResultTag,
        bool storeResultOffchain,
        string calldata callback,
        bytes calldata args
    ) external pure returns (bytes memory) {
        return abi.encode(
            QuorumRequestArgs({
                prompt: prompt,
                input: input,
                models: models,
                quorumThreshold: quorumThreshold,
                redundancy: redundancy,
                returnContentWithinResultTag: returnContentWithinResultTag,
                storeResultOffchain: storeResultOffchain,
                callback: callback,
                args: args
            })
        );
    }

    /**
     * @dev Internal function to create a new quorum request
     * @param caller The caller address
     * @param token The payment token address
     * @param paidAmount The amount paid in the payment token
     * @param requestArgs The request arguments
     * @return requestId The request ID
     */
    function _newQuorumRequest(
        address caller,
        address token,
        uint256 paidAmount,
        QuorumRequestArgs memory q
    )
        internal
        returns (uint256 requestId)
    {
        // Validate caller is a contract
        require(caller != tx.origin, "LLMQuorum: service is for contracts only");

        // Validate LLM service is configured
        require(address(llmService) != address(0), "LLMQuorum: service not configured");

        ModelInfo[] memory models = q.models;

        // Validate models
        require(models.length >= 1, "LLMQuorum: at least one model required");
        require(models.length <= 255, "LLMQuorum: too many models");

        // Set default redundancy
        uint8 redundancy = q.redundancy;
        if (redundancy == 0) redundancy = 1;

        // Calculate quorum threshold (default: simple majority = floor(n/2) + 1)
        uint8 quorumThreshold = q.quorumThreshold;
        if (quorumThreshold == 0) {
            quorumThreshold = uint8(models.length / 2) + 1;
        }
        require(quorumThreshold >= 1, "LLMQuorum: threshold must be at least 1");
        require(quorumThreshold <= models.length, "LLMQuorum: threshold exceeds model count");

        // Calculate total price (token smallest units)
        uint256 totalPrice = 0;
        for (uint256 i = 0; i < models.length; i++) {
            (uint256 modelPrice, uint8 psi) = llmService.getPriceInToken(models[i].platform, models[i].model, token);
            require(psi == 0, "LLMQuorum: token not accepted or price not configured");
            totalPrice += modelPrice * redundancy;
        }
        require(paidAmount >= totalPrice, "LLMQuorum: insufficient payment");

        require(IERC20(token).approve(address(llmService), totalPrice), "LLMQuorum: approve failed");

        // Create quorum request
        requestId = ++lastRequestId;

        requests[requestId] = QuorumRequest({
            caller: caller,
            callback: q.callback,
            args: q.args,
            quorumThreshold: quorumThreshold,
            resultsReceived: 0,
            storeResultOffchain: q.storeResultOffchain
        });

        // Create sub-requests for each model
        for (uint256 i = 0; i < models.length; i++) {
            (uint256 modelPrice, uint8 psi) = llmService.getPriceInToken(models[i].platform, models[i].model, token);
            require(psi == 0, "LLMQuorum: token not accepted or price not configured");
            uint256 subPayment = modelPrice * redundancy;

            // Encode our requestId as callback args for the sub-request
            bytes memory subArgs = abi.encode(requestId);

            llmService.newRequest(
                RequestArgs({
                    platform: models[i].platform,
                    model: models[i].model,
                    prompt: q.prompt,
                    input: q.input,
                    redundancy: redundancy,
                    returnContentWithinResultTag: q.returnContentWithinResultTag,
                    storeResultOffchain: q.storeResultOffchain,
                    callback: "onSubResult",
                    args: subArgs
                }),
                token,
                subPayment
            );
        }

        emit NewQuorumRequest(requestId, uint8(models.length), quorumThreshold);

        return requestId;
    }

    // ============================================================
    //                  CALLBACK FROM LLM SERVICE
    // ============================================================

    /**
     * @notice Called by the LLM service when a sub-request is completed
     * @param subRequestId The sub-request ID from LLM service
     * @param result The LLM result string
     * @param args Encoded callback arguments (contains our quorum requestId)
     */
    function onSubResult(
        uint256 subRequestId,
        string calldata result,
        bytes calldata args
    ) external onlyLLMService {
        // Decode our quorum request ID from the callback args
        uint256 requestId = abi.decode(args, (uint256));

        // Get the request
        QuorumRequest storage request = requests[requestId];

        // If request doesn't exist or was already completed, ignore
        if (request.caller == address(0)) {
            return;
        }

        // If storeResultOffchain is true, the result is already a hash string
        bytes32 resultHash = request.storeResultOffchain
            ? bytes32(bytes(result))
            : keccak256(abi.encodePacked(result));

        // Get current results count for this request
        uint256 currentIndex = request.resultsReceived;

        // Store the result hash at current index
        resultHashes[requestId][currentIndex] = resultHash;

        // Store result on-chain, but only if not storing off-chain and we haven't seen this hash before
        if (!request.storeResultOffchain && bytes(resultsByHash[requestId][resultHash]).length == 0) {
            resultsByHash[requestId][resultHash] = result;
        }

        // Increment count for this result hash
        uint256 resultCount = resultCounts[requestId][resultHash] + 1;
        resultCounts[requestId][resultHash] = resultCount;

        // Update results received count
        request.resultsReceived = uint8(currentIndex + 1);

        emit SubResultReceived(requestId, subRequestId);

        // Check if we reached quorum
        if (resultCount >= request.quorumThreshold) {
            _fireCallback(requestId, request, result, currentIndex + 1);
        }
    }

    // ============================================================
    //                    INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @dev Fire callback and clean up request state
     * @param requestId The quorum request ID
     * @param request The request struct
     * @param result The consensus result string
     * @param numResults Number of results to clear
     */
    function _fireCallback(
        uint256 requestId,
        QuorumRequest storage request,
        string memory result,
        uint256 numResults
    ) internal {
        address caller = request.caller;
        string memory callback = request.callback;
        bytes memory args = request.args;

        // Clear state BEFORE external call (reentrancy protection)
        _clearRequest(requestId, numResults);

        // Fire callback using low-level call
        bytes memory callData = abi.encodeWithSignature(
            string(abi.encodePacked(callback, "(uint256,string,bytes)")),
            requestId,
            result,
            args
        );

        // Call without checking success (like pcall in Lua)
        (bool callbackSuccess, ) = caller.call(callData);

        emit QuorumReached(requestId, callbackSuccess);
    }

    /**
     * @dev Clear request state
     * @param requestId The request ID to clear
     * @param numResults Number of results stored
     */
    function _clearRequest(uint256 requestId, uint256 numResults) internal {
        // Clear result hashes and counts
        for (uint256 i = 0; i < numResults; i++) {
            bytes32 hash = resultHashes[requestId][i];
            delete resultsByHash[requestId][hash];
            delete resultCounts[requestId][hash];
            delete resultHashes[requestId][i];
        }

        // Clear the request
        delete requests[requestId];
    }

    // ============================================================
    //                    UTILITY FUNCTIONS
    // ============================================================

    /**
     * @notice Get request information
     * @param requestId The request ID
     * @return The request struct
     */
    function getRequestInfo(uint256 requestId) external view returns (QuorumRequest memory) {
        return requests[requestId];
    }

    /**
     * @notice Get results received for a request
     * @param requestId The request ID
     * @return resultList Array of result strings received so far
     */
    function getRequestResults(uint256 requestId) external view returns (string[] memory resultList) {
        QuorumRequest storage request = requests[requestId];
        if (request.caller == address(0)) {
            return new string[](0);
        }

        uint256 count = request.resultsReceived;
        resultList = new string[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 hash = resultHashes[requestId][i];
            resultList[i] = resultsByHash[requestId][hash];
        }

        return resultList;
    }

    /**
     * @notice Withdraw ERC-20 balance held by this contract (e.g. excess user payments)
     */
    function withdrawFees(address token, uint256 amount, address recipient) external onlyOwner {
        if (recipient == address(0)) {
            recipient = owner;
        }
        if (amount == 0) {
            amount = IERC20(token).balanceOf(address(this));
        }
        require(IERC20(token).transfer(recipient, amount), "LLMQuorum: withdrawal failed");
    }
}

// ============================================================
//                    LLM QUORUM INTERFACE
// ============================================================

/**
 * @title ILLMQuorum
 * @notice Interface for interacting with the LLMQuorum contract
 */
interface ILLMQuorum {
    struct ModelInfo {
        bytes32 platform;
        bytes32 model;
    }

    /**
     * @notice Arguments for newRequest and ERC-20 transferAndCall payloads
     * @dev Field semantics match the previous per-parameter docs on newRequest (pre-struct API).
     */
    struct QuorumRequestArgs {
        /// @notice SHA256 hash of the prompt
        bytes32 prompt;
        /// @notice JSON input string
        string input;
        /// @notice Array of models to query
        ModelInfo[] models;
        /// @notice Number of matching results required (0 = majority)
        uint8 quorumThreshold;
        /// @notice Number of node confirmations per model
        uint8 redundancy;
        /// @notice Whether to extract content from result tag
        bool returnContentWithinResultTag;
        /// @notice Whether to store result off-chain
        bool storeResultOffchain;
        /// @notice Callback function signature
        string callback;
        /// @notice Encoded callback arguments
        bytes args;
    }

    struct QuorumRequest {
        address caller;
        string callback;
        bytes args;
        uint8 quorumThreshold;
        uint8 resultsReceived;
        bool storeResultOffchain;
    }

    function getPrice(
        ModelInfo[] calldata models,
        uint8 redundancy,
        address token
    ) external view returns (uint256 totalPrice);

    function newRequest(QuorumRequestArgs calldata q, address token, uint256 amount) external returns (uint256 requestId);

    function getRequestInfo(uint256 requestId) external view returns (QuorumRequest memory);

    function getRequestResults(uint256 requestId) external view returns (string[] memory resultList);
}

// ============================================================
//                    CALLBACK INTERFACE
// ============================================================

/**
 * @title ILLMQuorumCallback
 * @notice Interface that caller contracts should implement to receive quorum results
 */
interface ILLMQuorumCallback {
    /**
     * @notice Called by LLMQuorum when quorum is reached
     * @param requestId The original request ID
     * @param result The consensus result string
     * @param args The original callback arguments
     */
    function handleQuorumResult(uint256 requestId, string calldata result, bytes calldata args) external;
}

// ============================================================
//                    EXAMPLE CALLER CONTRACT
// ============================================================

/**
 * @title LLMQuorumCaller
 * @notice Example contract demonstrating how to use the LLM Quorum service
 */
contract LLMQuorumCaller is ILLMQuorumCallback {
    LLMQuorum public quorumService;

    mapping(uint256 => string) public results;

    event QuorumRequestSent(uint256 indexed requestId);
    event QuorumResultReceived(uint256 indexed requestId, string result);

    constructor(address _quorumService) {
        quorumService = LLMQuorum(payable(_quorumService));
    }

    /**
     * @notice Send a request to multiple models for consensus
     * @param prompt SHA256 hash of the prompt
     * @param input JSON input string
     * @param models Array of models to query
     */
    function askMultipleModels(
        bytes32 prompt,
        string calldata input,
        LLMQuorum.ModelInfo[] calldata models,
        address token,
        uint256 amount
    ) external returns (uint256) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "LLMQuorumCaller: pull failed");
        require(IERC20(token).approve(address(quorumService), amount), "LLMQuorumCaller: approve failed");
        uint256 requestId = quorumService.newRequest(
            LLMQuorum.QuorumRequestArgs({
                prompt: prompt,
                input: input,
                models: models,
                quorumThreshold: 0,
                redundancy: 1,
                returnContentWithinResultTag: true,
                storeResultOffchain: false,
                callback: "handleQuorumResult",
                args: ""
            }),
            token,
            amount
        );

        emit QuorumRequestSent(requestId);
        return requestId;
    }

    /**
     * @notice Callback function called by Quorum service when consensus is reached
     */
    function handleQuorumResult(
        uint256 requestId,
        string calldata result,
        bytes calldata /* args */
    ) external override {
        require(msg.sender == address(quorumService), "LLMQuorumCaller: unauthorized callback");
        results[requestId] = result;
        emit QuorumResultReceived(requestId, result);
    }

}
