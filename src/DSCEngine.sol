// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSC Engine
 * @author Karthik
 *
 * This System is designed to be as minimal as possible , and have tokes maintain
 * a 1 Token == $1 peg.
 *
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance , no fees , and was backed by
 * WETH and WBTC
 * @notice This contract is the core of the DSC system. It handles all the logic for
 * mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY Loosely based on the makerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    //// Errors ///
    ////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorTooLow(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HelathFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////
    //// Type /////
    ////////////////

    using OracleLib for AggregatorV3Interface;

    ///////////////////////
    /// State Variables ///
    ///////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // It should be 10%

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens; // weth or wbtc

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
    //// Events //////
    //////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    /// Modifiers ///
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////
    /// Functions ///
    ////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For Example ETH / USD , BTC / USD , MKR / USD, etc...
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
    }

    //////////////////////////
    /// External Functions ///
    //////////////////////////

    /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice this function will deposit your collateral and mint DSC in one transaction
    */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice Follows CEI pattern
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        // when we update the state we emit a event
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    * @param tokenCollateralAddress The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to Burn
    * This function burns DSC and redeems underlying collateral in one transaction
    */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks the health factor
    }

    // In order to reddem collateral:
    // 1. Helath Fcator must be over ! AFter Collateral pulled

    // CEI : Checks, Effects and Interactions

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @notice Follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much DSC (like 150 DSC if they collateral 100 dollars worth of ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I dont think this will ever hit
    }

    // If we do start nearing underCollateralization , we need someone to liquidate positions
    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <- DSC isnt worth $1.

    // $75 ETH backing $50 DSC
    // Liquidator take $75 backing and payback/burns $50 DSC

    // If Someone is almost underCollateralized, we will pay you to liquidate them

    /*
    * @param collateral - The ERC20 collateral address to liquidate from the user
    * @param user - The user Who has broken the health Factor. their _healthFactor 
    * should be below MIN_HEALTH_FACTOR
    * @param debtToCover - The amount of DSC you want to burn to improve the users health factor
    * @notice You can partially liquidate the user
    * @notice You will get a Liquidation bonus for taking the users Fund ($75-$50 = $25 for Liquidator)
    * @notice This FUnction working assumes the protocol will be roughly 200% overCollateralized\
    * in order for this to work.
    * 
    * @notice A known bug would be if the protocol were 100& or less collateralized, then we wouldnt
    * be able to incentive the liquidators
    * For Example , If the price of the collateral plummmeted before anyone could be liquidated
    * 
    * follows CEI : Checks, effects and Interactions
    */
    function liquidate(address collateral, address user, uint256 debtToCover) external {
        uint256 startingUserHealthFactor = _healthFactor(user);
        // need to check health Factor of the user
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HelathFactorOk();
        }
        // we want to burn their DSC "debt"
        // And take their collateral
        // Bad user : $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC == ?? ETH?

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra money amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We need to burn the dsc
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external {}

    /////////////////////////////////////////
    /// Private & Internal view Functions ///
    /////////////////////////////////////////

    /*
     * @dev Low-level internal function, do not call unless the function calling it 
     * is checking for health factor being broken
     */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This condition is Hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorAfter();
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // 3.
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /* 
    * Returns how close to liquidation a user is
    * If a User gioes below 1, they then get liquidated
    */

    // 4.
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // Explanation
        // if they have $1000 Worth of ETH in collateral
        // 1000 * 50 = 50000 / 100 = 500 They can only mint 500 DSC
        // So WE have 200% collateralization

        // for example $150 * 50 = 7500 / 100 = 75 idhu matu tha nambalala mint panna mudium
        // 75 / 100(namba dsc mint panra amount) = < 1 so they get liquidated
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 5.
    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check Health Factor (do they have enough collateral)
        // 2. Revert if they dont
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorTooLow(userHealthFactor);
        }
    }

    /////////////////////////////////////////
    /// Public & External view Functions ///
    /////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Price of ETH (Token)
        // $/ETH ETH ??
        // $2000 / ETH . $1000 = 0.5 ETH
        AggregatorV3Interface priceFeeds = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeeds.staleCheckLatestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    // 2.
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token,get the amount they have deposited , and map
        // the price , to get the usd value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    // 1.
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 1000 USD
        // the returned value from CL will be 1000 * 1e18;
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /////////////////////////
    /// getter Functions ////
    /////////////////////////

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
