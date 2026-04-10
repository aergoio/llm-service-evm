// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @notice Arguments for LLMService.newRequest and ERC-20 transferAndCall payloads
 * @dev Field semantics match the original per-parameter docs on newRequest (pre-struct API).
 */
struct RequestArgs {
    /// @notice LLM platform name
    bytes32 platform;
    /// @notice Model name
    bytes32 model;
    /// @notice SHA256 hash of the prompt
    bytes32 prompt;
    /// @notice JSON input string
    string input;
    /// @notice Number of matching results required (minimum 1)
    uint8 redundancy;
    /// @notice Whether to extract content from result tag
    bool returnContentWithinResultTag;
    /// @notice Whether to store result off-chain
    bool storeResultOffchain;
    /// @notice Callback function signature (e.g., "handleResult(uint256,string)")
    string callback;
    /// @notice Encoded callback arguments
    bytes args;
}

/**
 * @title LLMService
 * @notice Oracle-style contract for requesting LLM services from authorized off-chain nodes.
 * @dev Users pay a fee in accepted ERC-20 tokens. Authorized nodes process and return results.
 *      Supports redundancy/quorum - multiple nodes can submit, and consensus triggers callback.
 *
 *      Payment:
 *      - approve + newRequest (transferFrom), or
 *      - token.transferAndCall(service, amount, abi.encode(RequestArgs)) → onTokenTransfer
 *
 *      Token amount = `priceCents * acceptedToken[token]`. Set `acceptedToken` to **10^(decimals - 2)** so cents
 *      map to smallest units (e.g. USDT 6 decimals → 10^4; 50 cents × 10^4 = 500_000). Requires decimals >= 2.
 *      `acceptedToken[token] == 0` means that token is not accepted. Excess payment is not refunded.
 */
