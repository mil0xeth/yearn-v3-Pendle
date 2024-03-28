// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

interface ISSPStrategyFactoryInterface {
    function newSingleSidedPendle(
        address _asset,
        address _LP,
        address _redeemToken,
        address _strategy,
        uint256 _maxSingleTrade,
        string memory _name
    ) external returns (address);

    function management() external view returns (address);

    function performanceFeeRecipient() external view returns (address);

    function keeper() external view returns (address);
}
