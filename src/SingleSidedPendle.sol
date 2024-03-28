// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;
import "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPendleMarket} from "./interfaces/IPendleMarket.sol";
import {ISY} from "./interfaces/ISY.sol";
import {IPendleRouter} from "./interfaces/IPendleRouter.sol";
import {IPendleOracle} from "./interfaces/IPendleOracle.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

/// @title yearn-v3-Single-Sided-Pendle
/// @author mil0x
/// @notice yearn-v3 Strategy that single sided invests into yearn-v3-Pendle strategy.
contract SingleSidedPendle is BaseHealthCheck, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    address public LPstrategy;
    address public immutable redeemToken;

    // Bool to set wether or not to unwrap asset before depositing into SY. This enables direct payable deposits. Defaults to false.
    bool public immutable unwrapAssetToSY;

    // If rewards should be sold through Auctions.
    bool public useAuction;

    address internal constant pendleRouter = 0x00000000005BBB0EF59571E58418F9a4357b68A0;
    IPendleRouter.ApproxParams public routerParams;
    
    address public immutable LP;
    address public immutable oracle;
    address public immutable SY;
    address public immutable GOV;
    // Difference in decimals between asset and BPT(1e18).
    uint256 internal immutable scaler;
    uint256 internal constant WAD = 1e18;

    uint32 public oracleDuration;

    uint256 public minAssetAmountToLP;
    // The max in asset we will deposit or withdraw at a time.
    uint256 public maxSingleTrade;
    // The amount in asset that will trigger a tend if idle.
    uint256 public depositTrigger;
    // The max amount the base fee can be for a tend to happen.
    uint256 public maxTendBasefee;
    // Minimum time between deposits to wait.
    uint256 public minDepositInterval;
    // Time stamp of the last deployment of funds.
    uint256 public lastDeposit;
    // Amount in Basis Points to allow for slippage on deposits.
    uint256 public slippage;
    
    // Bool if the strategy is open for any depositors. Default = true.
    bool public open = true;

    // Mapping of addresses allowed to deposit.
    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        address _LP,
        address _redeemToken,
        address _oracle,
        address _LPstrategy,
        uint256 _maxSingleTrade,
        address _GOV,
        string memory _name
    ) BaseHealthCheck(_asset, _name) {
        console.log("constructor");
        require(IStrategy(_LPstrategy).asset() == _LP, "LPstrategy.asset != LP");

        (SY, , ) = IPendleMarket(_LP).readTokens();
        unwrapAssetToSY = !ISY(SY).isValidTokenIn(_asset); //if asset is invalid tokenIn, unwrapping is necessary.
        if (unwrapAssetToSY) {
            require(ISY(SY).isValidTokenIn(address(0)), "!valid"); //if asset & address(0) are both invalid tokenIn --> revert
        }

        redeemToken = _redeemToken;
        uint24 _feeRedeemTokenToAsset = 500;
        _setUniFees(redeemToken, _asset, _feeRedeemTokenToAsset);
        oracleDuration = 3600; //1 hour price smoothing

        routerParams.guessMin = 0;
        routerParams.guessMax = type(uint256).max;
        routerParams.guessOffchain = 0; // strictly 0
        routerParams.maxIteration = 256;
        routerParams.eps = 1e15; // max 0.1% unused

        LPstrategy = _LPstrategy;
        LP = _LP;
        oracle = _oracle;
        GOV = _GOV;

        // Amount to scale up or down from asset -> BPT token.
        scaler = 10 ** (ERC20(LP).decimals() - asset.decimals());

        // Allow for .1% loss.
        _setLossLimitRatio(10);
        // Only allow a 10% gain.
        _setProfitLimitRatio(50_00);

        // Max approvals.
        asset.safeApprove(SY, type(uint).max);
        ERC20(SY).safeApprove(pendleRouter, type(uint).max);
        ERC20(_LP).safeApprove(pendleRouter, type(uint256).max);
        ERC20(_LP).safeApprove(LPstrategy, type(uint256).max);
        if (redeemToken != address(0) || redeemToken != _asset) {
            ERC20(redeemToken).safeApprove(router, type(uint).max);
        }

        // Set storage
        maxSingleTrade = _maxSingleTrade;
        // Default the default trigger to half the max trade.
        depositTrigger = _maxSingleTrade / 2;
        // Default max tend fee to 100 gwei.
        maxTendBasefee = 100e9;
        // Default min deposit interval to 6 hours.
        minDepositInterval = 60 * 60 * 6;
        // Default slippage to 1%.
        slippage = 100;
    }

    /*//////////////////////////////////////////////////////////////
                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal override {
        //do nothing, we want to only have the keeper swap funds
    }

    function _depositAndStake(uint256 _amount) internal {
        uint256 currentBalance = _amount;
        //asset --> SY
        if (currentBalance <= minAssetAmountToLP) return;
        uint256 payableBalance;
        address depositToken;
        console.log("unwrapAssetToSY: ", unwrapAssetToSY);
        if (unwrapAssetToSY) { //for pools that require unwrapped gas as SY deposit asset
            console.log("withdraw:");
            IWETH(address(asset)).withdraw(currentBalance);
            payableBalance = currentBalance;
            depositToken = address(0); //unwrapped
        } else {
            depositToken = address(asset);
        }
        console.log("deposit:");
        ISY(SY).deposit{value: payableBalance}(address(this), depositToken, currentBalance, 0);
        currentBalance = ERC20(SY).balanceOf(address(this));

        //SY --> LP
        if (currentBalance == 0) return;
        IPendleRouter.LimitOrderData memory limit; //skip limit order by passing zero address
        (currentBalance, ) = IPendleRouter(pendleRouter).addLiquiditySingleSy(address(this), LP, currentBalance, _minLPout(currentBalance), routerParams, limit);

        //LP --> Deposit
        if (currentBalance > 0) {
            IStrategy(LPstrategy).deposit(currentBalance, address(this));
        }

        // Update the last time that we deposited.
        lastDeposit = block.timestamp;
    }

    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        if (!TokenizedStrategy.isShutdown()) {
            _depositAndStake(Math.min(asset.balanceOf(address(this)), maxSingleTrade));
        }
        console.log("SSP balanceAsset: ", _balanceAsset());
        console.log("SSP _balanceStrategyShares(): ", _balanceStrategyShares());
        console.log("SSP IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares()): ", IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares()));
        console.log("SSP _LPtoAsset(IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares())): ", _LPtoAsset(IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares())));
        _totalAssets = _balanceAsset() + _LPtoAsset(IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares())); 
    }

    function _freeFunds(uint256 _amount) internal override {
        //Redeem LPstrategy shares proportional to the SSP shares redeemed:
        uint256 totalAssets = TokenizedStrategy.totalAssets();
        uint256 totalDebt = totalAssets - _balanceAsset();
        uint256 sharesToRedeem = _balanceStrategyShares() * _amount / totalDebt;
        if (sharesToRedeem == 0) return;
        //Shares --> LP
        sharesToRedeem = IStrategy(LPstrategy).redeem(sharesToRedeem, address(this), address(this), 0);
        if (sharesToRedeem == 0) return;
        //LP --> SY
        IPendleRouter.LimitOrderData memory limit; //skip limit order by passing zero address
        (sharesToRedeem, ) = IPendleRouter(pendleRouter).removeLiquiditySingleSy(address(this), LP, sharesToRedeem, 0, limit);
        if (sharesToRedeem == 0) return;
        console.log("sharesToRedeem", sharesToRedeem);
        console.log("SY: ", ERC20(SY).balanceOf(address(this)));
        //SY --> asset
        address _redeemToken = redeemToken;
        bool swap = true; //swap if redeemToken is not zero address or asset
        if (_redeemToken == address(0)) {
            _redeemToken = address(asset);
            swap = false;
        } else if (_redeemToken == address(asset)) {
            swap = false;
        }
        // We don't enforce any min amount out since withdrawer's can use 'maxLoss'
        sharesToRedeem = ISY(SY).redeem(address(this), sharesToRedeem, _redeemToken, 0, false);        
        if (swap) {
            _swapFrom(_redeemToken, address(asset), sharesToRedeem, 0);
        }
        console.log("freefunds SSP balanceAsset: ", _balanceAsset());
        console.log("SSP _balanceStrategyShares(): ", _balanceStrategyShares());
        console.log("SSP IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares()): ", IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares()));
        console.log("SSP _LPtoAsset(IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares())): ", _LPtoAsset(IStrategy(LPstrategy).convertToAssets(_balanceStrategyShares())));
    }

    function _assetToLP(uint256 _amount) internal view returns (uint256) {
        uint256 rate = IPendleOracle(oracle).getLpToAssetRate(LP, oracleDuration);
        return (_amount * WAD * scaler) / rate;
    }

    function _LPtoAsset(uint256 _amount) internal view returns (uint256) {
        uint256 rate = IPendleOracle(oracle).getLpToAssetRate(LP, oracleDuration);
        return (_amount * rate) / WAD / scaler;
    }
    
    function _minLPout(uint256 _amount) internal view returns (uint256) {
        return (_assetToLP(_amount) * (MAX_BPS - slippage)) / MAX_BPS;
    }

    function _balanceAsset() internal view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function _balanceLP() internal view returns (uint256) {
        return ERC20(LP).balanceOf(address(this));
    }

    function _balanceStrategyShares() internal view returns (uint256) {
        return ERC20(LPstrategy).balanceOf(address(this));
    }

    function _tend(uint256) internal override {
        _depositAndStake(Math.min(asset.balanceOf(address(this)), maxSingleTrade));
    }

    function _tendTrigger() internal view override returns (bool _shouldTend) {
        if (block.timestamp - lastDeposit > minDepositInterval && asset.balanceOf(address(this)) > depositTrigger) {
            _shouldTend = block.basefee < maxTendBasefee;
        }
    }

    function availableDepositLimit(address _owner) public view override returns (uint256) {
        // If the owner is whitelisted or the strategy is open.
        if (allowed[_owner] || open) {
            // Allow the max of a single deposit.
            return maxSingleTrade;
        } else {
            // Otherwise they cannot deposit.
            return 0;
        }
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return _balanceAsset() + maxSingleTrade;
    }

    /*//////////////////////////////////////////////////////////////
                EXTERNAL:
    //////////////////////////////////////////////////////////////*/

    function balanceAsset() external view returns (uint256) {
        return _balanceAsset();
    }

    function balanceStrategyShares() external view returns (uint256) {
        return _balanceStrategyShares();
    }

    // Can also be used to pause deposits.
    function setMaxSingleTrade(uint256 _maxSingleTrade) external onlyEmergencyAuthorized {
        require(_maxSingleTrade != type(uint256).max, "cannot be max");
        maxSingleTrade = _maxSingleTrade;
    }

    // Set the minimum amount in asset that should be converted to LP.
    function setMinAssetAmountToLP(uint256 _minAssetAmountToLP) external onlyManagement {
        minAssetAmountToLP = _minAssetAmountToLP;
    }

    // Set the max base fee for tending to occur at.
    function setMaxTendBasefee(
        uint256 _maxTendBasefee
    ) external onlyManagement {
        maxTendBasefee = _maxTendBasefee;
    }

    // Set the amount in asset that should trigger a tend if idle.
    function setDepositTrigger(
        uint256 _depositTrigger
    ) external onlyManagement {
        depositTrigger = _depositTrigger;
    }

    // Set the slippage for deposits.
    function setSlippage(uint256 _slippage) external onlyManagement {
        slippage = _slippage;
    }

    // Set the minimum deposit wait time.
    function setDepositInterval(
        uint256 _newDepositInterval
    ) external onlyManagement {
        // Cannot set to 0.
        require(_newDepositInterval > 0, "interval too low");
        minDepositInterval = _newDepositInterval;
    }

    // Change if anyone can deposit in or only white listed addresses
    function setOpen(bool _open) external onlyManagement {
        open = _open;
    }

    // Set or update an addresses whitelist status.
    function setAllowed(
        address _address,
        bool _allowed
    ) external onlyManagement {
        allowed[_address] = _allowed;
    }

    // Manually pull funds out from the lp without shuting down.
    // This will also stop new deposits and withdraws that would pull from the LP.
    // Can call tend after this to update internal balances.
    function manualWithdraw(
        uint256 _amount
    ) external onlyEmergencyAuthorized {
        maxSingleTrade = 0;
        depositTrigger = type(uint256).max;
        _freeFunds(_amount);
    }

    function _emergencyWithdraw(
        uint256 _amount
    ) internal override {
        maxSingleTrade = 0;
        depositTrigger = type(uint256).max;
        _freeFunds(_amount);
    }

    /// @notice Sweep of non-asset ERC20 tokens to governance (onlyGovernance)
    /// @param _token The ERC20 token to sweep
    function sweep(address _token) external onlyGovernance {
        require(_token != address(asset), "!asset");
        ERC20(_token).safeTransfer(GOV, ERC20(_token).balanceOf(address(this)));
    }

    modifier onlyGovernance() {
        require(msg.sender == GOV, "!gov");
        _;
    }

    receive() external payable {}
}