// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {SingleSidedPendle} from "./SingleSidedPendle.sol";
import {ISSPStrategyInterface} from "./interfaces/ISSPStrategyInterface.sol";

contract SingleSidedPendleFactory {
    event NewSingleSidedPendle(address indexed strategy, address indexed asset);

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    address internal immutable oracle;
    address internal immutable emergencyAdmin;
    address internal immutable GOV;

    mapping(address => address) public assetToStrategy;

    constructor(
        address _management,
        address _peformanceFeeRecipient,
        address _keeper,
        address _oracle,
        address _emergencyAdmin,
        address _GOV
    ) {
        management = _management;
        performanceFeeRecipient = _peformanceFeeRecipient;
        keeper = _keeper;
        oracle = _oracle;
        emergencyAdmin = _emergencyAdmin;
        GOV = _GOV;
    }

    modifier onlyManagement() {
        require(msg.sender == management, "!management");
        _;
    }

    /**
     * @notice Deploy a new Gamma Stable LP Compounder Strategy.
     * @return . The address of the new lender.
     */
    function newSingleSidedPendle(
        address _asset,
        address _LP,
        address _redeemToken,
        address _strategy,
        uint256 _maxSingleTrade,
        string memory _name
    ) external onlyManagement returns (address) {

        ISSPStrategyInterface newStrategy = ISSPStrategyInterface(address(new SingleSidedPendle(_asset, _LP, _redeemToken, oracle, _strategy, _maxSingleTrade, GOV, _name)));

        newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        newStrategy.setKeeper(keeper);

        newStrategy.setPendingManagement(management);

        newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewSingleSidedPendle(address(newStrategy), _asset);

        assetToStrategy[_asset] = address(newStrategy);

        return address(newStrategy);
    }

    /**
     * @notice Retrieve the address of a strategy by LP address
     * @param _asset LP address
     * @return strategy address
     */
    function getStrategyByAsset(address _asset) external view returns (address) {
        return assetToStrategy[_asset];
    }

    /**
     * @notice Check if a strategy has been deployed by this Factory
     * @param _strategy strategy address
     */
    function isDeployedStrategy(address _strategy) external view returns (bool) {
        address _asset = ISSPStrategyInterface(_strategy).asset();
        return assetToStrategy[_asset] == _strategy;
    }


    function setStrategyByAsset(address _asset, address _strategy) external onlyManagement {
        assetToStrategy[_asset] = _strategy;
    }

    /**
     * @notice Set the management address.
     * @dev This is the address that can call the management functions.
     * @param _management The address to set as the management address.
     */
    function setManagement(address _management) external onlyManagement {
        require(_management != address(0), "ZERO_ADDRESS");
        management = _management;
    }

    /**
     * @notice Set the performance fee recipient address.
     * @dev This is the address that will receive the performance fee.
     * @param _performanceFeeRecipient The address to set as the performance fee recipient address.
     */
    function setPerformanceFeeRecipient(
        address _performanceFeeRecipient
    ) external onlyManagement {
        require(_performanceFeeRecipient != address(0), "ZERO_ADDRESS");
        performanceFeeRecipient = _performanceFeeRecipient;
    }

    /**
     * @notice Set the keeper address.
     * @dev This is the address that will be able to call the keeper functions.
     * @param _keeper The address to set as the keeper address.
     */
    function setKeeper(address _keeper) external onlyManagement {
        keeper = _keeper;
    }
}
