// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {SingleSidedPT} from "./SingleSidedPT.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract SingleSidedPTFactory {
    event NewSingleSidedPT(address indexed strategy, address indexed asset);

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    address public  immutable oracle;
    address public immutable emergencyAdmin;
    address public immutable GOV;

    mapping(address => address) public marketToStrategy;

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
     * @notice Deploy a new Single Sided Pendle PT Strategy.
     * @return . The address of the new strategy.
     */
    function newSingleSidedPT(address _asset, address _market, address _redeemToken, uint24 _feeRedeemTokenToBase, address _base, uint24 _feeBaseToAsset, string memory _name) external onlyManagement returns (address) {

        IStrategyInterface newStrategy = IStrategyInterface(address(new SingleSidedPT(_asset, _market, _redeemToken, _feeRedeemTokenToBase, _base, _feeBaseToAsset, oracle, GOV, _name)));

        newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        newStrategy.setKeeper(keeper);

        newStrategy.setPendingManagement(management);

        newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewSingleSidedPT(address(newStrategy), _asset);

        marketToStrategy[_market] = address(newStrategy);

        return address(newStrategy);
    }

    /**
     * @notice Retrieve the address of a strategy by market address
     * @param _market market address
     * @return strategy address
     */
    function getStrategyByAsset(address _market) external view returns (address) {
        return marketToStrategy[_market];
    }

    /**
     * @notice Check if a strategy has been deployed by this Factory
     * @param _strategy strategy address
     */
    function isDeployedStrategy(address _strategy) external view returns (bool) {
        address _market = IStrategyInterface(_strategy).market();
        return marketToStrategy[_market] == _strategy;
    }


    function setStrategyByAsset(address _market, address _strategy) external onlyManagement {
        marketToStrategy[_market] = _strategy;
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