// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.18;

interface IPendleOracle {
    function getLpToAssetRate(address market, uint32 duration) external view returns (uint256 rate);
}