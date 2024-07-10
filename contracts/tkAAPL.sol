// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

contract tkAPPL is ConfirmedOwner, FunctionsClient {

    using FunctionsRequest for FunctionsRequest.Request;
    
    enum MintOrRedeem {
        mint,
        redeem
    }

    // Struct to store sendMintRequest details
    struct AAPLRequest {
        uint256 requestedTokenAmount;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    address private constant FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    bytes32 private constant DON_ID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    uint64 private immutable subscriptionId;
    string private requestSourceCode;
    uint32 private constant GAS_LIMIT = 300000;

    // Mapping storing each request details for each specific request id
    mapping (bytes32 requestId => AAPLRequest request) private requests;

    constructor(
        string memory _requestSourceCode, 
        uint64 _subscriptionID
    ) ConfirmedOwner(msg.sender) FunctionsClient(FUNCTIONS_ROUTER) {
        requestSourceCode = _requestSourceCode;
        subscriptionId = _subscriptionID;
    }

    /**
     * @notice User send a request for minting an tkAAPL token.
     * @dev Send an HTTP request to Chainlink. Function will send 2 txs.
     * 1st tx will send a request to Chainlink node, to check the stocks balance of the user.
     * 2nd tx will do a callback to the APPL contract and do a token minting if user balance is enough for this. 
     */
    function sendMintRequest(uint256 _amount) external onlyOwner returns(bytes32 requestId) {
        FunctionsRequest.Request memory req; // this is our data object
        req.initializeRequestForInlineJavaScript(requestSourceCode);
        bytes32 requestId = _sendRequest(
            req.encodeCBOR(), // "encodeCBOR()" function encodes data into CBOR encoded bytes, so that Chainlink node will understand our data
            subscriptionId,
            GAS_LIMIT,
            DON_ID
        );
        requests[requestId] = AAPLRequest(
            _amount,
            msg.sender,
            MintOrRedeem.mint
        );
    }

    /**
     * @notice User send a request to sell AAPL token for USDC.
     * @dev Chainlink will call the exchange app, and do the next operations:
     * 1. Sell AAPL stock on the exchange.
     * 2. Buy USDC on the exchange.
     * 4. Send USDC to this smart contract. 
     */
    function sendRedeemRequest()  external {
        
    }

    /**
     * @dev After calling "sendMintRequest" function, the Chainlink node will return a response
     * which will be used in this function.
     */
    function _mintFulfillRequest() internal {
        
    }

    function _redeemFulfillRequest() internal {}

    function fulfillRequest(
        bytes32 requestId, 
        bytes memory response, 
        bytes memory /* err */) internal virtual override {
        
    }
}