contract LLMService {
    // ============================================================
    //                          TYPES
    // ============================================================

    /// @notice Stored request: user payload (RequestArgs) plus trusted caller (last field)
    struct Request {
        RequestArgs payload;
        address caller;              // Contract that made the request
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

    /// @notice Per-token multiplier: price (cents) × ratio = amount in token smallest units (0 = not accepted)
    mapping(address => uint256) public acceptedToken;

    /// @notice US cents per redundancy unit, `MODEL_NOT_SUPPORTED` for unsupported models
    mapping(bytes32 => mapping(bytes32 => uint256)) public prices;

    /// @dev Sentinel: model is not offered
    uint256 public constant MODEL_NOT_SUPPORTED = type(uint256).max;

    /// @dev Second return value of `getPriceInToken`
    uint8 public constant PRICE_IN_TOKEN_OK = 0;
    uint8 public constant PRICE_IN_TOKEN_MODEL_UNSUPPORTED = 1;
    uint8 public constant PRICE_IN_TOKEN_TOKEN_NOT_ACCEPTED = 2;

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
    event AcceptedTokenUpdated(address indexed token, uint256 conversionRatio);
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
     * @notice Set the price for a platform/model (US cents per redundancy unit)
     * @param model `bytes32("*")` for the default that applies to all models on `platform` unless overridden
     * @param price Cents for paid tiers; `MODEL_NOT_SUPPORTED` to exclude that model; `0` clears the slot (per-model
     *        `0` → `getPrice` uses `prices[platform][bytes32("*")]`; default key + `0` removes the platform default)
     */
    function setPrice(bytes32 platform, bytes32 model, uint256 price) external onlyOwner {
        prices[platform][model] = price;
        emit PriceUpdated(platform, model, price);
    }

    /**
     * @notice Set conversion multiplier for a payment token (0 removes acceptance)
     * @dev Use **10^(tokenDecimals - 2)** when `prices` are US cents (subtract 2 decimal places vs whole token units).
     */
    function setAcceptedToken(address token, uint256 conversionRatio) external onlyOwner {
        require(token != address(0), "LLMService: token is zero address");
        acceptedToken[token] = conversionRatio;
        emit AcceptedTokenUpdated(token, conversionRatio);
    }

    /**
     * @notice Resolved price in US cents (per redundancy unit) and whether the tier is offered
     * @dev Reads `prices[platform][model]` first. Only when that value is `0` (unset) does it read
     *      `prices[platform][bytes32("*")]`. Resolved unsupported if value is `0` or `MODEL_NOT_SUPPORTED`.
     */
    function getPrice(bytes32 platform, bytes32 model) public view returns (uint256 priceCents, bool supported) {
        uint256 price = prices[platform][model];
        if (price == 0) {
            price = prices[platform][bytes32("*")];
        }

        if (price == 0 || price == MODEL_NOT_SUPPORTED) {
            return (0, false);
        }
        return (price, true);
    }

    /**
     * @notice Price in `token` smallest units (per redundancy unit)
     * @return amount 0 when tier is free or on error (check status)
     * @return status `PRICE_IN_TOKEN_OK`, `PRICE_IN_TOKEN_MODEL_UNSUPPORTED`, or `PRICE_IN_TOKEN_TOKEN_NOT_ACCEPTED`
     */
    function getPriceInToken(bytes32 platform, bytes32 model, address token)
        public
        view
        returns (uint256 amount, uint8 status)
    {
        uint256 ratio = acceptedToken[token];
        if (ratio == 0) {
            return (0, PRICE_IN_TOKEN_TOKEN_NOT_ACCEPTED);
        }
        (uint256 cents, bool ok) = getPrice(platform, model);
        if (!ok) {
            return (0, PRICE_IN_TOKEN_MODEL_UNSUPPORTED);
        }
        return (cents * ratio, PRICE_IN_TOKEN_OK);
    }

    // ============================================================
    //                      USER FUNCTIONS
    // ============================================================

    /**
     * @notice Callback for ERC-20 transferAndCall (e.g. Arbitrum-style / ERC-677)
     * @dev msg.sender must be an accepted token. `from` becomes the request caller (must be a contract).
     *      `data` must be abi.encode(RequestArgs).
     */
    function onTokenTransfer(address from, uint256 amount, bytes calldata data) external {
        address token = msg.sender;
        RequestArgs memory args = abi.decode(data, (RequestArgs));
        _newRequest(from, token, amount, args);
    }

    /**
     * @notice Submit a new LLM request
     * @param req LLM request fields (see RequestArgs)
     * @param token ERC-20 to pull from msg.sender
     * @param amount Amount to transfer in (must be >= total price; excess is not refunded)
     * @return requestId The ID of the created request
     */
    function newRequest(RequestArgs calldata req, address token, uint256 amount) external returns (uint256 requestId) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "LLMService: transfer failed");

        RequestArgs memory m = req;
        requestId = _newRequest(msg.sender, token, amount, m);
    }

    /**
     * @notice ABI payload for transferAndCall
     */
    function encodeRequest(
        bytes32 platform,
        bytes32 model,
        bytes32 prompt,
        string calldata input,
        uint8 redundancy,
        bool returnContentWithinResultTag,
        bool storeResultOffchain,
        string calldata callback,
        bytes calldata args
    ) external pure returns (bytes memory) {
        return abi.encode(
            RequestArgs({
                platform: platform,
                model: model,
                prompt: prompt,
                input: input,
                redundancy: redundancy,
                returnContentWithinResultTag: returnContentWithinResultTag,
                storeResultOffchain: storeResultOffchain,
                callback: callback,
                args: args
            })
        );
    }

    function _newRequest(
        address caller,
        address token,
        uint256 paidAmount,
        RequestArgs memory a
    )
        internal
        returns (uint256 requestId)
    {
        // Service is for contract callers only (newRequest: msg.sender; onTokenTransfer: from)
        require(caller != tx.origin, "LLMService: service is for contracts only");

        // Validate redundancy
        require(a.redundancy >= 1, "LLMService: redundancy must be at least 1");
        require(a.redundancy <= authorizedNodes.length, "LLMService: redundancy exceeds available nodes");

        (uint256 price, uint8 psi) = getPriceInToken(a.platform, a.model, token);
        require(
            psi == PRICE_IN_TOKEN_OK,
            psi == PRICE_IN_TOKEN_MODEL_UNSUPPORTED ? "LLMService: model not supported" : "LLMService: token not accepted"
        );
        require(paidAmount >= price * uint256(a.redundancy), "LLMService: insufficient payment");

        // Create request
        requestId = ++lastRequestId;
        requests[requestId] = Request({payload: a, caller: caller});

        emit NewRequest(requestId, a.redundancy);
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
        bytes32 resultHash = request.payload.storeResultOffchain
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
        if (numEqual >= request.payload.redundancy) {
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
            if (!request.payload.storeResultOffchain && bytes(results[requestId][resultHash]).length == 0) {
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
        address callbackTarget = request.caller;
        string memory callback = request.payload.callback;
        bytes memory cbArgs = request.payload.args;

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
            cbArgs
        );

        // Call without checking success (like pcall in Lua)
        // solhint-disable-next-line avoid-low-level-calls
        (bool callbackSuccess, ) = callbackTarget.call(callData);

        emit Processed(requestId, callbackSuccess);
    }

    // ============================================================
    //                    UTILITY FUNCTIONS
    // ============================================================

    /**
     * @notice Withdraw collected ERC-20 fees
     * @param token Token to withdraw
     * @param amount Amount (0 = full balance of this contract for that token)
     * @param recipient Recipient (zero = owner)
     */
    function withdrawFees(address token, uint256 amount, address recipient) external onlyOwner {
        if (recipient == address(0)) {
            recipient = owner;
        }
        if (amount == 0) {
            amount = IERC20(token).balanceOf(address(this));
        }
        require(IERC20(token).transfer(recipient, amount), "LLMService: withdrawal failed");
    }

    /**
     * @notice Send native ETH to authorized nodes so each reaches at least `targetBalance`.
     * @dev Caller supplies the ETH via msg.value (must cover the aggregate shortfall). Surplus is returned to msg.sender.
     */
    function fundNodes(uint256 targetBalance) external payable onlyOwner {
        uint256 len = authorizedNodes.length;
        require(len > 0, "LLMService: no authorized nodes");

        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 bal = authorizedNodes[i].balance;
            if (bal < targetBalance) {
                totalNeeded += targetBalance - bal;
            }
        }
        require(msg.value >= totalNeeded, "LLMService: insufficient msg.value");

        for (uint256 i = 0; i < len; i++) {
            address node = authorizedNodes[i];
            uint256 currentBalance = node.balance;

            if (currentBalance < targetBalance) {
                uint256 amountToSend = targetBalance - currentBalance;

                (bool success, ) = node.call{value: amountToSend}("");
                require(success, "LLMService: transfer to node failed");

                emit NodeFunded(node, amountToSend);
            }
        }

        uint256 leftover = msg.value - totalNeeded;
        if (leftover > 0) {
            (bool ok, ) = payable(msg.sender).call{value: leftover}("");
            require(ok, "LLMService: surplus refund failed");
        }
    }
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
     * @notice Send a request to the LLM service (user must approve this contract, which forwards to LLMService)
     */
    function askLLM(
        bytes32 platform,
        bytes32 model,
        bytes32 prompt,
        string calldata input,
        address token,
        uint256 amount
    ) external returns (uint256) {

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "LLMServiceCaller: pull failed");
        require(IERC20(token).approve(address(llmService), amount), "LLMServiceCaller: approve failed");

        uint256 requestId = llmService.newRequest(
            RequestArgs({
                platform: platform,
                model: model,
                prompt: prompt,
                input: input,
                redundancy: 1,
                returnContentWithinResultTag: true,
                storeResultOffchain: false,
                callback: "handleLLMResult",
                args: ""
            }),
            token,
            amount
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

}

// ============================================================
//                    SERVICE INTERFACE
// ============================================================

interface ILLMService {
    function newRequest(RequestArgs calldata req, address token, uint256 amount) external returns (uint256);

    function getPrice(bytes32 platform, bytes32 model) external view returns (uint256 priceCents, bool supported);

    function getPriceInToken(bytes32 platform, bytes32 model, address token)
        external
        view
        returns (uint256 amount, uint8 status);
}
