// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {tkAAPLErrors} from "../contracts/interfaces/CustomErrors.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract tkAPPL is ConfirmedOwner, FunctionsClient, tkAAPLErrors, ERC20 {

    using FunctionsRequest for FunctionsRequest.Request;
    
    enum MintOrSell {
        mint,
        sell
    }

    // Struct to store sendMintRequest details
    struct AAPLRequest {
        uint256 requestedTokenAmount;
        address requester;
        MintOrSell mintOrSell;
    }

    address constant FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    bytes32 constant DON_ID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    uint256 constant DECIMALS = 1e18;
    // Tokens tkAAPL are not backed 1:1. Instead 1 tkAAPL token
    // has at least 2 shares on the exchange account. So 2:1.
    uint256 constant COLLATERAL_RATIO = 200;
    uint256 constant COLLATERAL_DECIMALS = 100;
    uint32 constant GAS_LIMIT = 300000;
    address constant SEPOLIA_AAPL_PRICE_FEED = 0xc59E3633BAAC79493d908e63626716e204A45EdF; // it is a LINK/USD frice feed for a test purpose
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    // Exchanges has a minimum withdrawal amount. I set it to 100
    // because this amount will cover min. withdr. amount on each exchange. 
    uint256 constant MINIMUM_WITHDROWAL_AMOUNT = 100e18;
    uint64 immutable subscriptionId;
    string private requestSourceCode;
    string private sellSourceCode;
    uint256 private portfolioBalance;

    // Mapping storing each request details for each specific request id
    mapping(bytes32 requestId => AAPLRequest request) private requests;

    constructor(string memory _requestSourceCode, string memory _sellSourceCode, uint64 _subscriptionID) 
        ConfirmedOwner(msg.sender) 
        FunctionsClient(FUNCTIONS_ROUTER)
        ERC20("tkAAPl", "tkAAPL") 
    {
        requestSourceCode = _requestSourceCode;
        sellSourceCode = _sellSourceCode;
        subscriptionId = _subscriptionID;
    }

    /**
     * @notice User send a request for minting an tkAAPL token.
     * @dev Send an HTTP request to Chainlink. Function will send 2 txs.
     * 1st tx will send a request to Chainlink node, to check the shares balance of the user.
     * 2nd tx will do a callback to the APPL contract and do a token minting throght the "_mintFulfillRequest"  
     * if user balance is enough for this.
     * If '_amount' <= 0 --> revert with 'tkAAPL_Requested0TokenAmountToMint()'
     * @param _amount - number of tokens for minting. 
     */
    function sendMintRequest(uint256 _amount) external onlyOwner returns(bytes32) {
        if(_amount <= 0) {
            revert tkAAPL_Requested0TokenAmountToMint(_amount);
        }
        FunctionsRequest.Request memory req; // this is our data object
        req.initializeRequestForInlineJavaScript(requestSourceCode);
        bytes32 requestId = _sendRequest( //sends a Chainlink Functions request to the stored router address
            req.encodeCBOR(), // "encodeCBOR()" function encodes data into CBOR encoded bytes, so that Chainlink node will understand our data
            subscriptionId,
            GAS_LIMIT,
            DON_ID
        );
        requests[requestId] = AAPLRequest(
            _amount,
            msg.sender,
            MintOrSell.mint
        );
        return requestId;
    }

    /**
     * @notice User send a request to sell tkAAPL token for it's USDC equivalent price 
     * at the current point of time.
     * @dev Chainlink will send a call to the exchange app, and do the next operations:
     * 1. Sell AAPL share on the exchange.
     * 2. Buy USDC on the exchange.
     * 4. Send USDC to this smart contract.
     * If  '_tkAAPLAmountToSell' < MINIMUM_WITHDROWAL_AMOUNT --> revert.
     */
    function sendSellRequest(uint256 _tkAAPLAmountToSell) external returns(bytes32) {
        // verifying user selling the amount which is > the minimum required amount 
        uint256 amountToSellInUsdc = getUsdcValueInUsd(getAaplShareValueInUsd(_tkAAPLAmountToSell));
        if (amountToSellInUsdc < MINIMUM_WITHDROWAL_AMOUNT) {
            revert tkAAPL_WithdrawalAmountLowerMinimumAmount(amountToSellInUsdc);
        }
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(sellSourceCode);
        bytes32 requestId = _sendRequest(
            req.encodeCBOR(), // "encodeCBOR()" function encodes data into CBOR encoded bytes, so that Chainlink node will understand our data
            subscriptionId,
            GAS_LIMIT,
            DON_ID
        );
        requests[requestId] = AAPLRequest(
            _tkAAPLAmountToSell,
            msg.sender,
            MintOrSell.sell
        );
        return requestId;
    }

    /**
     * @dev Return an AAPL share price in USD from Chainlink price feed.
     */
    function getAaplSharePrice() public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_AAPL_PRICE_FEED);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return uint256(price * 1e10); // 1e10 - creates 18 decimals
    }

    /**
     * @dev Return a USDC price in USD from Chainlink price feed.
     */
    function getUsdcPrice() public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_USDC_PRICE_FEED);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return uint256(price * 1e10); // 1e10 - creates 18 decimals
    }

    /**
     * @notice This function we need because USDC price != directly to 1.00 USD
     * It can change due to the supply/demand on the market. So with this function 
     * we guarantee that user will receive the latest updated USDC value for withdraw.
     * @dev Returns the USD value for the related USDC amount.
     * @param _amountOfUsd  - amount of USD.
     */
    function getUsdcValueInUsd(uint256 _amountOfUsd) public view returns(uint256) {
        return (getUsdcPrice() * _amountOfUsd) / DECIMALS;
    }

    /**
     * @dev Returns the USD value for the related AAPL amount.
     * @param _amountOfAapl - amount of AAPL shares.
     */
    function getAaplShareValueInUsd(uint256 _amountOfAapl) public view returns(uint256) {
        return (getAaplSharePrice() * _amountOfAapl) / DECIMALS;
    }

    /**
     * @notice Return the amount of AAPL value(in USD) stored on the user exchange account.
     * If user have enough AAPL shares, then we'll mint a tkAAPL token.
     * @dev After calling "sendMintRequest" function, the Chainlink node will return a response
     * with user exchange account balance, which will be used in this function.
     * If AAPL balance > txAAPL we want to mint --> then mint.
     * @param _requestId - id of the request to Chainlink.
     * @param _response - response object from Chainlink with data.
     */
    function _mintFulfillRequest(bytes32 _requestId, bytes memory _response) internal {
        AAPLRequest memory request = requests[_requestId];
        portfolioBalance = uint256(bytes32(_response));

        // Total amount of tokens to mint should be < portfolioBalance.
        // checking if user have enough AAPL shares on the exchange account to mint new tokens.
        if(_getCollateralBalance(request.requestedTokenAmount) > portfolioBalance) {
            revert tkAAPL_NotEnoughCollateral(request.requestedTokenAmount, portfolioBalance);
        } else {
            _mint(request.requester, request.requestedTokenAmount);
        }
    }

    function _sellFulfillRequest(bytes32 _requestId, bytes memory _response) internal {

    }

    /**
     * @dev After sending a mint/sell request, Chainlink will always 
     * respond with a callback to the fullFillRequest func.
     * @param _requestId - request id 
     * @param _response - response 
     */
    function fulfillRequest(bytes32 _requestId, bytes memory _response, bytes memory /* err */) 
        internal 
        override 
    {
        if (requests[_requestId].mintOrSell == MintOrSell.mint) {
            _mintFulfillRequest(_requestId, _response);
        } else {
            _sellFulfillRequest(_requestId, _response);
        }
    }

    /**
     * @dev Checks that user have enough AAPL shares on his exchange account, 
     * before starting minting a requested amount of tkAAPL tokens.
     * @param _amountOfTokensToMint - requested amount of tokens, user want to mint.
     */
    function _getCollateralBalance(uint256 _amountOfTokensToMint) internal view returns(uint256) {
        uint256 calculatedNewTotalValue = _getCalculatedNewTotalValue(_amountOfTokensToMint);
        return(calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_DECIMALS;
    }

    /**
     * @dev Calculate the total value(in USD) of all tkAAPL tokens. Combining the totalSupply 
     * together with the requested amount of tokens for mint and price of the AAPL share.
     * At least this newly calculated total value should be on the user exchange account to
     * mint the requested amount of tokens. 
     * @param _addedTokens - tokens amount which is requested for mint. 
     */
    function _getCalculatedNewTotalValue(uint256 _addedTokens) internal view returns (uint256) {
        // (10tokens + 5 tokens to mint) * AAPL share price(200) = 3000$
        return ((totalSupply() + _addedTokens) * getAaplSharePrice()) / DECIMALS;
    }
}