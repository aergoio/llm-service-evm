// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.20;

import "../contract/llm-service.sol";

/// @dev ERC-677 / Arbitrum-style: debits `msg.sender`, credits `to`, then `to.onTokenTransfer(msg.sender, amount, data)`
interface IERC20 {
    function transferAndCall(address to, uint256 amount, bytes calldata data) external returns (bool);
}

/**
 * @title LLMTest
 * @notice A simple test contract to interact with the LLM service
 * @dev Demonstrates basic request/callback flow with the LLM oracle (ERC-20 payment via approve + newRequest, or transferAndCall).
 */
contract LLMTest is ILLMServiceCallback {
    // ============================================================
    //                       STATE VARIABLES
    // ============================================================

    address public owner;
    ILLMService public llmService;

    string public lastResult;

    // ============================================================
    //                          EVENTS
    // ============================================================

    event RequestSubmitted(uint256 indexed requestId, address indexed sender, bytes32 configHash);
    event LLMResult(uint256 indexed requestId, address indexed sender, string result);
    event ServiceAddressUpdated(address indexed newAddress);

    // ============================================================
    //                         MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "LLMTest: permission denied");
        _;
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize the test contract
     * @param _llmService Address of the LLM service contract
     */
    constructor(address _llmService) {
        require(_llmService != address(0), "LLMTest: invalid service address");

        owner = msg.sender;
        llmService = ILLMService(_llmService);
    }

    // ============================================================
    //                      ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Update the LLM service contract address
     * @param _llmService New service address
     */
    function setLLMServiceAddress(address _llmService) external onlyOwner {
        require(_llmService != address(0), "LLMTest: invalid service address");
        llmService = ILLMService(_llmService);
        emit ServiceAddressUpdated(_llmService);
    }

    // ============================================================
    //                      MAIN FUNCTIONS
    // ============================================================

    /**
     * @notice Submit a new LLM request
     * @param configHash Hash of the config/prompt file
     * @param userInput The user's input string
     * @param token ERC-20 accepted on the service (`acceptedToken[token] != 0`)
     * @param amount Pulled from msg.sender and forwarded (must cover price × redundancy; excess not refunded)
     * @return requestId The LLM service request ID
     */
    function newRequest(
        bytes32 configHash,
        string calldata userInput,
        address token,
        uint256 amount
    ) external returns (uint256 requestId) {

        // Pull the ERC-20 from the caller and approve the LLM service
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "LLMTest: pull failed");
        require(IERC20(token).approve(address(llmService), amount), "LLMTest: approve failed");

        // Build the input JSON string
        string memory input = string(abi.encodePacked(
            '{"user_input":"',
            userInput,
            '"}'
        ));

        // Call the LLM service
        requestId = llmService.newRequest(
            RequestArgs({
                platform: bytes32(0),        // platform (use from config)
                model: bytes32(0),           // model (use from config)
                prompt: configHash,          // prompt hash
                input: input,                // JSON input
                redundancy: 1,               // redundancy of 1
                returnContentWithinResultTag: true, // return content within result tag
                storeResultOffchain: false,  // don't store result off-chain
                callback: "handleLLMResult", // callback function
                args: abi.encode(msg.sender) // encode sender address as args
            }),
            token, // ERC-20 payment token
            amount // amount approved to service (must cover price; excess not refunded)
        );

        emit RequestSubmitted(requestId, msg.sender, configHash);

        return requestId;
    }

    /**
     * @notice Same as `newRequest`, but pays via `token.transferAndCall(llmService, amount, abi.encode(RequestArgs))`
     * @dev Token must implement `transferAndCall`. Funds are pulled to this contract first so `onTokenTransfer`'s `from` is this contract (contracts-only rule). `lastRequestId` is read after the call.
     */
    function newRequestViaTransferAndCall(
        bytes32 configHash,
        string calldata userInput,
        address token,
        uint256 amount
    ) external returns (uint256 requestId) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "LLMTest: pull failed");

        // Build the input JSON string
        string memory input = string(abi.encodePacked(
            '{"user_input":"',
            userInput,
            '"}'
        ));

        // Build the request arguments
        bytes memory data = abi.encode(
            RequestArgs({
                platform: bytes32(0),        // platform (use from config)
                model: bytes32(0),           // model (use from config)
                prompt: configHash,          // prompt hash
                input: input,                // JSON input
                redundancy: 1,               // redundancy of 1
                returnContentWithinResultTag: true, // return content within result tag
                storeResultOffchain: false,  // don't store result off-chain
                callback: "handleLLMResult", // callback function
                args: abi.encode(msg.sender) // encode sender address as args
            })
        );

        // Call the LLM service
        bool success = IERC20(token).transferAndCall(address(llmService), amount, data);
        require(success, "LLMTest: transferAndCall failed");

        // Get the request ID
        requestId = LLMService(address(llmService)).lastRequestId();

        emit RequestSubmitted(requestId, msg.sender, configHash);
        return requestId;
    }

    /**
     * @notice Callback function called by LLM service with the result
     * @param requestId The original request ID
     * @param result The LLM result string
     * @param args Encoded callback arguments (sender address)
     */
    function handleLLMResult(
        uint256 requestId,
        string calldata result,
        bytes calldata args
    ) external override {
        require(msg.sender == address(llmService), "LLMTest: only LLM service can call this");

        // Decode the sender address from args
        address sender = abi.decode(args, (address));

        // Store the result
        lastResult = result;

        emit LLMResult(requestId, sender, result);
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get the last result received
     * @return The last LLM result string
     */
    function getLastResult() external view returns (string memory) {
        return lastResult;
    }
}
